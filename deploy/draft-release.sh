#!/usr/bin/env bash
# Prepare a DRAFT GitHub Release for a commit that passed staging (#10). Only
# Federico publishes it; publishing creates the v* tag and deploys live (#11).
#
#   deploy/draft-release.sh vX.Y.Z[-rc.N] [<sha>]     (default: main's HEAD)
#
# vX.Y.Z-rc.N is made as a pre-release, which the live deploy treats as a dry
# run (#11). Needs only gh (logged in with repo access), jq, unzip and
# sha256sum. With BASIC_AUTH_USER and BASIC_AUTH_PASSWORD (staging's basic
# auth) it also asks staging's /version.json.
#
# Refuses, before writing anything, unless:
#   - the version is vX.Y.Z or vX.Y.Z-rc.N, higher than the last published
#     release (pre-releases included), and no tag or published release has
#     that name;
#   - the commit is on main;
#   - its staging/deploy status (#7) is success with "sha256 <package>" in
#     the description, the newest Deploy staging run is that run (staging still
#     runs this commit), and with credentials, staging's /version.json reports
#     the commit and package;
#   - CI's artifact package-<sha> holds exactly romafederico-site-<sha>.tar.gz
#     and its .sha256, and that checksum is the one staging/deploy reports.
# Then creates (or updates, if one exists) the draft release: tag_name=vX.Y.Z,
# target_commitish=<full sha>, a "Heads-up" section first (every PR since the
# last published full release that touches something risky for the live site,
# see risk(), and the page changes; on the first release, every PR since
# FIRST_RELEASE_BASE and the files the live site loses), generated notes and a
# "Staging proof" section; and attaches the package and its .sha256 as release
# assets (they don't expire like the 90-day artifact, so release and rollback
# never depend on it). It never publishes, never creates a tag (a draft has no
# tag until published) and never starts a workflow. Last line: the draft URL.
set -euo pipefail

REPO="romafederico/romafederico.com"
R="repos/$REPO"
DEPLOY_ROOT=$(cd "$(dirname "$0")" && pwd)
# Before the first published release, the Heads-up starts here instead of at
# the first commit: main when epic #1 started (2026-11-03). Everything older
# is already live (the old rsync deploy).
FIRST_RELEASE_BASE="${FIRST_RELEASE_BASE:-54d0a70477b663f4838419ad3d0b00a610dd74a5}"
# Files on the live site that are in no commit (hand changes), found by the
# read-only compare in #9. The first release removes them too.
LIVE_ONLY_FILES=()

die() { echo "refused: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

VERSION="${1:-}"
COMMIT_ARG="${2:-main}"
[ $# -le 2 ] || die "usage: draft-release.sh vX.Y.Z[-rc.N] [<sha>]"
SEMVER='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.([1-9][0-9]*))?$'
[[ "$VERSION" =~ $SEMVER ]] || die "version must be vX.Y.Z or vX.Y.Z-rc.N (got '$VERSION')"
PRERELEASE=false
[ -z "${BASH_REMATCH[4]}" ] || PRERELEASE=true
[ "$COMMIT_ARG" = main ] || [[ "$COMMIT_ARG" =~ ^[0-9a-f]{7,40}$ ]] \
  || die "commit must be 7-40 hex characters (got '$COMMIT_ARG')"
[[ "$FIRST_RELEASE_BASE" =~ ^[0-9a-f]{7,40}$ ]] \
  || die "FIRST_RELEASE_BASE must be 7-40 hex characters (got '$FIRST_RELEASE_BASE')"

# --- Version ---------------------------------------------------------------

# Sort key for a version: major minor patch rc, where a full release sorts
# after all its release candidates (sort -V would put v1.0.0 before v1.0.0-rc.1).
version_key() {
  [[ "$1" =~ $SEMVER ]] || return 0
  printf '%s %s %s %s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
    "${BASH_REMATCH[5]:-999999999}" "$1"
}
# newest <tag>...: the highest version among the arguments.
newest() {
  local v
  for v in "$@"; do version_key "$v"; done | sort -k1,1n -k2,2n -k3,3n -k4,4n | tail -n1 | cut -f2
}

# id, tag, draft for every release (drafts are visible with push access).
RELEASES=$(gh api --paginate "$R/releases?per_page=100" -q '.[] | [.id, .tag_name, .draft] | @tsv')
mapfile -t PUBLISHED < <(awk -F'\t' '$3 == "false" { print $2 }' <<< "$RELEASES")
# LAST orders versions; LAST_FULL (no -rc) is where notes and the Heads-up start,
# since a published release candidate is only a dry run and changes nothing live.
LAST=$(newest "${PUBLISHED[@]}")
mapfile -t FULL < <(printf '%s\n' "${PUBLISHED[@]}" | grep -v -- '-rc\.' || true)
LAST_FULL=$(newest "${FULL[@]}")
if [ -n "$LAST" ]; then
  if [ "$LAST" = "$VERSION" ] || [ "$(newest "$LAST" "$VERSION")" != "$VERSION" ]; then
    die "$VERSION is not higher than the last published release $LAST"
  fi
fi
awk -F'\t' -v v="$VERSION" '$2 == v && $3 == "false"' <<< "$RELEASES" | grep -q . \
  && die "a published release $VERSION already exists"
DRAFT_IDS=$(awk -F'\t' -v v="$VERSION" '$2 == v && $3 == "true" { print $1 }' <<< "$RELEASES")
[ "$(grep -c . <<< "$DRAFT_IDS" || true)" -le 1 ] || die "more than one draft named $VERSION; delete the extra ones first"
gh api "$R/git/matching-refs/tags/$VERSION" -q '.[].ref' | grep -qx "refs/tags/$VERSION" \
  && die "tag $VERSION already exists"
log "version $VERSION$([ "$PRERELEASE" = false ] || echo ' (pre-release)') (last published: ${LAST:-none}, last full: ${LAST_FULL:-none})"

# --- Commit on main --------------------------------------------------------

SHA=$(gh api "$R/commits/$COMMIT_ARG" -q .sha)
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve commit '$COMMIT_ARG'"
case "$(gh api "$R/compare/$SHA...main" -q .status)" in
  identical|ahead) ;;
  *) die "commit $SHA is not on main";;
esac
log "commit $SHA is on main"

# --- Staging proof ---------------------------------------------------------

STATUS=$(gh api "$R/commits/$SHA/status" \
  -q '.statuses[] | select(.context == "staging/deploy") | [.state, .target_url, .description] | @tsv')
[ -n "$STATUS" ] || die "commit $SHA has no staging/deploy status (never deployed to staging)"
IFS=$'\t' read -r STATE RUN_URL DESCRIPTION <<< "$STATUS"
[ "$STATE" = success ] || die "staging/deploy for $SHA is '$STATE', not success"
[[ "$RUN_URL" =~ /actions/runs/([0-9]+)$ ]] || die "staging/deploy link is not a workflow run: $RUN_URL"
RUN_ID="${BASH_REMATCH[1]}"
[[ "$DESCRIPTION" =~ ^sha256\ ([0-9a-f]{64})$ ]] \
  || die "staging/deploy description has no package sha256 ('$DESCRIPTION')"
STAGED_SHA256="${BASH_REMATCH[1]}"

# Newest Deploy staging run that did anything (skipped runs deploy nothing)
# must be ours: otherwise staging may run another commit now.
NEWEST=$(gh api "$R/actions/workflows/deploy-staging.yml/runs?per_page=20" \
  -q '[.workflow_runs[] | select(.conclusion != "skipped")][0] | [.id, .status, .conclusion] | @tsv')
IFS=$'\t' read -r NEWEST_ID NEWEST_STATUS NEWEST_CONCLUSION <<< "$NEWEST"
[ "$NEWEST_ID" = "$RUN_ID" ] \
  || die "a newer staging deploy exists (run $NEWEST_ID, $NEWEST_STATUS ${NEWEST_CONCLUSION:-}): staging no longer runs $SHA"

SITE_URL=$(grep -E '^SITE_URL=' "$DEPLOY_ROOT/environments/staging.conf" | cut -d= -f2-)
CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if [ -n "${BASIC_AUTH_USER:-}" ]; then
  # Credentials go to curl as a config on stdin (as in smoke-test.sh).
  code=$(printf 'user = "%s:%s"\n' "$BASIC_AUTH_USER" "${BASIC_AUTH_PASSWORD:-}" \
    | curl -sS --max-time 15 -K - -o "$WORK/version.json" -w '%{http_code}' "$SITE_URL/version.json" 2>/dev/null || echo 000)
  read -r running running_pkg < <(jq -r '[.commit // "none", .package_sha256 // "none"] | join(" ")' "$WORK/version.json" 2>/dev/null || true) || true
  if [ "$code" != 200 ] || [ "${running:-}" != "$SHA" ] || [ "${running_pkg:-}" != "$STAGED_SHA256" ]; then
    die "staging /version.json: HTTP $code, commit '${running:-none}', package '${running_pkg:-none}', expected $SHA and $STAGED_SHA256"
  fi
  LIVE="\`$SITE_URL/version.json\` answered \`$(jq -c . "$WORK/version.json")\`"
else
  LIVE="not checked live (no staging credentials); the newest staging deploy is the run above, whose smoke test saw \`/version.json\` report this commit and package"
fi
log "staging proof: run $RUN_ID, package sha256 $STAGED_SHA256"

# --- Package ---------------------------------------------------------------

# The artifact CI uploaded for this commit on main (same filter as deploy.sh);
# its checksum must be the one that passed staging.
ARTIFACT="package-$SHA"
PKG_NAME="romafederico-site-$SHA.tar.gz"
artifact_id=$(gh api "$R/actions/artifacts?name=$ARTIFACT&per_page=100" \
  | jq -r --arg sha "$SHA" '[.artifacts[]
      | select(.expired == false and .workflow_run.head_sha == $sha and .workflow_run.head_branch == "main"
               and .workflow_run.head_repository_id == .workflow_run.repository_id)]
      | sort_by(.created_at) | last | .id // empty') \
  || die "could not list artifacts for $REPO"
[ -n "$artifact_id" ] || die "no artifact $ARTIFACT from CI on main (expired after 90 days?): not rebuilding"
gh api "$R/actions/artifacts/$artifact_id/zip" > "$WORK/package.zip" || die "could not download artifact $ARTIFACT"
mkdir "$WORK/package"
unzip -q "$WORK/package.zip" -d "$WORK/package" || die "artifact $ARTIFACT is not a zip"
[ "$(cd "$WORK/package" && find . -mindepth 1 | sort | tr '\n' ' ')" = "./$PKG_NAME ./$PKG_NAME.sha256 " ] \
  || die "artifact $ARTIFACT must hold exactly $PKG_NAME and $PKG_NAME.sha256"
read -r PACKAGE_SHA256 sum_name < "$WORK/package/$PKG_NAME.sha256" || true
[ "${sum_name:-}" = "$PKG_NAME" ] || die "$PKG_NAME.sha256 is not '<64 hex>  $PKG_NAME'"
(cd "$WORK/package" && sha256sum -c --quiet "$PKG_NAME.sha256" > /dev/null 2>&1) \
  || die "$PKG_NAME does not match its .sha256"
[ "${PACKAGE_SHA256:-}" = "$STAGED_SHA256" ] \
  || die "package sha256 ${PACKAGE_SHA256:-none} does not match staging/deploy ($STAGED_SHA256)"
log "package $PKG_NAME sha256 $PACKAGE_SHA256"

# --- Heads-up --------------------------------------------------------------

# Every commit going out: since the last published full release, or on the
# first release since the epic's base.
FROM=${LAST_FULL:-$FIRST_RELEASE_BASE}

# site_files <ref>: the paths in deploy/site-files at that commit (#5), one per
# line, without comments and blank lines.
site_files() {
  local raw
  raw=$(gh api -H "Accept: application/vnd.github.raw" "$R/contents/deploy/site-files?ref=$1") || return 1
  sed -e 's/[[:space:]]*#.*//' -e 's/[[:space:]]*$//' <<< "$raw" | grep . || true
}
SITE_NOW=$(site_files "$SHA") || die "could not read deploy/site-files at $SHA"
[ -n "$SITE_NOW" ] || die "deploy/site-files at $SHA lists no files"
SITE_FROM=""
if [ -n "$LAST_FULL" ]; then
  SITE_FROM=$(site_files "$FROM") || die "could not read deploy/site-files at $FROM"
fi
# is_site <path>: listed in deploy/site-files at this release or the last one.
is_site() { [ -n "$1" ] && grep -qxF -- "$1" <<< "$SITE_NOW"$'\n'"$SITE_FROM"; }

# Federico's only yes is publishing, so the notes start with what in this
# release can hurt the live site. risk <file> prints the plain-words reason, if any.
risk() {
  case "$1" in
    .github/*) echo "changes the CI checks or the deploy workflows";;
    deploy/site-files) echo "changes the list of files that make up the site (deploy/site-files)";;
    deploy/*) echo "changes the deploy scripts or who may deploy live";;
  esac
}

COMMITS=$(gh api --paginate "$R/compare/$FROM...$SHA?per_page=100" -q '.commits[].sha')
TOTAL=$(gh api "$R/compare/$FROM...$SHA?per_page=100" -q .total_commits)
[ "$(grep -c . <<< "$COMMITS" || true)" = "$TOTAL" ] \
  || die "listed $(grep -c . <<< "$COMMITS" || true) of $TOTAL commits since $FROM; cannot check them all for the Heads-up"

declare -A REASONS=() PAGES=()
ORDER=()
PAGE_ORDER=()
while read -r c; do
  [ -n "$c" ] || continue
  # One line per PR (several commits of a PR are grouped); else per commit.
  PR_INFO=$(gh api "$R/commits/$c/pulls" -q '.[0] | select(.) | "#\(.number) \(.title)", (.labels[]?.name)')
  PR=$(head -n1 <<< "$PR_INFO")
  INFO=$(gh api "$R/commits/$c" -q '(.commit.message | split("\n")[0]), (.files | length), (.files[] | [.status, .filename, (.previous_filename // "")] | @tsv)')
  KEY=${PR:-"commit ${c:0:7} (no PR) $(head -n1 <<< "$INFO")"}
  found=""
  page=""
  while IFS=$'\t' read -r st f prev; do
    [ -n "$f" ] || continue
    r=$(risk "$f")
    [ -z "$r" ] || found+="$r"$'\n'
    if [ "$st" = renamed ] && { is_site "$f" || is_site "$prev"; }; then
      found+="renames a site file ($prev → $f)"$'\n'
    elif ! is_site "$f"; then
      continue
    elif [ "$st" = added ]; then
      found+="adds a site file ($f)"$'\n'
    elif [ "$st" = removed ]; then
      found+="removes a site file ($f)"$'\n'
    else
      page+="$f"$'\n'
    fi
  done < <(tail -n +3 <<< "$INFO")
  tail -n +2 <<< "$PR_INFO" | grep -qx security && found+=$'\n'"has the security label"
  [ "$(sed -n 2p <<< "$INFO")" -lt 300 ] || found+=$'\n'"has 300 or more files: check it by hand"
  if [ -n "$(tr -d '\n' <<< "$found")" ]; then
    [ -n "${REASONS[$KEY]+x}" ] || ORDER+=("$KEY")
    REASONS[$KEY]+="$found"$'\n'
  fi
  if [ -n "$page" ]; then
    [ -n "${PAGES[$KEY]+x}" ] || PAGE_ORDER+=("$KEY")
    PAGES[$KEY]+="$page"
  fi
done <<< "$COMMITS"

# The first release replaces the old deploy's copy of the whole repo with the
# package, which holds only the site files: everything else the old deploy put
# there (the base commit's files minus .github/) and what #9 found only on
# live disappear from the live site.
LOSES=()
if [ -z "$LAST_FULL" ]; then
  mapfile -t base_files < <(gh api "$R/git/trees/$FIRST_RELEASE_BASE?recursive=1" -q '.tree[] | select(.type == "blob") | .path')
  [ "${#base_files[@]}" -gt 0 ] || die "could not list the files of $FIRST_RELEASE_BASE"
  for f in "${base_files[@]}" "${LIVE_ONLY_FILES[@]}"; do
    case "$f" in .github/*) continue;; esac
    grep -qxF -- "$f" <<< "$SITE_NOW" || LOSES+=("$f")
  done
fi

# "reason; reason" in order of first appearance, each once.
join_once() { grep . <<< "$1" | awk '!seen[$0]++' | paste -sd ';' | sed 's/;/; /g'; }

if [ ${#ORDER[@]} -eq 0 ] && [ ${#LOSES[@]} -eq 0 ]; then
  HEADS_UP="Heads-up: nothing risky in this release."
else
  HEADS_UP="## Heads-up

These change things that can break the live site; read them before publishing:
"
  if [ ${#LOSES[@]} -gt 0 ]; then
    HEADS_UP+="
- First release: the live site loses $(printf "\`%s\`, " "${LOSES[@]}" | sed 's/, $//'). The old deploy copied the whole repo; the package holds only the files in \`deploy/site-files\`."
  fi
  for k in "${ORDER[@]}"; do
    HEADS_UP+="
- $k: $(join_once "${REASONS[$k]}")"
  done
fi
if [ ${#PAGE_ORDER[@]} -gt 0 ]; then
  HEADS_UP+="

### Page changes

What visitors will see change; check them on staging:
"
  for k in "${PAGE_ORDER[@]}"; do
    HEADS_UP+="
- $k: changes $(join_once "${PAGES[$k]}" | sed 's/; /, /g')"
  done
fi
log "heads-up: ${#ORDER[@]} risky PR(s) or commit(s), ${#PAGE_ORDER[@]} with page changes, ${#LOSES[@]} file(s) leaving live, since $FROM"

# --- Notes, draft, assets --------------------------------------------------

notes_args=(-f tag_name="$VERSION" -f target_commitish="$SHA")
[ -z "$LAST_FULL" ] || notes_args+=(-f previous_tag_name="$LAST_FULL")
NOTES=$(gh api -X POST "$R/releases/generate-notes" "${notes_args[@]}" -q .body)

BODY_TEXT="$HEADS_UP

$NOTES

## Staging proof

- Commit: \`$SHA\`
- Package: \`$PKG_NAME\` (attached below)
- sha256: \`$PACKAGE_SHA256\`
- Staging run: $RUN_URL
- Staging \`/version.json\`: $LIVE
- Checked: $CHECKED_AT

Draft prepared by \`deploy/draft-release.sh\`. Publishing creates tag \`$VERSION\` on this commit$([ "$PRERELEASE" = false ] && echo " and deploys it live" || echo "; as a pre-release it is a dry run of the live deploy")."

release_args=(-f tag_name="$VERSION" -f target_commitish="$SHA" -f name="$VERSION"
  -F draft=true -F prerelease="$PRERELEASE" -f body="$BODY_TEXT")
if [ -n "$DRAFT_IDS" ]; then
  RELEASE=$(gh api -X PATCH "$R/releases/$DRAFT_IDS" "${release_args[@]}")
  log "updated draft release $VERSION"
else
  RELEASE=$(gh api -X POST "$R/releases" "${release_args[@]}")
  log "created draft release $VERSION"
fi
RELEASE_ID=$(jq -r .id <<< "$RELEASE")
URL=$(jq -r .html_url <<< "$RELEASE")
[[ "$RELEASE_ID" =~ ^[0-9]+$ ]] || die "GitHub returned no release id"

# Replace whatever assets an earlier draft had, then upload the checked files.
for asset in $(jq -r '.assets[]?.id' <<< "$RELEASE"); do
  gh api -X DELETE "$R/releases/assets/$asset" > /dev/null
done
for f in "$PKG_NAME" "$PKG_NAME.sha256"; do
  size=$(gh api -X POST "https://uploads.github.com/$R/releases/$RELEASE_ID/assets?name=$f" \
    -H "Content-Type: application/octet-stream" --input "$WORK/package/$f" -q 'select(.state == "uploaded") | .size')
  [ "$size" = "$(wc -c < "$WORK/package/$f" | tr -d ' ')" ] || die "upload of $f to the draft did not complete; run again"
done
log "attached $PKG_NAME and $PKG_NAME.sha256"
echo "$URL"
