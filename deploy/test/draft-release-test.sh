#!/usr/bin/env bash
# Tests for deploy/draft-release.sh (#10) with fake gh and curl commands: nothing leaves the
# machine. Run: deploy/test/draft-release-test.sh
# Single-quoted $ is meant literally here (variables expanded inside check's eval).
# shellcheck disable=SC2016
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SHA="0123456789abcdef0123456789abcdef01234567"
OLD="ffffffffffffffffffffffffffffffffffffffff"
BASE="54d0a70477b663f4838419ad3d0b00a610dd74a5"
RUN=41598422763
PKG="romafederico-site-$SHA.tar.gz"
FAILS=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# A fresh sandbox per case. The fake gh answers `gh api <path>` from files in $FAKE/api (method and
# path with / ? and space turned into _), applies -q with jq, and logs every call plus the -f/-F
# fields of writes and the file sent with --input. Defaults: a good commit on main, last published
# release v0.10.1, a package artifact whose sha256 matches staging/deploy.
setup() {
  T=$(mktemp -d)
  mkdir -p "$T/bin" "$T/api" "$T/pkg" "$T/uploads"
  export FAKE="$T" FAKE_COMMIT="$SHA"
  unset BASIC_AUTH_USER BASIC_AUTH_PASSWORD FAKE_ENV FAKE_PACKAGE FAKE_CODE FIRST_RELEASE_BASE

  cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE/gh.log"
[ "$1" = api ] || { echo "fake gh: unsupported: $*" >&2; exit 2; }
shift
method=GET; path=""; q=""; input=""; fields=()
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2;;
    -q) q="$2"; shift 2;;
    -f|-F) fields+=("$2"); shift 2;;
    -H) shift 2;;
    --input) input="$2"; shift 2;;
    --paginate) shift;;
    *) path="$1"; shift;;
  esac
done
key=$(printf '%s' "$method $path" | sed 's#^\([A-Z]*\) https://uploads.github.com/#\1 #' | tr '/? ' '___')
if [ "$method" != GET ]; then printf '%s\n' "${fields[@]}" > "$FAKE/$key.fields"; fi
if [ -n "$input" ]; then name=${path##*name=}; cp "$input" "$FAKE/uploads/$name"; fi
file="$FAKE/api/$key.json"
[ -f "$file" ] || { echo "gh: Not Found (HTTP 404) $method $path" >&2; exit 1; }
if [ -n "$q" ]; then jq -r "$q" "$file"; else cat "$file"; fi
EOF

  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  [ "$prev" = "-K" ] && cat "$a" > "$FAKE/curl-config"
  case "$a" in https://*) url="$a";; esac
  prev="$a"
done
echo "$url" >> "$FAKE/curl.log"
[ "${FAKE_CODE:-200}" = 200 ] || { echo "401 Unauthorized" > "$out"; printf '%s' "$FAKE_CODE"; exit 0; }
printf '{"site":"romafederico.com","environment":"%s","commit":"%s","version":"sha-0123456","package_sha256":"%s"}' \
  "${FAKE_ENV:-staging}" "$FAKE_COMMIT" "${FAKE_PACKAGE:-$FAKE_SUM}" > "${out:-/dev/stdout}"
printf '%s' "${FAKE_CODE:-200}"
EOF
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH"

  # The package and its artifact zip, as CI's package job uploads them.
  mkdir -p "$T/pkg/src/site"
  echo '<!doctype html><title>rf</title>' > "$T/pkg/src/site/index.html"
  tar -czf "$T/pkg/$PKG" -C "$T/pkg/src" site
  (cd "$T/pkg" && sha256sum "$PKG" > "$PKG.sha256")
  SUM=$(cut -d' ' -f1 "$T/pkg/$PKG.sha256")
  export FAKE_SUM="$SUM"
  make_zip "$PKG" "$PKG.sha256"

  R=repos/romafederico/romafederico.com
  api "GET $R/commits/main" "{\"sha\":\"$SHA\"}"
  api "GET $R/commits/0123456" "{\"sha\":\"$SHA\"}"
  api "GET $R/compare/$SHA...main" '{"status":"identical"}'
  api "GET $R/releases?per_page=100" \
    '[{"id":1,"tag_name":"v0.9.0","draft":false,"prerelease":false},{"id":2,"tag_name":"v0.10.1","draft":false,"prerelease":false},{"id":3,"tag_name":"v2.0.0","draft":true,"prerelease":false}]'
  api "GET $R/git/matching-refs/tags/v1.0.0" '[]'
  api "GET $R/git/matching-refs/tags/v1.0.0-rc.1" '[]'
  api "GET $R/git/matching-refs/tags/v2.0.0" '[]'
  staging_status success "sha256 $SUM"
  api "GET $R/actions/workflows/deploy-staging.yml/runs?per_page=20" \
    "{\"workflow_runs\":[{\"id\":99,\"status\":\"completed\",\"conclusion\":\"skipped\"},{\"id\":$RUN,\"status\":\"completed\",\"conclusion\":\"success\"}]}"
  artifacts main
  cp "$T/package.zip" "$T/api/GET_${R//\//_}_actions_artifacts_777_zip.json"
  # The release since v0.10.1: one harmless PR (#40), squash-merged as $SHA.
  api "GET $R/compare/v0.10.1...$SHA?per_page=100" "{\"total_commits\":1,\"commits\":[{\"sha\":\"$SHA\"}]}"
  commit "$SHA" "Thing" README.md
  # deploy/site-files at the release commit and at the last published release.
  site_files "$SHA" index.html style.css avatar.jpg
  site_files v0.10.1 index.html style.css avatar.jpg
  api "GET $R/git/trees/$BASE?recursive=1" \
    '{"tree":[{"path":".github","type":"tree"},{"path":".github/workflows/deploy.yml","type":"blob"},{"path":".gitignore","type":"blob"},{"path":"README.md","type":"blob"},{"path":"avatar.jpg","type":"blob"},{"path":"index.html","type":"blob"},{"path":"style.css","type":"blob"}]}' 
  api "GET $R/commits/$SHA/pulls" '[{"number":40,"title":"Thing","labels":[]}]'
  api "POST $R/releases/generate-notes" '{"name":"v1.0.0","body":"## What'"'"'s Changed\n* Thing by @someone in #40"}'
  api "POST $R/releases" '{"id":50,"draft":true,"html_url":"https://github.com/romafederico/romafederico.com/releases/tag/untagged-abc","assets":[]}'
  api "PATCH $R/releases/3" '{"id":3,"draft":true,"html_url":"https://github.com/romafederico/romafederico.com/releases/tag/untagged-def","assets":[{"id":71,"name":"romafederico-site-old.tar.gz"},{"id":72,"name":"romafederico-site-old.tar.gz.sha256"}]}'
  api "DELETE $R/releases/assets/71" ''
  api "DELETE $R/releases/assets/72" ''
  for id in 50 3; do
    api "POST $R/releases/$id/assets?name=$PKG" "{\"name\":\"$PKG\",\"state\":\"uploaded\",\"size\":$(wc -c < "$T/pkg/$PKG")}"
    api "POST $R/releases/$id/assets?name=$PKG.sha256" "{\"name\":\"$PKG.sha256\",\"state\":\"uploaded\",\"size\":$(wc -c < "$T/pkg/$PKG.sha256")}"
  done
}

api() { printf '%s' "$2" > "$FAKE/api/$(printf '%s' "$1" | tr '/? ' '___').json"; }
# commit <sha> <subject> <file>...: GET commits/<sha> with those changed files. A file is
# [added:|removed:]<path>, or renamed:<old>:<new>; plain <path> is modified.
commit() {
  local sha="$1" subject="$2"; shift 2
  api "GET $R/commits/$sha" "$(jq -nc --arg sha "$sha" --arg m "$subject" '{sha: $sha, commit: {message: $m}, files: [$ARGS.positional[] | split(":")
    | if length == 1 then {status: "modified", filename: .[0]}
      elif .[0] == "renamed" then {status: "renamed", previous_filename: .[1], filename: .[2]}
      else {status: .[0], filename: .[1]} end]}' --args "$@")"
}
# site_files <ref> <path>...: deploy/site-files at that ref (raw), with a comment line.
site_files() {
  local ref="$1"; shift
  api "GET $R/contents/deploy/site-files?ref=$ref" "$(printf '# The files that make up the site\n'; printf '%s\n' "$@")"
}
staging_status() {
  api "GET $R/commits/$SHA/status" \
    "$(jq -nc --arg s "$1" --arg d "$2" --arg u "https://github.com/romafederico/romafederico.com/actions/runs/$RUN" \
      '{statuses: [{context: "CI", state: "success"}, {context: "staging/deploy", state: $s, target_url: $u, description: $d}]}')"
}
# make_zip <file>...: the artifact zip with exactly these files from $T/pkg.
make_zip() { rm -f "$T/package.zip"; (cd "$T/pkg" && zip -q "$T/package.zip" "$@"); }
# artifacts <branch>: the artifact list deploy.sh also reads.
artifacts() {
  api "GET $R/actions/artifacts?name=package-$SHA&per_page=100" \
    "{\"artifacts\":[{\"id\":777,\"name\":\"package-$SHA\",\"expired\":false,\"created_at\":\"2026-11-03T07:00:00Z\",\"workflow_run\":{\"head_sha\":\"$SHA\",\"head_branch\":\"$1\",\"repository_id\":1,\"head_repository_id\":1}}]}"
}

run() {
  "$ROOT/deploy/draft-release.sh" "$@" > "$FAKE/out.log" 2>&1
  echo $? > "$FAKE/rc"
}
refused() { [ "$(cat "$FAKE/rc")" != 0 ] && grep -qi -- "$1" "$FAKE/out.log" && no_writes; }
no_writes() { ! grep -qE -- "-X (POST|PATCH|PUT|DELETE)" "$FAKE/gh.log" 2>/dev/null; }
ok() { [ "$(cat "$FAKE/rc")" = 0 ] || { cat "$FAKE/out.log"; false; }; }
field() { grep -m1 "^$2=" "$FAKE/$1.fields" | cut -d= -f2-; }
# shellcheck disable=SC2034 # used inside check's eval
POST_REL="POST_repos_romafederico_romafederico.com_releases"

echo "# 1. Bad version strings refused before any write"
for v in 1.0.0 v1.0 v1.0.0-rc1 v1.0.0-rc.0 v1.0.0-beta.1 v01.0.0 "v1.0.0 " latest; do
  setup; run "$v"
  check "'$v' refused" 'refused "vX.Y.Z"'
  rm -rf "$T"
done
setup; run v1.0.0 "$SHA" extra
check "a third argument refused" 'refused "usage"'
rm -rf "$T"

echo "# 2. Version not higher than the last published release"
setup; run v0.10.1
check "equal to last published refused" 'refused "higher"'
rm -rf "$T"
setup; run v0.9.5
check "lower than last published (version order, not text) refused" 'refused "v0.10.1"'
rm -rf "$T"
setup; run v0.10.1-rc.1
check "pre-release of the last published version refused" 'refused "higher"'
rm -rf "$T"
setup
api "GET $R/releases?per_page=100" '[{"id":5,"tag_name":"v1.0.0-rc.2","draft":false,"prerelease":true}]'
run v1.0.0-rc.1
check "rc lower than a published rc refused" 'refused "v1.0.0-rc.2"'
rm -rf "$T"
setup
api "GET $R/releases?per_page=100" '[{"id":5,"tag_name":"v1.0.0-rc.2","draft":false,"prerelease":true}]'
api "GET $R/git/matching-refs/tags/v1.0.0-rc.10" '[]'
api "GET $R/compare/$BASE...$SHA?per_page=100" "{\"total_commits\":1,\"commits\":[{\"sha\":\"$SHA\"}]}"
run v1.0.0-rc.10
check "rc.10 is higher than rc.2 (numbers, not text)" 'ok'
rm -rf "$T"

echo "# 3. Tag or published release with that name already exists"
setup
api "GET $R/git/matching-refs/tags/v1.0.0" '[{"ref":"refs/tags/v1.0.0"}]'
run v1.0.0
check "existing tag refused" 'refused "tag v1.0.0 already exists"'
rm -rf "$T"
setup
api "GET $R/git/matching-refs/tags/v1.0.0" '[{"ref":"refs/tags/v1.0.0-rc.1"}]'
run v1.0.0
check "a tag that only starts with the name is not a clash" 'ok'
rm -rf "$T"
setup
api "GET $R/releases?per_page=100" '[{"id":4,"tag_name":"v1.0.0","draft":false,"prerelease":false}]'
run v1.0.0
check "published release with that name refused" 'refused "release v1.0.0"'
rm -rf "$T"
setup
api "GET $R/releases?per_page=100" '[{"id":4,"tag_name":"v1.0.0","draft":true},{"id":5,"tag_name":"v1.0.0","draft":true}]'
run v1.0.0
check "two drafts with that name refused" 'refused "more than one draft"'
rm -rf "$T"

echo "# 4. Commit not on main"
setup
api "GET $R/compare/$SHA...main" '{"status":"diverged"}'
run v1.0.0 "$SHA"
check "diverged commit refused" 'refused "not on main"'
rm -rf "$T"
setup
api "GET $R/compare/$SHA...main" '{"status":"behind"}'
run v1.0.0 "$SHA"
check "commit ahead of main (a branch) refused" 'refused "not on main"'
rm -rf "$T"
setup; run v1.0.0 "nothex"
check "non-hex commit refused" 'refused "commit"'
rm -rf "$T"

echo "# 5. Commit without staging proof"
setup
api "GET $R/commits/$SHA/status" '{"statuses":[{"context":"CI","state":"success"}]}'
run v1.0.0
check "no staging/deploy status refused" 'refused "staging/deploy"'
rm -rf "$T"
setup; staging_status failure "Staging deploy or smoke test failed"; run v1.0.0
check "failed staging/deploy refused" 'refused "staging/deploy"'
rm -rf "$T"
setup; staging_status pending "Deploying to staging"; run v1.0.0
check "pending staging/deploy refused" 'refused "staging/deploy"'
rm -rf "$T"
setup; staging_status success "Live on staging"; run v1.0.0
check "success without a sha256 in the description refused" 'refused "sha256"'
rm -rf "$T"

echo "# 6. Staging no longer runs that commit"
setup
api "GET $R/actions/workflows/deploy-staging.yml/runs?per_page=20" \
  "{\"workflow_runs\":[{\"id\":100,\"status\":\"in_progress\",\"conclusion\":null},{\"id\":$RUN,\"status\":\"completed\",\"conclusion\":\"success\"}]}"
run v1.0.0
check "newer staging deploy (running) refused" 'refused "newer"'
rm -rf "$T"
setup
export BASIC_AUTH_USER=stg BASIC_AUTH_PASSWORD=basic-pass-value FAKE_COMMIT="$OLD"
run v1.0.0
check "staging /version on another commit refused" 'refused "/version.json"'
rm -rf "$T"
setup
FAKE_PACKAGE=$(printf '%064d' 0)
export BASIC_AUTH_USER=stg BASIC_AUTH_PASSWORD=basic-pass-value FAKE_PACKAGE
run v1.0.0
check "staging /version with another package refused" 'refused "/version.json"'
rm -rf "$T"
setup
export BASIC_AUTH_USER=stg BASIC_AUTH_PASSWORD=wrong FAKE_CODE=401
run v1.0.0
check "staging /version not 200 (not JSON) refused with a reason" 'refused "HTTP 401"'
rm -rf "$T"

echo "# 7. Package: missing, from another branch, or not the one that passed staging"
setup
api "GET $R/actions/artifacts?name=package-$SHA&per_page=100" '{"artifacts":[]}'
run v1.0.0
check "no artifact refused" 'refused "no artifact"'
rm -rf "$T"
setup; artifacts my-branch; run v1.0.0
check "artifact from a branch build refused" 'refused "no artifact"'
rm -rf "$T"
setup; staging_status success "sha256 $(printf '%064d' 0)"; run v1.0.0
check "checksum not matching staging/deploy refused" 'refused "does not match"'
rm -rf "$T"
setup
echo tampered >> "$T/pkg/$PKG"; make_zip "$PKG" "$PKG.sha256"
cp "$T/package.zip" "$T/api/GET_${R//\//_}_actions_artifacts_777_zip.json"
run v1.0.0
check "package not matching its .sha256 refused" 'refused "does not match"'
rm -rf "$T"
setup
echo x > "$T/pkg/extra"; make_zip "$PKG" "$PKG.sha256" extra
cp "$T/package.zip" "$T/api/GET_${R//\//_}_actions_artifacts_777_zip.json"
run v1.0.0
check "artifact with extra files refused" 'refused "exactly"'
rm -rf "$T"

echo "# 8. Good commit: new draft, assets, proof in the body"
setup
export BASIC_AUTH_USER=stg BASIC_AUTH_PASSWORD=basic-pass-value
run v1.0.0
check "exits 0" 'ok'
check "creates a release" '[ -f $FAKE/$POST_REL.fields ]'
check "draft=true" '[ "$(field $POST_REL draft)" = true ]'
check "prerelease=false" '[ "$(field $POST_REL prerelease)" = false ]'
check "tag_name=v1.0.0" '[ "$(field $POST_REL tag_name)" = v1.0.0 ]'
check "target_commitish = full sha" '[ "$(field $POST_REL target_commitish)" = "$SHA" ]'
check "never sends make_latest or a publish" '! grep -q "^make_latest\|^draft=false" $FAKE/$POST_REL.fields'
check "notes generated from the last published release" \
  'grep -qx "previous_tag_name=v0.10.1" $FAKE/${POST_REL}_generate-notes.fields'
check "body has the generated notes" 'grep -q "Thing by @someone" $FAKE/$POST_REL.fields'
check "body has a Staging proof section" 'grep -q "^## Staging proof" $FAKE/$POST_REL.fields'
check "proof: commit" 'grep -q "Commit: \`$SHA\`" $FAKE/$POST_REL.fields'
check "proof: package name and sha256" 'grep -q "$PKG" $FAKE/$POST_REL.fields && grep -q "$SUM" $FAKE/$POST_REL.fields'
check "proof: staging run link" 'grep -q "actions/runs/$RUN" $FAKE/$POST_REL.fields'
check "proof: /version answer" 'grep -q "\"commit\":\"$SHA\"" $FAKE/$POST_REL.fields'
check "proof: time checked" 'grep -qE "Checked: [0-9]{4}-[0-9]{2}-[0-9]{2}T" $FAKE/$POST_REL.fields'
check "package uploaded as an asset, the file that passed staging" 'cmp -s $FAKE/uploads/$PKG $FAKE/pkg/$PKG'
check ".sha256 uploaded as an asset" 'cmp -s $FAKE/uploads/$PKG.sha256 $FAKE/pkg/$PKG.sha256'
check "assets go to the new draft" 'grep -q "uploads.github.com/$R/releases/50/assets?name=$PKG" $FAKE/gh.log'
check "basic auth passed to curl via config, not argv" 'grep -q basic-pass-value $FAKE/curl-config && ! grep -q basic-pass-value $FAKE/gh.log'
check "/version asked of the staging site" 'grep -qx "https://staging.romafederico.com/version.json" $FAKE/curl.log'
check "no tag ref written" '! grep -q "git/refs" $FAKE/gh.log'
check "no workflow started" '! grep -qE "dispatches|gh (workflow|run) " $FAKE/gh.log'
check "output ends with the draft URL" '[ "$(tail -n1 $FAKE/out.log)" = "https://github.com/romafederico/romafederico.com/releases/tag/untagged-abc" ]'
rm -rf "$T"

echo "# 9. Short sha, no staging credentials"
setup
run v1.0.0 0123456
check "exits 0" 'ok'
check "short sha resolved to the full one" '[ "$(field $POST_REL target_commitish)" = "$SHA" ]'
check "proof says /version was not checked live" 'grep -qi "not checked live" $FAKE/$POST_REL.fields'
check "no curl without credentials" '[ ! -e $FAKE/curl.log ]'
rm -rf "$T"

echo "# 10. A draft for that version exists: updated, not duplicated, assets replaced"
setup
run v2.0.0
check "exits 0" 'ok'
check "existing draft patched" '[ "$(field PATCH_repos_romafederico_romafederico.com_releases_3 draft)" = true ]'
check "no new release" '[ ! -f $FAKE/$POST_REL.fields ]'
check "old assets deleted" 'grep -q "DELETE $R/releases/assets/71" $FAKE/gh.log && grep -q "DELETE $R/releases/assets/72" $FAKE/gh.log'
check "new assets uploaded to that draft" 'grep -q "releases/3/assets?name=$PKG.sha256" $FAKE/gh.log'
check "output ends with the draft URL" '[ "$(tail -n1 $FAKE/out.log)" = "https://github.com/romafederico/romafederico.com/releases/tag/untagged-def" ]'
rm -rf "$T"

echo "# 11. Release candidate: a pre-release draft"
setup
run v1.0.0-rc.1
check "exits 0" 'ok'
check "prerelease=true" '[ "$(field $POST_REL prerelease)" = true ]'
check "draft=true" '[ "$(field $POST_REL draft)" = true ]'
check "tag_name=v1.0.0-rc.1" '[ "$(field $POST_REL tag_name)" = v1.0.0-rc.1 ]'
rm -rf "$T"
setup
# rc.1 was published (a dry run); v1.0.0's notes and Heads-up still start at the last full release.
api "GET $R/releases?per_page=100" \
  '[{"id":2,"tag_name":"v0.10.1","draft":false,"prerelease":false},{"id":6,"tag_name":"v1.0.0-rc.1","draft":false,"prerelease":true}]'
run v1.0.0
check "final after its rc exits 0" 'ok'
check "notes since the last full release, not the rc" \
  'grep -qx "previous_tag_name=v0.10.1" $FAKE/${POST_REL}_generate-notes.fields'
check "Heads-up since the last full release" 'grep -q "compare/v0.10.1\.\.\.$SHA" $FAKE/gh.log'
rm -rf "$T"

echo "# 12. Heads-up: nothing risky"
setup
run v1.0.0
check "exits 0" 'ok'
check "body starts with the all-clear" '[ "$(field $POST_REL body)" = "Heads-up: nothing risky in this release." ]'
check "generated notes and proof still below it" 'grep -q "Thing by @someone" $FAKE/$POST_REL.fields && grep -q "^## Staging proof" $FAKE/$POST_REL.fields'
rm -rf "$T"

echo "# 13. Heads-up: every risky PR listed at the top, in plain words; page changes below"
setup
C=(aaaaaaa000000000000000000000000000000001 aaaaaaa000000000000000000000000000000002
   aaaaaaa000000000000000000000000000000003 aaaaaaa000000000000000000000000000000004
   aaaaaaa000000000000000000000000000000005 aaaaaaa000000000000000000000000000000006
   aaaaaaa000000000000000000000000000000007 aaaaaaa000000000000000000000000000000008
   aaaaaaa000000000000000000000000000000009 bbbbbbb000000000000000000000000000000010)
api "GET $R/compare/v0.10.1...$SHA?per_page=100" \
  "$(jq -nc '{total_commits: ($ARGS.positional | length), commits: [$ARGS.positional[] | {sha: .}]}' --args "${C[@]}" "$SHA")"
# This release adds cv.pdf and renames avatar.jpg to me.jpg; v0.10.1 had old.html.
site_files "$SHA" index.html style.css me.jpg cv.pdf
site_files v0.10.1 index.html style.css avatar.jpg old.html
commit "${C[0]}" "Stricter CI" .github/workflows/ci.yml README.md
commit "${C[1]}" "Deploy tweaks" deploy/deploy.sh deploy/live-actors
commit "${C[2]}" "Add CV" added:cv.pdf deploy/site-files index.html
commit "${C[3]}" "Drop old page" removed:old.html
commit "${C[4]}" "New photo" renamed:avatar.jpg:me.jpg
commit "${C[5]}" "New intro" index.html
commit "${C[6]}" "Second commit of #62" style.css index.html
commit "${C[7]}" "Escape output" added:tests/new_check.py
commit "${C[8]}" "A draft page, not on the site" added:draft.html
commit "${C[9]}" "Hotfix pushed straight to main" .github/workflows/deploy-staging.yml
for i in 0 1 2 3 4; do api "GET $R/commits/${C[$i]}/pulls" "[{\"number\":$((57 + i)),\"title\":\"PR $((57 + i))\",\"labels\":[]}]"; done
api "GET $R/commits/${C[5]}/pulls" '[{"number":62,"title":"Intro","labels":[]}]'
api "GET $R/commits/${C[6]}/pulls" '[{"number":62,"title":"Intro","labels":[]}]'
api "GET $R/commits/${C[7]}/pulls" '[{"number":63,"title":"Escape output","labels":[{"name":"type:task"},{"name":"security"}]}]'
api "GET $R/commits/${C[8]}/pulls" '[{"number":64,"title":"Draft page","labels":[]}]'
api "GET $R/commits/${C[9]}/pulls" '[]'
run v1.0.0
check "exits 0" 'ok'
check "body starts with the Heads-up section" '[ "$(field $POST_REL body)" = "## Heads-up" ]'
check "nothing-risky line absent" '! grep -q "nothing risky" $FAKE/$POST_REL.fields'
check "CI change named" 'grep -q "^- #57 PR 57: changes the CI checks or the deploy workflows$" $FAKE/$POST_REL.fields'
check "deploy scripts named" 'grep -q "^- #58 PR 58: changes the deploy scripts or who may deploy live$" $FAKE/$POST_REL.fields'
check "added site file and the site-files list named" \
  'grep -q "^- #59 PR 59: adds a site file (cv.pdf); changes the list of files that make up the site (deploy/site-files)$" $FAKE/$POST_REL.fields'
check "removed site file named" 'grep -q "^- #60 PR 60: removes a site file (old.html)$" $FAKE/$POST_REL.fields'
check "renamed site file named" 'grep -q "^- #61 PR 61: renames a site file (avatar.jpg → me.jpg)$" $FAKE/$POST_REL.fields'
check "security label named" 'grep -q "^- #63 Escape output: has the security label$" $FAKE/$POST_REL.fields'
check "commit without a PR listed by sha" 'grep -q "^- commit bbbbbbb (no PR) Hotfix pushed straight to main: changes the CI checks" $FAKE/$POST_REL.fields'
check "a new file outside deploy/site-files is not risky" '! grep -q "#64" $FAKE/$POST_REL.fields'
check "harmless PR not listed" '! grep -q "^- #40" $FAKE/$POST_REL.fields'
check "page changes section after the risky list" \
  '[ "$(grep -n -m1 "^### Page changes" $FAKE/$POST_REL.fields | cut -d: -f1)" -gt "$(grep -n "^- commit bbbbbbb" $FAKE/$POST_REL.fields | cut -d: -f1)" ]'
check "page change named with its files, commits of one PR grouped" \
  '[ "$(grep -c "^- #62 " $FAKE/$POST_REL.fields)" = 1 ] && grep -q "^- #62 Intro: changes index.html, style.css$" $FAKE/$POST_REL.fields'
check "a risky PR that also edits the page is in both lists" 'grep -q "^- #59 PR 59: changes index.html$" $FAKE/$POST_REL.fields'
check "no first-release line after a published release" '! grep -q "First release" $FAKE/$POST_REL.fields'
check "generated notes still below" 'grep -q "Thing by @someone" $FAKE/$POST_REL.fields && grep -q "^## Staging proof" $FAKE/$POST_REL.fields'
rm -rf "$T"
setup
commit "$SHA" "Typo" index.html
run v1.0.0
check "only page changes: still the all-clear first" '[ "$(field $POST_REL body)" = "Heads-up: nothing risky in this release." ]'
check "only page changes: listed below it" 'grep -q "^### Page changes" $FAKE/$POST_REL.fields && grep -q "^- #40 Thing: changes index.html$" $FAKE/$POST_REL.fields'
rm -rf "$T"

echo "# 14. Heads-up: first release (nothing published) starts where epic #1 started"
setup
api "GET $R/releases?per_page=100" '[]'
api "GET $R/compare/$BASE...$SHA?per_page=100" "{\"total_commits\":1,\"commits\":[{\"sha\":\"$SHA\"}]}"
commit "$SHA" "CI" .github/workflows/ci.yml
run v1.0.0
check "exits 0" 'ok'
check "compares against the epic's start" 'grep -q "compare/$BASE\.\.\.$SHA" $FAKE/gh.log'
check "never walks all of history" '! grep -q "commits?sha=" $FAKE/gh.log'
check "lists the PR since the base" 'grep -q "^- #40 Thing: changes the CI checks" $FAKE/$POST_REL.fields'
check "says the live site loses README.md and .gitignore (not .github, not site files)" \
  'grep -q "^- First release: the live site loses \`.gitignore\`, \`README.md\`. " $FAKE/$POST_REL.fields'
check "first-release line comes first" '[ "$(grep -m1 "^- " $FAKE/$POST_REL.fields | cut -c1-16)" = "- First release:" ]'
check "no previous_tag_name on a first release" '! grep -q "^previous_tag_name=" $FAKE/${POST_REL}_generate-notes.fields'
rm -rf "$T"
setup
api "GET $R/releases?per_page=100" '[]'
api "GET $R/compare/$BASE...$SHA?per_page=100" "{\"total_commits\":1,\"commits\":[{\"sha\":\"$SHA\"}]}"
run v1.0.0
check "first release with nothing risky in its PRs still has the Heads-up" \
  '[ "$(field $POST_REL body)" = "## Heads-up" ] && grep -q "loses \`.gitignore\`, \`README.md\`" $FAKE/$POST_REL.fields'
rm -rf "$T"
setup
api "GET $R/releases?per_page=100" '[]'
api "GET $R/compare/abcdef1...$SHA?per_page=100" "{\"total_commits\":1,\"commits\":[{\"sha\":\"$SHA\"}]}"
api "GET $R/git/trees/abcdef1?recursive=1" '{"tree":[{"path":"index.html","type":"blob"}]}'
FIRST_RELEASE_BASE=abcdef1 run v1.0.0
check "base is configurable" 'ok && grep -q "compare/abcdef1\.\.\.$SHA" $FAKE/gh.log'
check "nothing lost when the base had only site files" '! grep -q "loses" $FAKE/$POST_REL.fields'
rm -rf "$T"
setup
FIRST_RELEASE_BASE='main;x' run v1.0.0
check "bad base refused before any write" 'refused "base"'
rm -rf "$T"
setup
api "GET $R/releases?per_page=100" '[]'
api "GET $R/compare/$BASE...$SHA?per_page=100" "{\"total_commits\":1,\"commits\":[{\"sha\":\"$SHA\"}]}"
rm "$FAKE/api/GET_${R//\//_}_git_trees_${BASE}_recursive=1.json"
run v1.0.0
check "base files not listable refused before any write" 'refused "could not list the files"'
rm -rf "$T"
setup
rm "$FAKE/api/GET_${R//\//_}_contents_deploy_site-files_ref=$SHA.json"
run v1.0.0
check "deploy/site-files not readable refused before any write" 'refused "deploy/site-files"'
rm -rf "$T"

echo "# 15. Heads-up: incomplete commit list refused before any write"
setup
api "GET $R/compare/v0.10.1...$SHA?per_page=100" "{\"total_commits\":2,\"commits\":[{\"sha\":\"$SHA\"}]}"
run v1.0.0
check "refused" 'refused "commits"'
rm -rf "$T"

echo "# 16. deploy/live-actors"
check "lists romafederico and rfminibbot only" \
  '[ "$(grep -v "^#" "$ROOT/deploy/live-actors" | grep . | sort | tr "\n" " ")" = "rfminibbot romafederico " ]'

echo
if [ "$FAILS" = 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
