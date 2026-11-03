#!/usr/bin/env bash
# Tests for deploy/deploy.sh and deploy/smoke-test.sh (staging #7, live #11, rollback #12) with fake gh,
# aws, ssh, docker, curl and a local git repo: nothing leaves the machine. Also checks the guard rails
# of .github/workflows/deploy-staging.yml, release.yml and rollback-live.yml, and runs the notes steps
# of release.yml and rollback-live.yml.
# Run: deploy/test/deploy-test.sh
# Single-quoted $ is meant literally here (bcrypt lines, variables expanded inside check's eval).
# shellcheck disable=SC2016
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SHA="0123456789abcdef0123456789abcdef01234567"
VERSION="sha-0123456"
PKG="romafederico-site-$SHA.tar.gz"
HTLINE='rf:$2y$10$mM1rQcgaRIKiZjYMMEYGROvg5tJ7RgFXZAQZDvgavyZ7yjKcqbSe2'   # a real `htpasswd -niB -C 10 rf` output
HTPASSWD_IMAGE="httpd:2.4.69-alpine@sha256:070da7661f0be8a05430b2c125c0cde9e53176b4048c813024021969a0e3893c"
FAILS=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# A fresh sandbox per case: fake bin/ first on PATH, a log of everything the fakes saw, a package
# artifact zip, and the parameters the fake aws returns.
setup() {
  T=$(mktemp -d)
  mkdir -p "$T/bin" "$T/tmp" "$T/pkg"
  export FAKE="$T" RUNNER_TEMP="$T/tmp" GITHUB_STEP_SUMMARY="$T/summary.md" GITHUB_OUTPUT="$T/output"
  export GITHUB_REPOSITORY=romafederico/romafederico.com
  export SMOKE_INTERVAL=0 SMOKE_TIMEOUT=1
  export FAKE_COMMIT="$SHA" FAKE_ENV=staging FAKE_VERSION="$VERSION"
  unset FAKE_NOAUTH FAKE_ROBOTS FAKE_XROBOTS FAKE_HOME FAKE_README FAKE_AVATAR FAKE_INSTALL_OUT FAKE_CURRENT FAKE_SSH_FAIL
  : > "$T/gate.log"

  # The package and its artifact zip, as CI's package job uploads them.
  mkdir -p "$T/pkg/src/site"
  echo '<p>Federico Roma</p>' > "$T/pkg/src/site/index.html"
  echo "{\"commit\":\"$SHA\"}" > "$T/pkg/src/BUILD.json"
  tar -czf "$T/pkg/$PKG" -C "$T/pkg/src" BUILD.json site
  (cd "$T/pkg" && sha256sum "$PKG" > "$PKG.sha256")
  SUM=$(cut -d' ' -f1 "$T/pkg/$PKG.sha256")
  export FAKE_PKG="$SUM"
  make_zip "$PKG" "$PKG.sha256"
  artifacts main

  cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE/gh.log"
case "$2" in
  */actions/artifacts\?name=*) cat "$FAKE/artifacts.json";;
  */actions/artifacts/*/zip) cat "$FAKE/package.zip";;
  *) echo "fake gh: unexpected $*" >&2; exit 1;;
esac
EOF

  cat > "$T/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$FAKE/aws.log"
cat "$FAKE/params.json"
EOF

  # Only `docker run --rm -i <httpd image> htpasswd -niB -C 10 <user>` (password on stdin).
  cat > "$T/bin/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "\$FAKE/docker.log"
[ "\$*" = "run --rm -i $HTPASSWD_IMAGE htpasswd -niB -C 10 rf" ] || { echo "fake docker: unexpected \$*" >&2; exit 1; }
cat > "\$FAKE/htpasswd.stdin"
printf '%s\n\n' "\$FAKE_HTLINE"
EOF

  # ssh: log the command (last argument), keep stdin, check the key file. Answers like deploy-gate-rf (#2).
  cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${*: -1}"
echo "$cmd" >> "$FAKE/gate.log"
printf '%s\n' "$@" > "$FAKE/ssh-args.last"
prev=""
for a in "$@"; do
  if [ "$prev" = "-i" ]; then stat -c '%a' "$a" > "$FAKE/key-mode"; echo "$a" > "$FAKE/key-path"; cp "$a" "$FAKE/key-copy"; fi
  prev="$a"
done
[ "${FAKE_SSH_FAIL:-}" = "${cmd%% *}" ] && { echo "REFUSED" >&2; exit 1; }
case "$cmd" in
  put-htpasswd) cat > "$FAKE/put-htpasswd.stdin";;
  put-package*) cat > "$FAKE/put-package.stdin";;
  install*) set -- $cmd; echo "${FAKE_INSTALL_OUT-installed $3 ($2)}";;
  current) echo "${FAKE_CURRENT-{\"site\":\"romafederico.com\",\"environment\":\"staging\",\"version\":\"$FAKE_VERSION\",\"commit\":\"$FAKE_COMMIT\",\"package_sha256\":\"$FAKE_PKG\",\"installed_at\":\"2026-11-03T12:00:00Z\"}}";;
esac
exit 0
EOF

  # curl: answers from the URL path, like host nginx (#2). 401 without credentials, except
  # /robots.txt (nginx's return runs before auth_basic). Credentials only from a -K config file.
  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; head=""; url=""; prev=""; config=""
printf '%s\n' "$*" >> "$FAKE/curl-args.log"
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  [ "$prev" = "-D" ] && head="$a"
  [ "$prev" = "-K" ] && { config=$(cat "$a"); stat -c '%a' "$a" > "$FAKE/curl-config-mode"; printf '%s\n' "$config" > "$FAKE/curl-config"; }
  case "$a" in https://*) url="$a";; esac
  prev="$a"
done
echo "$url" >> "$FAKE/curl.log"
path="/${url#https://*/}"; [ "$url" = "${url#https://*/}" ] && path=/
path="${path%%\?*}"
status=200; body="<html></html>"; headers="X-Robots-Tag: ${FAKE_XROBOTS-noindex, nofollow}"
if [ "$path" = /robots.txt ]; then
  body="${FAKE_ROBOTS-$'User-agent: *\nDisallow: /\n'}"
elif ! grep -q '^user = "rf:basic-pass-value"$' <<< "$config"; then
  status="${FAKE_NOAUTH:-401}"; body=""
else
  case "$path" in
    /version.json) body="{\"site\":\"romafederico.com\",\"environment\":\"$FAKE_ENV\",\"version\":\"$FAKE_VERSION\",\"commit\":\"$FAKE_COMMIT\",\"package_sha256\":\"$FAKE_PKG\",\"installed_at\":\"2026-11-03T12:00:00Z\"}";;
    /) body="${FAKE_HOME-<html><title>Federico Roma</title></html>}";;
    /style.css) ;;
    /avatar.jpg) status="${FAKE_AVATAR:-200}";;
    /README.md) status="${FAKE_README:-404}";;
    *) status=404;;
  esac
fi
[ -n "$head" ] && printf 'HTTP/1.1 %s\r\n%s\r\n\r\n' "$status" "$headers" > "$head"
printf '%s' "$body" > "${out:-/dev/stdout}"
printf '%s' "$status"
EOF
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH" FAKE_HTLINE="$HTLINE"
}

make_zip() {   # files in $T/pkg → $T/package.zip
  (cd "$T/pkg" && python3 -c 'import sys, zipfile
with zipfile.ZipFile("../package.zip", "w") as z:
    [z.write(f) for f in sys.argv[1:]]' "$@")
}

artifacts() {  # <head_branch> [expired]
  jq -n --arg sha "$SHA" --arg b "$1" --argjson e "${2:-false}" '{artifacts: [
    {id: 11, name: "package-\($sha)", expired: true, created_at: "2026-08-01T00:00:00Z",
     workflow_run: {id: 1, head_sha: $sha, head_branch: "main", head_repository_id: 7, repository_id: 7}},
    {id: 42, name: "package-\($sha)", expired: $e, created_at: "2026-11-03T07:00:00Z",
     workflow_run: {id: 2, head_sha: $sha, head_branch: $b, head_repository_id: 7, repository_id: 7}}]}' > "$T/artifacts.json"
}

params() {
  # $@ = NAME=VALUE pairs (values may span lines); through jq so quoting is exact. Types as #6 made them.
  printf '%s\0' "$@" | jq -R -s '
    {Parameters: (split("\u0000") | map(select(length > 0)) | map(
      index("=") as $i | {n: .[:$i], v: .[$i + 1:]} | {Name: ("/romafederico/staging/" + .n), Value: .v,
       Type: (if .n == "BASIC_AUTH_USER" then "String" else "SecureString" end)}))}' \
    > "$FAKE/params.json"
}

full_params() {
  params BASIC_AUTH_USER=rf BASIC_AUTH_PASSWORD=basic-pass-value \
    $'DEPLOY_SSH_KEY=-----BEGIN OPENSSH PRIVATE KEY-----\nkey-body-line\n-----END OPENSSH PRIVATE KEY-----'
}

run_deploy() {
  GITHUB_ACTIONS=true "$ROOT/deploy/deploy.sh" --env staging --sha "$SHA" > "$FAKE/out.log" 2>&1
  echo $? > "$FAKE/rc"
}

run_smoke() {
  BASIC_AUTH_USER=rf BASIC_AUTH_PASSWORD=basic-pass-value \
    "$ROOT/deploy/smoke-test.sh" --env staging --commit "$SHA" --version "$VERSION" --package-sha256 "$SUM" > "$FAKE/out.log" 2>&1
  echo $? > "$FAKE/rc"
}

rc() { cat "$FAKE/rc"; }

# The order #7 asks for, on #2's deploy-gate-rf allow-list.
expected_gate() {
  printf '%s\n' put-htpasswd "put-package $SUM" "install $SUM $VERSION" current prune
}

echo "# 1. Arguments"
setup
"$ROOT/deploy/deploy.sh" --env production --sha "$SHA" > "$T/out.log" 2>&1; code=$?
check "--env production refused" '[ $code != 0 ] && grep -q "env must be one of: staging live" $T/out.log'
"$ROOT/deploy/deploy.sh" --env staging --sha "$SHA" --dry-run > "$T/out.log" 2>&1; code=$?
check "--dry-run is for live only" '[ $code != 0 ] && grep -q "for live only" $T/out.log'
"$ROOT/deploy/deploy.sh" --env staging --sha 0123456 > "$T/out.log" 2>&1; code=$?
check "short sha refused" '[ $code != 0 ] && grep -q "40 hex" $T/out.log'
"$ROOT/deploy/deploy.sh" --env staging --sha "$SHA" --rebuild > "$T/out.log" 2>&1; code=$?
check "unknown argument refused" '[ $code != 0 ] && grep -q "unknown argument" $T/out.log'
check "nothing fetched, nothing sent" '[ ! -e $T/gh.log ] && [ ! -e $T/aws.log ] && [ ! -s $T/gate.log ]'
rm -rf "$T"

echo "# 2. No package artifact: stop, never rebuild, never touch AWS or the server"
setup
full_params
artifacts main true
run_deploy
check "exits non-zero" '[ "$(rc)" != 0 ]'
check "says the artifact is gone and that it does not rebuild" 'grep -q "no artifact package-$SHA" $T/out.log && grep -q "not rebuilding" $T/out.log'
check "summary explains" 'grep -q "never rebuilds" $T/summary.md'
check "asked for package-<sha> by name" 'grep -q "actions/artifacts?name=package-$SHA" $T/gh.log'
check "no AWS call, no SSH" '[ ! -e $T/aws.log ] && [ ! -s $T/gate.log ]'
rm -rf "$T"
setup
full_params
artifacts some-branch
run_deploy
check "an artifact from another branch is not used" '[ "$(rc)" != 0 ] && grep -q "no artifact" $T/out.log && [ ! -s $T/gate.log ]'
rm -rf "$T"

echo "# 3. Package does not match its .sha256: stop before put-package"
setup
full_params
echo "tampered" >> "$T/pkg/$PKG"
make_zip "$PKG" "$PKG.sha256"
run_deploy
check "exits non-zero, says why" '[ "$(rc)" != 0 ] && grep -q "does not match its .sha256" $T/out.log'
check "no SSH at all (so no put-package), no AWS" '[ ! -s $T/gate.log ] && [ ! -e $T/aws.log ]'
rm -rf "$T"
setup
full_params
echo extra > "$T/pkg/extra.txt"
make_zip "$PKG" "$PKG.sha256" extra.txt
run_deploy
check "an extra file in the artifact is refused" '[ "$(rc)" != 0 ] && grep -q "exactly" $T/out.log && [ ! -s $T/gate.log ]'
rm -rf "$T"
setup
full_params
echo "$SUM  other-name.tar.gz" > "$T/pkg/$PKG.sha256"
make_zip "$PKG" "$PKG.sha256"
run_deploy
check "a .sha256 naming another file is refused" '[ "$(rc)" != 0 ] && grep -q "is not" $T/out.log && [ ! -s $T/gate.log ]'
rm -rf "$T"

echo "# 4. Missing parameters: fail before any SSH, naming each one"
setup
params BASIC_AUTH_USER=rf
run_deploy
check "exits non-zero" '[ "$(rc)" != 0 ]'
check "names BASIC_AUTH_PASSWORD and DEPLOY_SSH_KEY" 'grep -q "/romafederico/staging/BASIC_AUTH_PASSWORD" $T/out.log && grep -q "/romafederico/staging/DEPLOY_SSH_KEY" $T/out.log'
check "does not name BASIC_AUTH_USER (present)" '! grep -q "/romafederico/staging/BASIC_AUTH_USER" $T/out.log'
check "no SSH command sent" '[ ! -s $T/gate.log ]'
check "reads the path with a trailing slash, decrypted, us-east-1" 'grep -q -- "--path /romafederico/staging/ --with-decryption --region us-east-1" $T/aws.log'
rm -rf "$T"
setup
full_params
params BASIC_AUTH_USER=Bad.User BASIC_AUTH_PASSWORD=basic-pass-value DEPLOY_SSH_KEY=k
run_deploy
check "a user name the gate would refuse stops before SSH" '[ "$(rc)" != 0 ] && grep -q "BASIC_AUTH_USER" $T/out.log && [ ! -s $T/gate.log ]'
rm -rf "$T"

echo "# 5. Full set: gate commands in order, htpasswd, key handling, masks, smoke test"
setup
full_params
run_deploy
check "exits 0" '[ "$(rc)" = 0 ] || { cat $T/out.log; false; }'
check "exact gate command sequence (#2 allow-list)" '[ "$(cat $T/gate.log)" = "$(expected_gate)" ] || { cat $T/gate.log; false; }'
check "downloads the newest unexpired artifact of main (id 42)" 'grep -q "actions/artifacts/42/zip" $T/gh.log'
check "put-package sends the artifact's package byte for byte" 'cmp -s $T/put-package.stdin $T/pkg/$PKG'
check "put-htpasswd sends exactly one bcrypt line" '[ "$(cat $T/put-htpasswd.stdin)" = "$HTLINE" ] && [ "$(wc -l < $T/put-htpasswd.stdin)" = 1 ]'
check "htpasswd gets the password on stdin only" '[ "$(cat $T/htpasswd.stdin)" = basic-pass-value ] && ! grep -q basic-pass-value $T/docker.log'
check "the plain password never reaches the server" '! grep -rq basic-pass-value $T/put-htpasswd.stdin $T/put-package.stdin $T/gate.log $T/ssh-args.last'
check "key file was mode 600" '[ "$(cat $T/key-mode)" = 600 ]'
check "key file had the parameter's key" 'grep -q "key-body-line" $T/key-copy'
check "key file removed afterwards" '[ ! -e "$(cat $T/key-path)" ]'
check "work folder removed" '[ -z "$(ls -A $T/tmp)" ]'
check "ssh: StrictHostKeyChecking=yes" 'grep -qx "StrictHostKeyChecking=yes" $T/ssh-args.last'
check "ssh: committed known_hosts" 'grep -qx "UserKnownHostsFile=$ROOT/deploy/environments/staging.known_hosts" $T/ssh-args.last'
check "ssh: no ssh config, only this key" 'grep -qx -- "-F" $T/ssh-args.last && grep -qx "IdentitiesOnly=yes" $T/ssh-args.last && grep -qx "BatchMode=yes" $T/ssh-args.last'
check "ssh: deploy@66.179.251.96" 'grep -qx "deploy@66.179.251.96" $T/ssh-args.last'
for s in rf basic-pass-value -----BEGIN\ OPENSSH\ PRIVATE\ KEY----- key-body-line "$HTLINE"; do
  check "masked: $s" "grep -qxF -- '::add-mask::$s' \$T/out.log"
done
check "masks come before the first gate command" '[ "$(grep -n "^::add-mask::" $T/out.log | tail -n1 | cut -d: -f1)" -lt "$(grep -n "put-htpasswd" $T/out.log | head -n1 | cut -d: -f1)" ]'
check "no secret printed outside the masks" '! grep -v "^::add-mask::" $T/out.log | grep -qE "basic-pass-value|key-body-line|OPENSSH|\\\$2y\\\$10"'
check "no secret in the summary or outputs" '! grep -qE "basic-pass-value|key-body-line|OPENSSH|\\\$2y\\\$10" $T/summary.md $T/output'
check "package_sha256 output" 'grep -qx "package_sha256=$SUM" $T/output'
check "smoke test hit /version.json (cache-busted), /, /style.css, /avatar.jpg, /robots.txt, /README.md" \
  'grep -qE "^https://staging.romafederico.com/version.json\?[a-z]+=[0-9]+" $T/curl.log && for p in / /style.css /avatar.jpg /robots.txt /README.md; do grep -qx "https://staging.romafederico.com$p" $T/curl.log || exit 1; done'
check "smoke credentials only in a mode-600 curl config file" '[ "$(cat $T/curl-config)" = "user = \"rf:basic-pass-value\"" ] && [ "$(cat $T/curl-config-mode)" = 600 ]'
check "password never on curl's command line" '! grep -q basic-pass-value $T/curl-args.log'
check "summary has the checksum and the smoke test" 'grep -q "sha256 \`$SUM\`" $T/summary.md && grep -q "ok   /README.md" $T/summary.md'
check "no failure section" '! grep -qi "failed" $T/summary.md'
rm -rf "$T"

echo "# 6. Bad htpasswd output: stop before SSH"
setup
full_params
export FAKE_HTLINE="rf:not-a-hash"
run_deploy
check "a line the gate would refuse stops the deploy" '[ "$(rc)" != 0 ] && grep -q "bcrypt" $T/out.log && [ ! -s $T/gate.log ]'
rm -rf "$T"

echo "# 7. Gate answers checked"
setup
full_params
export FAKE_INSTALL_OUT="installed sha-ffffff (abc)"
run_deploy
check "install not confirming the version and sha: red, no current" '[ "$(rc)" != 0 ] && grep -q "install did not confirm" $T/out.log && ! grep -qx current $T/gate.log'
rm -rf "$T"
setup
full_params
export FAKE_CURRENT='none'
run_deploy
check "current not reporting the install: red, no prune" '[ "$(rc)" != 0 ] && grep -q "current reports" $T/out.log && ! grep -qx prune $T/gate.log'
rm -rf "$T"
setup
full_params
export FAKE_SSH_FAIL=put-package
run_deploy
check "a refused gate command stops the run" '[ "$(rc)" != 0 ] && [ "$(tail -n1 $T/gate.log)" = "put-package $SUM" ] && [ ! -e "$(cat $T/key-path)" ]'
rm -rf "$T"

echo "# 8. Smoke test fails after the install: run red, nothing undone"
setup
full_params
run_deploy_old() { FAKE_COMMIT=ffffffffffffffffffffffffffffffffffffffff run_deploy; }
# current must still match (the gate installed the new one); only the site answers the old commit.
export FAKE_CURRENT="{\"site\":\"romafederico.com\",\"environment\":\"staging\",\"version\":\"$VERSION\",\"commit\":\"$SHA\",\"package_sha256\":\"$SUM\",\"installed_at\":\"2026-11-03T12:00:00Z\"}"
run_deploy_old
check "old commit on /version.json: exits non-zero" '[ "$(rc)" != 0 ]'
check "says the smoke test failed" 'grep -q "smoke test failed" $T/out.log && grep -q "FAIL /version.json" $T/summary.md'
check "nothing undone: prune is the last gate command" '[ "$(cat $T/gate.log)" = "$(expected_gate)" ]'
check "key file removed on failure" '[ ! -e "$(cat $T/key-path)" ]'
check "work folder removed on failure" '[ -z "$(ls -A $T/tmp)" ]'
rm -rf "$T"

echo "# 9. Smoke test on its own"
smoke_case() {   # <name> <VAR=value> <expected FAIL text>
  setup
  export "${2?}"
  # FAKE_* values from setup are exported; SUM is the fake package's.
  run_smoke
  check "$1" "[ \"\$(rc)\" != 0 ] && grep -q \"$3\" \$T/out.log"
  rm -rf "$T"
}
setup
run_smoke
check "all checks pass on a good staging" '[ "$(rc)" = 0 ] || { cat $T/out.log; false; }'
check "/robots.txt is not expected to need a login" 'grep -q "ok   /robots.txt" $T/out.log'
check "without credentials: / and /version.json are 401" 'grep -q "ok   / without credentials → 401" $T/out.log && grep -q "ok   /version.json without credentials → 401" $T/out.log'
rm -rf "$T"
smoke_case "a <script on / fails" 'FAKE_HOME=<html>Federico Roma<SCRIPT src=x></SCRIPT></html>' "FAIL /: has <script"
smoke_case "no 'Federico Roma' on / fails" 'FAKE_HOME=<html>someone</html>' "FAIL /: 200 but no 'Federico Roma'"
smoke_case "no X-Robots-Tag noindex fails" 'FAKE_XROBOTS=' "FAIL /: no X-Robots-Tag noindex"
smoke_case "robots.txt without Disallow: / fails" 'FAKE_ROBOTS=User-agent: *' "FAIL /robots.txt"
smoke_case "/README.md served fails" 'FAKE_README=200' "FAIL /README.md"
smoke_case "/avatar.jpg missing fails" 'FAKE_AVATAR=404' "FAIL /avatar.jpg"
smoke_case "no login needed fails" 'FAKE_NOAUTH=200' "FAIL / without credentials"
smoke_case "wrong environment on /version.json fails" 'FAKE_ENV=live' "FAIL /version.json"
smoke_case "wrong package on /version.json fails" 'FAKE_PKG=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' "FAIL /version.json"
setup
"$ROOT/deploy/smoke-test.sh" --env production --commit "$SHA" > "$T/out.log" 2>&1; code=$?
check "smoke-test: --env production refused" "[ $code != 0 ] && grep -q 'env must be staging or live' \$T/out.log && [ ! -e \$T/curl.log ]"
"$ROOT/deploy/smoke-test.sh" --env live --commit "$SHA" > "$T/out.log" 2>&1; code=$?
check "smoke-test: --env live needs --version" "[ $code != 0 ] && grep -q 'needs --version' \$T/out.log && [ ! -e \$T/curl.log ]"
rm -rf "$T"

# --- Live (#11) ------------------------------------------------------------------

RELEASE=v1.0.0
# shellcheck disable=SC2034 # used inside check's eval
LIVE_URL=https://romafederico.com
LIVE_KEY=$'-----BEGIN OPENSSH PRIVATE KEY-----\nlive-key-body\n-----END OPENSSH PRIVATE KEY-----'

# A sandbox for a live run: a git repo whose main holds this deploy/ (tagged $RELEASE), a fake gh
# that serves one release, its assets and the commit's statuses, fake aws (the live key), ssh
# (rf-live-gate, #8) and curl (the live site, no password).
setup_live() {
  T=$(mktemp -d)
  mkdir -p "$T/bin" "$T/tmp" "$T/pkg" "$T/assets"
  export FAKE="$T" RUNNER_TEMP="$T/tmp" GITHUB_STEP_SUMMARY="$T/summary.md" GITHUB_OUTPUT="$T/output"
  export GITHUB_REPOSITORY=romafederico/romafederico.com GITHUB_TRIGGERING_ACTOR=romafederico
  export SMOKE_INTERVAL=0 SMOKE_TIMEOUT=1 FAKE_ENV=live
  unset FAKE_HOME FAKE_WWW FAKE_README FAKE_AVATAR FAKE_BACKUP_FAIL FAKE_INSTALL_FAIL FAKE_CURRENT BASIC_AUTH_USER BASIC_AUTH_PASSWORD
  : > "$T/gate.log"

  git init -q -b main "$T/repo"
  cp -r "$ROOT/deploy" "$T/repo/deploy"
  git -C "$T/repo" add -A
  git -C "$T/repo" -c user.name=t -c user.email=t@example.com commit -qm "release commit"
  git init -q --bare "$T/origin.git"
  git -C "$T/repo" remote add origin "$T/origin.git"
  git -C "$T/repo" push -q origin main
  tag_release "$RELEASE"

  cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE/gh.log"
path=""; q=""; prev=""
for a in "$@"; do
  [ "$prev" = -q ] && q="$a"
  case "$a" in repos/*) path="$a";; esac
  prev="$a"
done
case "$path" in
  */releases/tags/*) f="$FAKE/release.json";;
  */releases/assets/*) f="$FAKE/assets/${path##*/}"; [ -f "$f" ] && { cat "$f"; exit 0; };;
  */commits/*/status) f="$FAKE/status.json";;
  *) echo "fake gh: unexpected $*" >&2; exit 1;;
esac
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ -n "$q" ]; then jq -r "$q" "$f"; else cat "$f"; fi
EOF

  cat > "$T/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$FAKE/aws.log"
cat "$FAKE/params.json"
EOF
  jq -n --arg v "$LIVE_KEY" '{Parameters: [{Name: "/romafederico/live/DEPLOY_SSH_KEY", Type: "SecureString", Value: $v}], InvalidParameters: []}' \
    > "$T/params.json"

  # ssh: rf-live-gate (#8) as it answers on stdout; progress on stderr.
  cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${*: -1}"
echo "$cmd" >> "$FAKE/gate.log"
printf '%s\n' "$@" > "$FAKE/ssh-args.last"
prev=""
for a in "$@"; do
  if [ "$prev" = "-i" ]; then stat -c '%a' "$a" > "$FAKE/key-mode"; echo "$a" > "$FAKE/key-path"; cp "$a" "$FAKE/key-copy"; fi
  prev="$a"
done
read -r -a w <<< "$cmd"
case "${w[0]}" in
  put-package) cat > "$FAKE/put-package.stdin"; echo "PACKAGE=${w[1]} $(stat -c %s "$FAKE/put-package.stdin") bytes";;
  backup)
    [ -n "${FAKE_BACKUP_FAIL:-}" ] && { echo "rf-live-gate: FAILED: tar of the site folder failed" >&2; exit 1; }
    echo "rf-live-gate: site folder → live-20261103-120000-${w[1]}.tgz" >&2
    echo "BACKUP=live-20261103-120000-${w[1]}"
    echo "live-20261103-120000-${w[1]}.tgz 106935 bytes";;
  install)
    [ -n "${FAKE_INSTALL_FAIL:-}" ] && { echo "rf-live-gate: FAILED: package has no index.html" >&2; exit 1; }
    printf '{"site":"romafederico.com","environment":"live","version":"%s","commit":"%s","package_sha256":"%s","installed_at":"2026-11-03T12:01:00Z"}\n' \
      "${w[2]}" "$FAKE_COMMIT" "${w[1]}" > "$FAKE/current"
    echo "INSTALLED=${w[2]} ${w[1]}"
    echo "PREVIOUS=site-20261103-120100";;
  current) if [ -n "${FAKE_CURRENT:-}" ]; then echo "$FAKE_CURRENT"; else cat "$FAKE/current" 2>/dev/null || echo none; fi;;
  *) echo "rf-live-gate: refused: unknown command" >&2; exit 2;;
esac
EOF

  # curl: the live site on DreamHost, no password. www answers the same folder.
  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; head=""; url=""; prev=""
printf '%s\n' "$*" >> "$FAKE/curl-args.log"
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  [ "$prev" = "-D" ] && head="$a"
  [ "$prev" = "-K" ] && echo "$a" >> "$FAKE/curl-config"
  case "$a" in https://*) url="$a";; esac
  prev="$a"
done
echo "$url" >> "$FAKE/curl.log"
path="/${url#https://*/}"; [ "$url" = "${url#https://*/}" ] && path=/
path="${path%%\?*}"
status=200; body="<html></html>"; headers="Content-Type: text/html"
case "$url" in
  https://www.romafederico.com/) body="${FAKE_WWW-<html><title>Federico Roma</title></html>}";;
  *) case "$path" in
       /version.json) body="{\"site\":\"romafederico.com\",\"environment\":\"$FAKE_ENV\",\"version\":\"$FAKE_VERSION\",\"commit\":\"$FAKE_COMMIT\",\"package_sha256\":\"$FAKE_PKG\",\"installed_at\":\"2026-11-03T12:01:00Z\"}";;
       /) body="${FAKE_HOME-<html><title>Federico Roma</title></html>}";;
       /style.css) ;;
       /avatar.jpg) status="${FAKE_AVATAR:-200}";;
       /README.md) status="${FAKE_README:-404}";;
       *) status=404;;
     esac;;
esac
[ -n "$head" ] && printf 'HTTP/1.1 %s\r\n%s\r\n\r\n' "$status" "$headers" > "$head"
printf '%s' "$body" > "${out:-/dev/stdout}"
printf '%s' "$status"
EOF
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH"
}

# tag_release <vX.Y.Z[-rc.N]> [prerelease]: tag HEAD, make its package (release assets 101 and 102),
# a published release whose Staging proof is that package (as deploy/draft-release.sh writes it, #10),
# and a success staging/deploy status (#7).
tag_release() {
  git -C "$T/repo" tag "$1"
  COMMIT=$(git -C "$T/repo" rev-parse HEAD)
  LPKG="romafederico-site-$COMMIT.tar.gz"
  export GITHUB_REF="refs/tags/$1" FAKE_COMMIT="$COMMIT" FAKE_VERSION="$1"
  rm -rf "$T/pkg/src"; mkdir -p "$T/pkg/src/site"
  echo "<p>Federico Roma $1</p>" > "$T/pkg/src/site/index.html"
  echo "{\"commit\":\"$COMMIT\"}" > "$T/pkg/src/BUILD.json"
  tar -czf "$T/pkg/$LPKG" -C "$T/pkg/src" BUILD.json site
  (cd "$T/pkg" && sha256sum "$LPKG" > "$LPKG.sha256")
  LSUM=$(cut -d' ' -f1 "$T/pkg/$LPKG.sha256")
  export FAKE_PKG="$LSUM"
  cp "$T/pkg/$LPKG" "$T/assets/101"
  cp "$T/pkg/$LPKG.sha256" "$T/assets/102"
  release_json "$1" false "${2:-false}" "$LSUM"
  staging_status success "sha256 $LSUM"
}

release_json() { # <tag> <draft> <prerelease> <proof sha256 or ""> [asset names...]
  local names
  if [ $# -gt 4 ]; then names=$(printf '%s\n' "${@:5}" | jq -R . | jq -s .); else names=$(jq -n --arg p "$LPKG" '[$p, "\($p).sha256"]'); fi
  jq -n --arg tag "$1" --argjson draft "$2" --argjson pre "$3" --arg proof "$4" --arg c "$COMMIT" --argjson names "$names" '{
    id: 7, tag_name: $tag, draft: $draft, prerelease: $pre,
    body: ("## Heads-up\r\n\r\nNothing risky.\r\n\r\n## What'"'"'s Changed\r\n* Thing\r\n\r\n## Staging proof\r\n\r\n- Commit: `\($c)`\r\n"
           + (if $proof == "" then "" else "- sha256: `\($proof)`\r\n" end) + "- Staging run: https://github.com/x/actions/runs/1\r\n"),
    assets: [$names | to_entries[] | {id: (101 + .key), name: .value, state: "uploaded"}]}' > "$T/release.json"
}

staging_status() { # <state> <description>
  jq -n --arg s "$1" --arg d "$2" '{statuses: [
    {context: "ci/other", state: "success", description: "x"},
    {context: "staging/deploy", state: $s, description: $d, target_url: "https://github.com/x/actions/runs/1"}]}' > "$T/status.json"
}

run_live() { # [release] [--dry-run]
  (cd "$T/repo" && GITHUB_ACTIONS=true deploy/deploy.sh --env live --release "${1:-$RELEASE}" ${2:+"$2"}) > "$FAKE/out.log" 2>&1
  echo $? > "$FAKE/rc"
}

out() { grep -E "^$1=" "$T/output" | tail -n1 | cut -d= -f2-; }
nothing_sent() { [ ! -e "$T/aws.log" ] && [ ! -s "$T/gate.log" ]; }

echo "# 10. Live guards: refused before AWS or the server, each with a clear error"
setup_live
GITHUB_TRIGGERING_ACTOR=someone-else run_live
check "actor not in deploy/live-actors: refused" '[ "$(rc)" != 0 ] && grep -q "::error::.*someone-else.*not in deploy/live-actors" $T/out.log'
check "actor refused: no GitHub, AWS or SSH call" '[ ! -e $T/gh.log ] && nothing_sent'
GITHUB_TRIGGERING_ACTOR="" run_live
check "no actor: refused" '[ "$(rc)" != 0 ] && grep -q "not in deploy/live-actors" $T/out.log'
GITHUB_TRIGGERING_ACTOR=romafederico-x run_live
check "a login that only starts like a listed one: refused" '[ "$(rc)" != 0 ] && grep -q "not in deploy/live-actors" $T/out.log'
(cd "$T/repo" && deploy/deploy.sh --env live --sha "$SHA") > "$T/out.log" 2>&1; echo $? > "$T/rc"
check "live refuses --sha (it deploys a release)" '[ "$(rc)" != 0 ] && grep -q "live takes --release" $T/out.log'
run_live v1.0
check "--release v1.0 refused" '[ "$(rc)" != 0 ] && grep -q "vX.Y.Z" $T/out.log && nothing_sent'
GITHUB_REF=refs/heads/main run_live
check "run not on the release tag ref: refused" '[ "$(rc)" != 0 ] && grep -q "refs/tags/$RELEASE" $T/out.log && nothing_sent'
rm -rf "$T"

setup_live
git -C "$T/repo" checkout -q -b side
echo x > "$T/repo/side.txt"; git -C "$T/repo" add side.txt
git -C "$T/repo" -c user.name=t -c user.email=t@example.com commit -qm "not on main"
tag_release v1.0.1
run_live v1.0.1
check "tag's commit not on main: refused" '[ "$(rc)" != 0 ] && grep -q "::error::v1.0.1 ($COMMIT) is not on main" $T/out.log && nothing_sent'
rm -rf "$T"

setup_live
echo y > "$T/repo/later.txt"; git -C "$T/repo" add later.txt
git -C "$T/repo" -c user.name=t -c user.email=t@example.com commit -qm later
run_live
check "checkout is not the tagged commit: refused" '[ "$(rc)" != 0 ] && grep -q "not the commit tagged" $T/out.log && nothing_sent'
rm -rf "$T"

setup_live
release_json "$RELEASE" true false "$LSUM"
run_live
check "draft release: refused" '[ "$(rc)" != 0 ] && grep -q "::error::no published release $RELEASE" $T/out.log && nothing_sent'
check "draft: no release_id output (no notes)" '[ -z "$(out release_id)" ]'
rm -f "$T/release.json"
run_live
check "no release (GitHub hides drafts by tag): refused" '[ "$(rc)" != 0 ] && grep -q "no published release" $T/out.log && nothing_sent'
release_json "$RELEASE" false false "$LSUM" "$LPKG"
run_live
check "release without the .sha256 asset: refused" '[ "$(rc)" != 0 ] && grep -q "has no asset $LPKG.sha256" $T/out.log && nothing_sent'
release_json "$RELEASE" false false "$LSUM" "romafederico-site-ffffffffffffffffffffffffffffffffffffffff.tar.gz" "romafederico-site-ffffffffffffffffffffffffffffffffffffffff.tar.gz.sha256"
run_live
check "release with another commit's package: refused" '[ "$(rc)" != 0 ] && grep -q "has no asset $LPKG" $T/out.log && nothing_sent'
rm -rf "$T"

setup_live
echo tampered >> "$T/assets/101"
run_live
check "asset does not match its .sha256: refused" '[ "$(rc)" != 0 ] && grep -q "does not match its .sha256" $T/out.log && nothing_sent'
rm -rf "$T"

setup_live
release_json "$RELEASE" false false "$(printf 'e%.0s' {1..64})"
run_live
check "checksum differs from the Staging proof: refused" '[ "$(rc)" != 0 ] && grep -q "::error::.*Staging proof" $T/out.log && nothing_sent'
release_json "$RELEASE" false false ""
run_live
check "no Staging proof sha256: refused" '[ "$(rc)" != 0 ] && grep -q "no Staging proof" $T/out.log && nothing_sent'
release_json "$RELEASE" false false "$LSUM"
staging_status success "sha256 $(printf 'e%.0s' {1..64})"
run_live
check "checksum differs from staging/deploy: refused" '[ "$(rc)" != 0 ] && grep -q "::error::.*staging/deploy" $T/out.log && nothing_sent'
staging_status failure "Staging deploy or smoke test failed (sha256 $LSUM)"
run_live
check "staging/deploy not success: refused" '[ "$(rc)" != 0 ] && grep -q "staging/deploy for $COMMIT is .failure." $T/out.log && nothing_sent'
jq '.statuses |= map(select(.context != "staging/deploy"))' "$T/status.json" > "$T/s" && mv "$T/s" "$T/status.json"
run_live
check "no staging/deploy status: refused" '[ "$(rc)" != 0 ] && grep -q "is .missing., not success" $T/out.log && nothing_sent'
check "failed guard: failed_step=guards" '[ "$(out failed_step)" = guards ]'
rm -rf "$T"

echo "# 11. Live deploy: put-package, backup, install, current, smoke test"
setup_live
run_live
check "exits 0" '[ "$(rc)" = 0 ] || { cat $T/out.log; false; }'
# shellcheck disable=SC2034 # used inside check's eval
expected="put-package $LSUM
backup v1-0-0
install $LSUM $RELEASE
current"
check "exact rf-live-gate command sequence (#8)" '[ "$(cat $T/gate.log)" = "$expected" ] || { cat $T/gate.log; false; }'
check "put-package sends the release asset byte for byte" 'cmp -s $T/put-package.stdin $T/pkg/$LPKG'
check "downloads the assets as files (octet-stream)" 'grep -q "Accept: application/octet-stream" $T/gh.log && grep -q "releases/assets/101" $T/gh.log'
check "reads only /romafederico/live/DEPLOY_SSH_KEY, decrypted, us-east-1" \
  '[ "$(cat $T/aws.log)" = "aws ssm get-parameters --names /romafederico/live/DEPLOY_SSH_KEY --with-decryption --region us-east-1 --output json" ]'
check "key file was mode 600 with the live key" '[ "$(cat $T/key-mode)" = 600 ] && grep -q live-key-body $T/key-copy'
check "key file and work folder removed" '[ ! -e "$(cat $T/key-path)" ] && [ -z "$(ls -A $T/tmp)" ]'
check "ssh: StrictHostKeyChecking=yes, committed live.known_hosts" \
  'grep -qx "StrictHostKeyChecking=yes" $T/ssh-args.last && grep -qx "UserKnownHostsFile=$T/repo/deploy/environments/live.known_hosts" $T/ssh-args.last'
check "ssh: romafederico@pdx1-shared-a1-22.dreamhost.com, no ssh config" \
  'grep -qx "romafederico@pdx1-shared-a1-22.dreamhost.com" $T/ssh-args.last && grep -qx -- "-F" $T/ssh-args.last && grep -qx "IdentitiesOnly=yes" $T/ssh-args.last'
check "key masked line by line" 'grep -qxF "::add-mask::live-key-body" $T/out.log'
check "key never printed" '! grep -v "^::add-mask::" $T/out.log | grep -q live-key-body'
check "key not in the summary or outputs" '! grep -q live-key-body $T/summary.md $T/output'
check "outputs: release_id, dry_run=false, package, package_sha256, commit" \
  '[ "$(out release_id)" = 7 ] && [ "$(out dry_run)" = false ] && [ "$(out package)" = "$LPKG" ] && [ "$(out package_sha256)" = "$LSUM" ] && [ "$(out commit)" = "$COMMIT" ]'
check "output backup = the gate's BACKUP= name" '[ "$(out backup)" = live-20261103-120000-v1-0-0 ]'
check "no failed_step output" '[ -z "$(out failed_step)" ]'
check "smoke test hit /version.json (cache-busted), /, /style.css, /avatar.jpg, /README.md and www" \
  'grep -qE "^$LIVE_URL/version.json\?[a-z]+=[0-9]+" $T/curl.log && (for p in / /style.css /avatar.jpg /README.md; do grep -qx "$LIVE_URL$p" $T/curl.log || exit 1; done) && grep -qx "https://www.romafederico.com/" $T/curl.log'
check "smoke test sent no credentials" '[ ! -e $T/curl-config ] && ! grep -qE -- "(^| )(-u|--user|-K) " $T/curl-args.log'
check "summary names the release, package and backup" \
  'grep -q "Live deploy $RELEASE" $T/summary.md && grep -q "$LSUM" $T/summary.md && grep -q "live-20261103-120000-v1-0-0" $T/summary.md'
rm -rf "$T"

echo "# 12. Dry runs (dispatch, pre-release) never send install"
setup_live
run_live "$RELEASE" --dry-run
check "--dry-run: exits 0" '[ "$(rc)" = 0 ] || { cat $T/out.log; false; }'
# shellcheck disable=SC2034 # used inside check's eval
expected="put-package $LSUM
backup v1-0-0
current"
check "--dry-run: put-package, backup, current; no install" '[ "$(cat $T/gate.log)" = "$expected" ] || { cat $T/gate.log; false; }'
check "--dry-run: dry_run=true, backup named" '[ "$(out dry_run)" = true ] && [ "$(out backup)" = live-20261103-120000-v1-0-0 ]'
check "--dry-run: no smoke test against the old live site" '[ ! -e $T/curl.log ]'
check "--dry-run: summary says so" 'grep -q "Dry run" $T/summary.md'
rm -rf "$T"
setup_live
tag_release v1.0.0-rc.1 true
run_live v1.0.0-rc.1
check "pre-release v1.0.0-rc.1: exits 0" '[ "$(rc)" = 0 ] || { cat $T/out.log; false; }'
check "pre-release: no install, dry_run=true" '! grep -q install $T/gate.log && [ "$(out dry_run)" = true ]'
check "pre-release: backup label v1-0-0-rc-1 (the gate allows a-z 0-9 -)" 'grep -qx "backup v1-0-0-rc-1" $T/gate.log'
rm -rf "$T"
setup_live
release_json "$RELEASE" false true "$LSUM"
run_live
check "release marked pre-release: no install" '[ "$(rc)" = 0 ] && ! grep -q install $T/gate.log && [ "$(out dry_run)" = true ]'
rm -rf "$T"
setup_live
tag_release v1.0.0-rc.2 false
run_live v1.0.0-rc.2
check "rc name, not marked pre-release: still no install" '[ "$(rc)" = 0 ] && ! grep -q install $T/gate.log && [ "$(out dry_run)" = true ]'
rm -rf "$T"

echo "# 13. Live failures: the run is red, the failed step and backup are recorded"
setup_live
export FAKE_BACKUP_FAIL=1
run_live
check "backup fails: exits non-zero, no install" '[ "$(rc)" != 0 ] && ! grep -q install $T/gate.log'
check "backup fails: failed_step=backup, no backup output" '[ "$(out failed_step)" = backup ] && [ -z "$(out backup)" ]'
check "backup fails: summary says the live site was not changed, no backup" \
  'grep -q "failed at backup" $T/summary.md && grep -q "not changed" $T/summary.md && grep -qxF -- "- Backup before deploy: none made" $T/summary.md'
rm -rf "$T"
setup_live
export FAKE_INSTALL_FAIL=1
run_live
check "install fails: exits non-zero, failed_step=install, backup kept" '[ "$(rc)" != 0 ] && [ "$(out failed_step)" = install ] && [ "$(out backup)" = live-20261103-120000-v1-0-0 ]'
check "install fails: summary names the backup" \
  'grep -q "failed at install" $T/summary.md && grep -qxF -- "- Backup before deploy: \`live-20261103-120000-v1-0-0\` (.tgz in ~/rf-backups)" $T/summary.md'
rm -rf "$T"
setup_live
export FAKE_CURRENT=none
run_live
check "current does not report the release: failed_step=current" '[ "$(rc)" != 0 ] && [ "$(out failed_step)" = current ]'
rm -rf "$T"
setup_live
export FAKE_README=200
run_live
check "smoke test fails: failed_step=smoke-test" '[ "$(rc)" != 0 ] && [ "$(out failed_step)" = smoke-test ] && grep -q "FAIL /README.md" $T/summary.md'
check "smoke test fails: says the new package is installed" 'grep -q "new package is installed on the live site" $T/summary.md'
check "smoke test fails: key file removed" '[ ! -e "$(cat $T/key-path)" ]'
rm -rf "$T"

echo "# 14. Rollback live (#12): an earlier release's own package, after a backup rollback-vA-B-C"
run_rollback() { # [release] [--dry-run]
  (cd "$T/repo" && GITHUB_ACTIONS=true deploy/deploy.sh --env live --rollback "${1:-$RELEASE}" ${2:+"$2"}) > "$FAKE/out.log" 2>&1
  echo $? > "$FAKE/rc"
}
# A Live deploy section as release.yml's notes job writes it (#11), with that package's sha256.
live_deploy_notes() { # <sha256> [heading]
  jq --arg s "$1" --arg p "$LPKG" --arg h "${2:-## Live deploy}" '.body += "\n\n\($h)\n\n- Package: \($p), sha256 \($s)\n- Backup before deploy: live-20261101-090000-v1-0-0.tgz (in ~/rf-backups)\n- Run: https://github.com/x/actions/runs/5/attempts/1\n- At: 2026-11-01T09:00:00Z"' \
    "$T/release.json" > "$T/r" && mv "$T/r" "$T/release.json"
}
setup_live
live_deploy_notes "$LSUM"
run_rollback
check "rollback: exits 0" '[ "$(rc)" = 0 ] || { cat $T/out.log; false; }'
# shellcheck disable=SC2034 # used inside check's eval
expected="put-package $LSUM
backup rollback-v1-0-0
install $LSUM $RELEASE
current"
check "rollback: put-package, backup rollback-v1-0-0, install, current" '[ "$(cat $T/gate.log)" = "$expected" ] || { cat $T/gate.log; false; }'
check "rollback: sends the release's own asset byte for byte" 'cmp -s $T/put-package.stdin $T/pkg/$LPKG'
check "rollback: smoke test expects $RELEASE on /version.json and www" \
  'grep -qE "^$LIVE_URL/version.json\?" $T/curl.log && grep -qx "https://www.romafederico.com/" $T/curl.log && grep -q "^ok" $T/out.log'
check "rollback: outputs dry_run=false, release_id, backup live-<stamp>-rollback-v1-0-0" \
  '[ "$(out dry_run)" = false ] && [ "$(out release_id)" = 7 ] && [ "$(out backup)" = live-20261103-120000-rollback-v1-0-0 ]'
check "rollback: summary names it, who started it, the package and the backup" \
  'grep -q "### Rollback live to $RELEASE" $T/summary.md && grep -q "Started by: \`romafederico\`" $T/summary.md && grep -q "$LSUM" $T/summary.md && grep -qxF -- "- Backup before rollback: \`live-20261103-120000-rollback-v1-0-0\` (.tgz in ~/rf-backups)" $T/summary.md'
check "rollback: the recorded live deploy's sha256 is checked" 'grep -qx "==> ok: rollback to $RELEASE uses the package its Live deploy recorded" $T/out.log'
check "rollback: key file and work folder removed" '[ ! -e "$(cat $T/key-path)" ] && [ -z "$(ls -A $T/tmp)" ]'
rm -rf "$T"

setup_live
run_rollback
check "rollback of a release with no Live deploy recorded: allowed (Staging proof is enough)" \
  '[ "$(rc)" = 0 ] && grep -q "install $LSUM" $T/gate.log && grep -qx "==> ok: rollback to $RELEASE uses its Staging proof package (no Live deploy recorded)" $T/out.log'
rm -rf "$T"

setup_live
run_rollback "$RELEASE" --dry-run
# shellcheck disable=SC2034 # used inside check's eval
expected="put-package $LSUM
backup rollback-v1-0-0
current"
check "rollback --dry-run: put-package, backup, current; no install" '[ "$(rc)" = 0 ] && [ "$(cat $T/gate.log)" = "$expected" ] || { cat $T/gate.log; cat $T/out.log; false; }'
check "rollback --dry-run: dry_run=true, no smoke test" '[ "$(out dry_run)" = true ] && [ ! -e $T/curl.log ]'
check "rollback --dry-run: summary says dry run" 'grep -q "### Rollback live to $RELEASE (dry run)" $T/summary.md && grep -q "Dry run" $T/summary.md'
rm -rf "$T"

setup_live
GITHUB_TRIGGERING_ACTOR=someone-else run_rollback
check "rollback by an actor not in deploy/live-actors: refused, nothing called" \
  '[ "$(rc)" != 0 ] && grep -q "::error::.*someone-else.*not in deploy/live-actors.*rollback" $T/out.log && [ ! -e $T/gh.log ] && nothing_sent'
GITHUB_REF=refs/heads/main run_rollback
check "rollback not run on the release tag: refused" '[ "$(rc)" != 0 ] && grep -q "refs/tags/$RELEASE" $T/out.log && nothing_sent'
GITHUB_REF=refs/tags/v1.1.0 run_rollback
check "rollback run on another tag: refused" '[ "$(rc)" != 0 ] && grep -q "refs/tags/$RELEASE" $T/out.log && nothing_sent'
run_rollback v1.0
check "--rollback v1.0 refused" '[ "$(rc)" != 0 ] && grep -q "::error::--rollback must be vX.Y.Z" $T/out.log && nothing_sent'
run_rollback v1.0.0-rc.1
check "--rollback to a release candidate refused (it never went live)" '[ "$(rc)" != 0 ] && grep -q "::error::--rollback must be vX.Y.Z" $T/out.log && nothing_sent'
(cd "$T/repo" && deploy/deploy.sh --env live --release "$RELEASE" --rollback "$RELEASE") > "$T/out.log" 2>&1; echo $? > "$T/rc"
check "--release and --rollback together: refused" '[ "$(rc)" != 0 ] && grep -q "not both" $T/out.log && nothing_sent'
(cd "$T/repo" && deploy/deploy.sh --env staging --sha "$SHA" --rollback "$RELEASE") > "$T/out.log" 2>&1; echo $? > "$T/rc"
check "staging --rollback: refused" '[ "$(rc)" != 0 ] && grep -q "for live only" $T/out.log && nothing_sent'
rm -rf "$T"

setup_live
release_json "$RELEASE" true false "$LSUM"
run_rollback
check "rollback to a draft: refused" '[ "$(rc)" != 0 ] && grep -q "no published release $RELEASE" $T/out.log && nothing_sent'
release_json "$RELEASE" false true "$LSUM"
run_rollback
check "rollback to a release marked pre-release: refused (it never went live)" '[ "$(rc)" != 0 ] && grep -q "::error::$RELEASE is marked pre-release" $T/out.log && nothing_sent'
release_json "$RELEASE" false false "$(printf 'e%.0s' {1..64})"
run_rollback
check "rollback: package differs from the Staging proof: refused" '[ "$(rc)" != 0 ] && grep -q "::error::.*Staging proof" $T/out.log && nothing_sent'
release_json "$RELEASE" false false "$LSUM"
staging_status success "sha256 $(printf 'e%.0s' {1..64})"
run_rollback
check "rollback: package differs from staging/deploy: refused" '[ "$(rc)" != 0 ] && grep -q "::error::.*staging/deploy" $T/out.log && nothing_sent'
staging_status success "sha256 $LSUM"
live_deploy_notes "$(printf 'd%.0s' {1..64})"
run_rollback
check "rollback: Live deploy recorded another sha256: refused" \
  '[ "$(rc)" != 0 ] && grep -q "::error::the release notes record a live deploy of sha256 d" $T/out.log && nothing_sent'
check "rollback refused: summary says the live site was not changed" 'grep -q "Rollback live to $RELEASE failed at guards" $T/summary.md && grep -q "not changed" $T/summary.md'
release_json "$RELEASE" false false "$LSUM"
live_deploy_notes "$(printf 'd%.0s' {1..64})" "## Live deploy: FAILED at install"
run_rollback
check "rollback: a FAILED Live deploy section with another sha256 also refuses" \
  '[ "$(rc)" != 0 ] && grep -q "::error::the release notes record a live deploy of sha256 d" $T/out.log && nothing_sent'
rm -rf "$T"

setup_live
export FAKE_BACKUP_FAIL=1
run_rollback
check "rollback backup fails: no install, failed_step=backup, none made" \
  '[ "$(rc)" != 0 ] && ! grep -q install $T/gate.log && [ "$(out failed_step)" = backup ] && grep -qxF -- "- Backup before rollback: none made" $T/summary.md'
rm -rf "$T"
setup_live
export FAKE_INSTALL_FAIL=1
run_rollback
check "rollback install fails: red, failed_step=install, backup kept" \
  '[ "$(rc)" != 0 ] && [ "$(out failed_step)" = install ] && [ "$(out backup)" = live-20261103-120000-rollback-v1-0-0 ]'
check "rollback install fails: summary names the backup" \
  'grep -q "Rollback live to $RELEASE failed at install" $T/summary.md && grep -qxF -- "- Backup before rollback: \`live-20261103-120000-rollback-v1-0-0\` (.tgz in ~/rf-backups)" $T/summary.md'
rm -rf "$T"
setup_live
export FAKE_README=200
run_rollback
check "rollback smoke test fails: failed_step=smoke-test, summary says $RELEASE is installed" \
  '[ "$(rc)" != 0 ] && [ "$(out failed_step)" = smoke-test ] && grep -q "$RELEASE is installed on the live site" $T/summary.md && ! grep -q "Rollback live\*\* on the previous" $T/summary.md'
rm -rf "$T"
setup_live
export FAKE_README=200
run_live
check "release smoke test fails: summary points to Rollback live" 'grep -q "Federico orders \*\*Rollback live\*\* on the previous release" $T/summary.md'
rm -rf "$T"

echo "# 15. Live smoke test on its own"
run_live_smoke() {
  "$ROOT/deploy/smoke-test.sh" --env live --commit "$COMMIT" --version "$RELEASE" --package-sha256 "$LSUM" > "$FAKE/out.log" 2>&1
  echo $? > "$FAKE/rc"
}
live_smoke_case() {   # <name> <VAR=value> <expected FAIL text>
  setup_live
  export "${2?}"
  run_live_smoke
  check "$1" "[ \"\$(rc)\" != 0 ] && grep -q \"$3\" \$T/out.log"
  rm -rf "$T"
}
setup_live
BASIC_AUTH_USER=rf BASIC_AUTH_PASSWORD=should-not-be-sent run_live_smoke
check "all checks pass on a good live site, without credentials" '[ "$(rc)" = 0 ] && [ ! -e $T/curl-config ] && ! grep -q should-not-be-sent $T/curl-args.log || { cat $T/out.log; false; }'
check "www answers too" 'grep -q "ok   https://www.romafederico.com/" $T/out.log'
rm -rf "$T"
live_smoke_case "a <script on / fails" 'FAKE_HOME=<html>Federico Roma<script></script></html>' "FAIL /: has <script"
live_smoke_case "www without 'Federico Roma' fails" 'FAKE_WWW=<html>parked</html>' "FAIL https://www.romafederico.com/: 200 but no 'Federico Roma'"
live_smoke_case "/README.md served fails" 'FAKE_README=200' "FAIL /README.md"
live_smoke_case "/avatar.jpg missing fails" 'FAKE_AVATAR=404' "FAIL /avatar.jpg"
live_smoke_case "staging's version.json on live fails" 'FAKE_ENV=staging' "FAIL /version.json"
live_smoke_case "older version on /version.json fails" 'FAKE_VERSION=v0.9.0' "FAIL /version.json"

echo "# 16. release.yml and the live settings"
LCONF="$ROOT/deploy/environments/live.conf"
RWF="$ROOT/.github/workflows/release.yml"
for kv in DEPLOY_HOST=pdx1-shared-a1-22.dreamhost.com DEPLOY_USER=romafederico SITE_URL=https://romafederico.com \
  AWS_REGION=us-east-1 AWS_ROLE_ARN=arn:aws:iam::441641151006:role/romafederico-gha-live SSM_PATH=/romafederico/live/; do
  check "live.conf: $kv (#3, #9)" "grep -qx '$kv' '$LCONF'"
done
check "live.known_hosts: DreamHost's ed25519 key (#9)" \
  "[ \"\$(ssh-keygen -lf '$ROOT/deploy/environments/live.known_hosts' | cut -d' ' -f2)\" = SHA256:okU2Ml5japcLOIxRlNNHsx+SsgPBkeoPzWH4KLkE4xw ]"
check "live-actors: romafederico" "grep -qx romafederico '$ROOT/deploy/live-actors'"
check "old deploy.yml (rsync on push) is gone" "[ ! -e '$ROOT/.github/workflows/deploy.yml' ]"
check "no workflow uses DREAMHOST_SSH_KEY or rsync" "! grep -rnE 'DREAMHOST_SSH_KEY|rsync' '$ROOT/.github/workflows'"
check "release.yml: name Release live" "grep -qx 'name: Release live' '$RWF'"
check "release.yml: no secrets.* or vars.*" "! grep -nE '(secrets|vars)\\.' '$RWF'"
check "release.yml: permissions: {} at the top" "grep -qx 'permissions: {}' '$RWF'"
check "release.yml: on push of v*.*.* tags and workflow_dispatch" "grep -qF \"tags: ['v*.*.*']\" '$RWF' && grep -q '^  workflow_dispatch:' '$RWF'"
check "release.yml: concurrency deploy-live, never cancelled" "grep -A2 '^concurrency:' '$RWF' | grep -q 'group: deploy-live' && grep -A2 '^concurrency:' '$RWF' | grep -q 'cancel-in-progress: false'"
check "release.yml: actions pinned to a commit sha" "! grep -E '^\\s*-?\\s*uses:' '$RWF' | grep -vqE '@[0-9a-f]{40}( |\$)'"
# release.yml as JSON: PyYAML, else yq (both on GitHub's Ubuntu runners).
release_yml() {
  python3 -c 'import json, sys, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$RWF" 2>/dev/null \
    || yq -o=json '.' "$RWF"
}
check "release.yml: deploy job only on v tags" "[ \"\$(release_yml | jq -r .jobs.deploy.if)\" = \"startsWith(github.ref, 'refs/tags/v')\" ]"
check "release.yml: deploy job permissions contents read, id-token write, statuses read" \
  "[ \"\$(release_yml | jq -c .jobs.deploy.permissions)\" = '{\"contents\":\"read\",\"id-token\":\"write\",\"statuses\":\"read\"}' ]"
check "release.yml: notes job permissions contents write only" "[ \"\$(release_yml | jq -c .jobs.notes.permissions)\" = '{\"contents\":\"write\"}' ]"
check "release.yml: checkout with full history, no persisted token" \
  "[ \"\$(release_yml | jq -c '.jobs.deploy.steps[] | select(.uses // \"\" | startswith(\"actions/checkout@\")) | .with')\" = '{\"fetch-depth\":0,\"persist-credentials\":false}' ]"
check "release.yml: dispatch runs are dry runs" "grep -qF \"github.event_name == 'workflow_dispatch' && '--dry-run' || ''\" '$RWF'"
check "release.yml: calls deploy/deploy.sh --env live --release" "grep -q 'deploy/deploy.sh --env live --release \"\$RELEASE\"' '$RWF'"
check "release.yml: notes after a failed deploy too, never for dry runs or dispatches" \
  "release_yml | jq -r .jobs.notes.if | grep -q '^always() && ' && release_yml | jq -r .jobs.notes.if | grep -qF \"needs.deploy.outputs.dry_run != 'true'\" && release_yml | jq -r .jobs.notes.if | grep -qF \"github.event_name == 'push'\""

# The notes step, run as the workflow would, with a fake gh that holds one release.
# The variables are meant for this subshell only (rollback_notes_step sets its own).
# shellcheck disable=SC2030
notes_step() { # RESULT FAILED_STEP BACKUP [PACKAGE_SHA256] [prerelease]
  T=$(mktemp -d); mkdir -p "$T/bin"
  release_yml | jq -r '.jobs.notes.steps[] | select(.name | test("Live deploy")) | .run' > "$T/notes.sh"
  jq -n --argjson pre "${5:-false}" '{id: 7, draft: false, prerelease: $pre, body: "## Staging proof\n\n- sha256: `abc`"}' > "$T/release.json"
  cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE/gh.log"
args=("$@")
for i in "${!args[@]}"; do
  [ "${args[$i]}" = -f ] && [[ "${args[$((i + 1))]}" == body=* ]] && printf '%s' "${args[$((i + 1))]#body=}" > "$FAKE/new-body"
done
case "$*" in
  "api -X PATCH repos/romafederico/romafederico.com/releases/7"*) echo '{}';;
  "api repos/romafederico/romafederico.com/releases/tags/v1.0.0"*) cat "$FAKE/release.json";;
  *) echo "fake gh: unexpected $*" >&2; exit 1;;
esac
EOF
  chmod +x "$T/bin/gh"
  (export FAKE="$T" PATH="$T/bin:$PATH" GITHUB_STEP_SUMMARY="$T/summary.md" GITHUB_REPOSITORY=romafederico/romafederico.com \
     RELEASE=v1.0.0 RESULT="$1" FAILED_STEP="$2" BACKUP="$3" PACKAGE="romafederico-site-$SHA.tar.gz" PACKAGE_SHA256="${4-$NSUM}" \
     RUN_URL=https://github.com/romafederico/romafederico.com/actions/runs/9/attempts/1
   bash -e "$T/notes.sh") > "$T/out.log" 2>&1
  echo $? > "$T/rc"
}
NSUM=$(printf 'a%.0s' {1..64})
notes_step success "" live-20261103-120000-v1-0-0
check "notes: success appends a Live deploy section below the old body" \
  '[ "$(cat $T/rc)" = 0 ] && grep -qx "## Live deploy" $T/new-body && [ "$(head -n1 $T/new-body)" = "## Staging proof" ] || { cat $T/out.log; false; }'
check "notes: package, sha256, backup, run and time" \
  'grep -qxF -- "- Package: romafederico-site-$SHA.tar.gz, sha256 $NSUM" $T/new-body &&
   grep -qxF -- "- Backup before deploy: live-20261103-120000-v1-0-0.tgz (in ~/rf-backups)" $T/new-body &&
   grep -qxF -- "- Run: https://github.com/romafederico/romafederico.com/actions/runs/9/attempts/1" $T/new-body &&
   grep -qE -- "^- At: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$" $T/new-body'
check "notes: also in the run summary" 'grep -qx "## Live deploy" $T/summary.md'
rm -rf "$T"
notes_step failure install live-20261103-120000-v1-0-0
check "notes: failed run marked FAILED at the step, with the backup" \
  'grep -qx "## Live deploy: FAILED at install" $T/new-body && grep -q "live-20261103-120000-v1-0-0.tgz" $T/new-body'
rm -rf "$T"
notes_step failure guards "" ""
check "notes: failed before a backup says none was made" \
  'grep -qx "## Live deploy: FAILED at guards" $T/new-body && grep -qxF -- "- Backup before deploy: none made" $T/new-body && grep -qxF -- "- Package: not checked" $T/new-body'
rm -rf "$T"
notes_step cancelled "" ""
check "notes: cancelled with no step known still noted" 'grep -q "^## Live deploy: FAILED at an unknown step" $T/new-body'
rm -rf "$T"
notes_step success "" live-20261103-120000-v1-0-0 "$NSUM" true
check "notes: a pre-release gets no Live deploy section" '[ "$(cat $T/rc)" = 0 ] && [ ! -e $T/new-body ] && ! grep -q PATCH $T/gh.log'
rm -rf "$T"

echo "# 17. rollback-live.yml (#12): guard rails, and its notes step with a fake gh"
KWF="$ROOT/.github/workflows/rollback-live.yml"
rollback_yml() {
  python3 -c 'import json, sys, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$KWF" 2>/dev/null \
    || yq -o=json '.' "$KWF"
}
check "rollback-live.yml: exists, name Rollback live" "grep -qx 'name: Rollback live' '$KWF'"
check "rollback-live.yml: workflow_dispatch only" "[ \"\$(rollback_yml | jq -c '.on // .[\"true\"] | keys')\" = '[\"workflow_dispatch\"]' ]"
check "rollback-live.yml: input dry_run, boolean, default true" \
  "[ \"\$(rollback_yml | jq -c '(.on // .[\"true\"]).workflow_dispatch.inputs.dry_run | [.type, .default]')\" = '[\"boolean\",true]' ]"
check "rollback-live.yml: no secrets.* or vars.*" "! grep -nE '(secrets|vars)\\.' '$KWF'"
check "rollback-live.yml: permissions: {} at the top" "grep -qx 'permissions: {}' '$KWF'"
check "rollback-live.yml: concurrency deploy-live (as release.yml), never cancelled" \
  "[ \"\$(rollback_yml | jq -c .concurrency)\" = '{\"group\":\"deploy-live\",\"cancel-in-progress\":false}' ] && [ \"\$(release_yml | jq -c .concurrency)\" = \"\$(rollback_yml | jq -c .concurrency)\" ]"
check "rollback-live.yml: actions pinned to a commit sha" "! grep -E '^\\s*-?\\s*uses:' '$KWF' | grep -vqE '@[0-9a-f]{40}( |\$)'"
check "rollback-live.yml: deploy job only on v tags" "[ \"\$(rollback_yml | jq -r .jobs.deploy.if)\" = \"startsWith(github.ref, 'refs/tags/v')\" ]"
check "rollback-live.yml: deploy job permissions contents read, id-token write, statuses read" \
  "[ \"\$(rollback_yml | jq -c .jobs.deploy.permissions)\" = '{\"contents\":\"read\",\"id-token\":\"write\",\"statuses\":\"read\"}' ]"
check "rollback-live.yml: first step checks deploy/live-actors of the tag" \
  "rollback_yml | jq -r '.jobs.deploy.steps[0].run' | grep -q 'contents/deploy/live-actors?ref=\$GITHUB_SHA'"
check "rollback-live.yml: checkout with full history, no persisted token" \
  "[ \"\$(rollback_yml | jq -c '.jobs.deploy.steps[] | select(.uses // \"\" | startswith(\"actions/checkout@\")) | .with')\" = '{\"fetch-depth\":0,\"persist-credentials\":false}' ]"
check "rollback-live.yml: calls deploy/deploy.sh --env live --rollback" "grep -q 'deploy/deploy.sh --env live --rollback \"\$RELEASE\" \$DRY_RUN_FLAG' '$KWF'"
check "rollback-live.yml: dry_run input gives --dry-run" "grep -qF \"inputs.dry_run && '--dry-run' || ''\" '$KWF'"
check "rollback-live.yml: notes job permissions contents write only, after every run on a tag" \
  "[ \"\$(rollback_yml | jq -c .jobs.notes.permissions)\" = '{\"contents\":\"write\"}' ] && [ \"\$(rollback_yml | jq -r .jobs.notes.if)\" = \"always() && startsWith(github.ref, 'refs/tags/v')\" ]"

check "rollback-live.yml: notes take dry_run from the input (deploy.sh's output is empty when refused early)" \
  "[ \"\$(rollback_yml | jq -r .jobs.notes.env.DRY_RUN)\" = '\${{ inputs.dry_run }}' ] && ! grep -q 'outputs.dry_run' '$KWF'"

# The rollback notes step, run as the workflow would, with a fake gh that holds one release.
# Its own copies of notes_step's variables, in a subshell too.
# shellcheck disable=SC2031
rollback_notes_step() { # RESULT DRY_RUN BACKUP [body file]
  T=$(mktemp -d); mkdir -p "$T/bin"
  rollback_yml | jq -r '.jobs.notes.steps[] | select(.name | test("rollback")) | .run' > "$T/notes.sh"
  jq -n --rawfile b "${4:-/dev/null}" '{id: 7, draft: false, prerelease: false, body: (if $b == "" then "## Staging proof\n\n- sha256: `abc`" else $b end)}' > "$T/release.json"
  cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE/gh.log"
args=("$@")
for i in "${!args[@]}"; do
  [ "${args[$i]}" = -f ] && [[ "${args[$((i + 1))]}" == body=* ]] && printf '%s' "${args[$((i + 1))]#body=}" > "$FAKE/new-body"
done
case "$*" in
  "api -X PATCH repos/romafederico/romafederico.com/releases/7"*) echo '{}';;
  "api repos/romafederico/romafederico.com/releases/tags/v1.0.0"*) cat "$FAKE/release.json";;
  *) echo "fake gh: unexpected $*" >&2; exit 1;;
esac
EOF
  chmod +x "$T/bin/gh"
  (export FAKE="$T" PATH="$T/bin:$PATH" GITHUB_STEP_SUMMARY="$T/summary.md" GITHUB_REPOSITORY=romafederico/romafederico.com \
     RELEASE=v1.0.0 ACTOR=romafederico RESULT="$1" DRY_RUN="$2" BACKUP="$3" \
     RUN_URL=https://github.com/romafederico/romafederico.com/actions/runs/9/attempts/1
   bash -e "$T/notes.sh") > "$T/out.log" 2>&1
  echo $? > "$T/rc"
}
rollback_notes_step success false live-20261103-120000-rollback-v1-0-0
check "rollback notes: a Live rollbacks section below the old body" \
  '[ "$(cat $T/rc)" = 0 ] && grep -qx "## Live rollbacks" $T/new-body && [ "$(head -n1 $T/new-body)" = "## Staging proof" ] || { cat $T/out.log; false; }'
check "rollback notes: one line with time, actor, result, backup and run" \
  'grep -qE -- "^- [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z rollback started by \`romafederico\`: \*\*success\*\*, backup \`live-20261103-120000-rollback-v1-0-0\`, https://github.com/romafederico/romafederico.com/actions/runs/9/attempts/1$" $T/new-body'
check "rollback notes: also in the run summary" 'grep -q "rollback started by" $T/summary.md'
BODY=$(mktemp); cp "$T/new-body" "$BODY"; rm -rf "$T"
rollback_notes_step success true live-20261103-130000-rollback-v1-0-0 "$BODY"
check "rollback notes: a second run adds a line, not a second heading; dry run marked" \
  '[ "$(grep -cx "## Live rollbacks" $T/new-body)" = 1 ] && [ "$(grep -c "rollback.* started by" $T/new-body)" = 2 ] && grep -q "rollback (dry run) started by" $T/new-body'
rm -rf "$T" "$BODY"
rollback_notes_step failure true ""
check "rollback notes: a refused dry run is listed as a dry run, no backup" \
  'grep -q "rollback (dry run) started by \`romafederico\`: \*\*failure\*\*, https://" $T/new-body'
rm -rf "$T"
rollback_notes_step failure false ""
check "rollback notes: a refused real run is listed, no backup" \
  'grep -q "rollback started by \`romafederico\`: \*\*failure\*\*, https://" $T/new-body'
rm -rf "$T"

echo "# 18. Guard rails"
WF="$ROOT/.github/workflows/deploy-staging.yml"
check "workflow exists" '[ -f "$WF" ]'
check "workflow: no secrets.* or vars.*" "! grep -nE '(secrets|vars)\\.' '$WF'"
check "workflow: permissions: {} at the top" "grep -qx 'permissions: {}' '$WF'"
check "workflow: job permissions are exactly contents/actions read, id-token/statuses write" \
  "[ \"\$(sed -n '/^    permissions:/,/^    [a-z-]*:\$/p' '$WF' | grep -E '^      [a-z-]+:' | sed 's/^ *//' | sort | tr '\\n' ' ')\" = 'actions: read contents: read id-token: write statuses: write ' ]"
check "workflow: on CI's workflow_run, main, completed" "grep -qx '    workflows: \\[CI\\]' '$WF' && grep -qx '    types: \\[completed\\]' '$WF' && grep -qx '    branches: \\[main\\]' '$WF'"
check "workflow: only successful push runs, or a manual run on main" "grep -q \"conclusion == 'success'\" '$WF' && grep -q \"workflow_run.event == 'push'\" '$WF' && grep -q \"github.ref == 'refs/heads/main'\" '$WF'"
check "workflow: concurrency deploy-staging, never cancelled" "grep -qx '  group: deploy-staging' '$WF' && grep -qx '  cancel-in-progress: false' '$WF'"
check "workflow: calls deploy/deploy.sh --env staging" "grep -q 'deploy/deploy.sh --env staging --sha' '$WF'"
check "workflow: sets staging/deploy" "grep -q 'context=staging/deploy' '$WF'"
check "workflow: actions pinned to a commit sha" "! grep -E '^\\s*-?\\s*uses:' '$WF' | grep -vqE '@[0-9a-f]{40}( |\$)'"
for f in deploy/deploy.sh deploy/smoke-test.sh "$WF" "$RWF" "$KWF"; do
  check "$f: no set -x / xtrace" "! grep -nE 'set -[a-wyz]*x|xtrace' '$ROOT/${f#"$ROOT/"}'"
done
check "smoke-test: credentials never on curl's command line (-u/--user)" "! grep -nE 'curl[^|]* (-u|--user) ' '$ROOT/deploy/smoke-test.sh'"
check "deploy.sh: sends only deploy-gate-rf commands (no scp, rsync)" "! grep -nE '\\b(scp|rsync|sftp)\\b' '$ROOT/deploy/deploy.sh' | grep -v '^[0-9]*:#'"

echo
if [ "$FAILS" -gt 0 ]; then echo "$FAILS failed"; exit 1; fi
echo "all passed"
