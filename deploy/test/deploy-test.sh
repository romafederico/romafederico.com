#!/usr/bin/env bash
# Tests for deploy/deploy.sh and deploy/smoke-test.sh (staging #7) with fake gh, aws, ssh, docker
# and curl commands: nothing leaves the machine. Also checks the guard rails of
# .github/workflows/deploy-staging.yml.
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
check "--env production refused" '[ $code != 0 ] && grep -q "env must be one of: staging" $T/out.log'
"$ROOT/deploy/deploy.sh" --env live --sha "$SHA" > "$T/out.log" 2>&1; code=$?
check "--env live refused (#11)" '[ $code != 0 ] && grep -q "env must be one of: staging" $T/out.log'
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
"$ROOT/deploy/smoke-test.sh" --env live --commit "$SHA" > "$T/out.log" 2>&1; code=$?
check "smoke-test: --env live refused (#11)" "[ $code != 0 ] && grep -q 'env must be staging' \$T/out.log && [ ! -e \$T/curl.log ]"
rm -rf "$T"

echo "# 10. Guard rails"
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
for f in deploy/deploy.sh deploy/smoke-test.sh "$WF"; do
  check "$f: no set -x / xtrace" "! grep -nE 'set -[a-wyz]*x|xtrace' '$ROOT/${f#"$ROOT/"}'"
done
check "smoke-test: credentials never on curl's command line (-u/--user)" "! grep -nE 'curl[^|]* (-u|--user) ' '$ROOT/deploy/smoke-test.sh'"
check "deploy.sh: sends only deploy-gate-rf commands (no scp, rsync)" "! grep -nE '\\b(scp|rsync|sftp)\\b' '$ROOT/deploy/deploy.sh' | grep -v '^[0-9]*:#'"

echo
if [ "$FAILS" -gt 0 ]; then echo "$FAILS failed"; exit 1; fi
echo "all passed"
