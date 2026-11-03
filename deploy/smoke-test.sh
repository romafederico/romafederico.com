#!/usr/bin/env bash
# Smoke test after a deploy (staging #7, live #11). The site is SITE_URL from
# deploy/environments/<env>.conf.
#
#   BASIC_AUTH_USER=… BASIC_AUTH_PASSWORD=… deploy/smoke-test.sh --env staging --commit <40 hex> \
#     [--version sha-xxxxxxx] [--package-sha256 <64 hex>]
#   deploy/smoke-test.sh --env live --commit <40 hex> --version vX.Y.Z [--package-sha256 <64 hex>]
#
# Both: /version.json reports that commit (and version and package, if given) and the environment;
# polled with a cache-busting query (the new site shows up right after `install`; DreamHost may cache
# for up to 10 minutes, so live polls up to 2 minutes by default).
# staging (password on every request):
#   - / is 200, contains "Federico Roma", has no <script and has X-Robots-Tag: noindex;
#   - /style.css and /avatar.jpg are 200;
#   - /robots.txt has a "Disallow: /" line (nginx answers it without the login, #2);
#   - /README.md is 404 (the package holds only site files);
#   - without credentials, / and /version.json are 401.
# live (no password, never sent one):
#   - / and https://www.<host>/ are 200, contain "Federico Roma" and have no <script;
#   - /style.css and /avatar.jpg are 200;
#   - /README.md is 404.
# Exit 0 = passed. SMOKE_TIMEOUT (seconds, default 60 on staging, 120 on live) and SMOKE_INTERVAL
# (default 5) tune the poll.
set -euo pipefail

DEPLOY_ROOT=$(cd "$(dirname "$0")" && pwd)
USAGE="usage: smoke-test.sh --env staging|live --commit <40 hex> [--version <version>] [--package-sha256 <64 hex>]"
ENV_NAME=""
COMMIT=""
VERSION=""
PACKAGE_SHA256=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2;;
    --commit) COMMIT="${2:-}"; shift 2;;
    --version) VERSION="${2:-}"; shift 2;;
    --package-sha256) PACKAGE_SHA256="${2:-}"; shift 2;;
    *) echo "smoke-test: unknown argument: $1 ($USAGE)" >&2; exit 2;;
  esac
done
case "$ENV_NAME" in
  staging) ;;
  live) unset BASIC_AUTH_USER BASIC_AUTH_PASSWORD
        [ -n "$VERSION" ] || { echo "smoke-test: --env live needs --version" >&2; exit 2; };;
  *) echo "smoke-test: --env must be staging or live (got '$ENV_NAME')" >&2; exit 2;;
esac
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "smoke-test: --commit must be 40 hex (got '$COMMIT')" >&2; exit 2; }
[ -z "$PACKAGE_SHA256" ] || [[ "$PACKAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "smoke-test: --package-sha256 must be 64 hex" >&2; exit 2; }
[ "$ENV_NAME" = live ] || { [ -n "${BASIC_AUTH_USER:-}" ] && [ -n "${BASIC_AUTH_PASSWORD:-}" ]; } \
  || { echo "smoke-test: staging needs BASIC_AUTH_USER and BASIC_AUTH_PASSWORD" >&2; exit 2; }

CONF_FILE="$DEPLOY_ROOT/environments/$ENV_NAME.conf"
SITE_URL=$(grep -E '^SITE_URL=' "$CONF_FILE" | cut -d= -f2- || true)
[[ "$SITE_URL" =~ ^https://[a-z0-9.-]+$ ]] || { echo "smoke-test: SITE_URL in $CONF_FILE must be https://<host> (got '$SITE_URL')" >&2; exit 2; }
if [ "$ENV_NAME" = live ]; then TIMEOUT="${SMOKE_TIMEOUT:-120}"; else TIMEOUT="${SMOKE_TIMEOUT:-60}"; fi
INTERVAL="${SMOKE_INTERVAL:-5}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
BODY="$WORK/body"
HEAD="$WORK/head"
# Staging: the credentials go to curl in a mode-600 config file, so they never show on a command line.
AUTH=""
if [ "$ENV_NAME" = staging ]; then
  AUTH="$WORK/curl-auth"
  esc() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }
  ( umask 077; printf 'user = "%s:%s"\n' "$(esc "$BASIC_AUTH_USER")" "$(esc "$BASIC_AUTH_PASSWORD")" > "$AUTH" )
fi

# req [--no-auth] <path or https:// URL> → body in $BODY, headers in $HEAD, prints the HTTP status.
# Never follows redirects; -q ignores any ~/.curlrc.
req() {
  local auth=() url
  [ -z "$AUTH" ] || auth=(-K "$AUTH")
  if [ "$1" = --no-auth ]; then auth=(); shift; fi
  case "$1" in https://*) url="$1";; *) url="$SITE_URL$1";; esac
  : > "$BODY"; : > "$HEAD"
  curl -q -sS --max-time 15 "${auth[@]}" -o "$BODY" -D "$HEAD" -w '%{http_code}' "$url" 2>/dev/null || true   # curl prints 000 itself when it cannot connect
}
header() { tr -d '\r' < "$HEAD" | grep -i "^$1:" | tail -n1 | cut -d: -f2- | sed 's/^ *//' || true; }

echo "Waiting up to ${TIMEOUT}s for $SITE_URL/version.json to report $COMMIT${VERSION:+ $VERSION}"
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  status=$(req "/version.json?t=$(date +%s)")
  got=""
  if [ "$status" = 200 ]; then
    got=$(jq -r '[.environment, .commit, .version, .package_sha256] | map(. // "none") | join(" ")' "$BODY" 2>/dev/null || true)
  fi
  read -r g_env g_commit g_version g_package <<< "${got:-none none none none}"
  if [ "$g_env" = "$ENV_NAME" ] && [ "$g_commit" = "$COMMIT" ] \
    && { [ -z "$VERSION" ] || [ "$g_version" = "$VERSION" ]; } \
    && { [ -z "$PACKAGE_SHA256" ] || [ "$g_package" = "$PACKAGE_SHA256" ]; }; then
    echo "ok   /version.json → $ENV_NAME $COMMIT${VERSION:+ $VERSION}${PACKAGE_SHA256:+ package $PACKAGE_SHA256}"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FAIL /version.json: HTTP $status, environment '$g_env' commit '$g_commit' version '$g_version' package '$g_package'," \
      "expected $ENV_NAME $COMMIT${VERSION:+ $VERSION}${PACKAGE_SHA256:+ $PACKAGE_SHA256}" >&2
    exit 1
  fi
  sleep "$INTERVAL"
done

failed=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*" >&2; failed=1; }

HOME_PAGES=(/)
[ "$ENV_NAME" = staging ] || HOME_PAGES+=("https://www.${SITE_URL#https://}/")
for page in "${HOME_PAGES[@]}"; do
  status=$(req "$page")
  if [ "$status" != 200 ]; then
    bad "$page: HTTP $status"
    continue
  fi
  if grep -q 'Federico Roma' "$BODY"; then ok "$page → 200, has 'Federico Roma'"; else bad "$page: 200 but no 'Federico Roma'"; fi
  if grep -qi '<script' "$BODY"; then bad "$page: has <script (the site has no JavaScript)"; else ok "$page has no <script"; fi
  if [ "$ENV_NAME" = staging ]; then
    robots=$(header X-Robots-Tag)
    if [[ "$robots" == *noindex* ]]; then ok "$page X-Robots-Tag: $robots"; else bad "$page: no X-Robots-Tag noindex (got '${robots:-none}')"; fi
  fi
done

for path in /style.css /avatar.jpg; do
  status=$(req "$path")
  if [ "$status" = 200 ]; then ok "$path → 200"; else bad "$path: HTTP $status"; fi
done

if [ "$ENV_NAME" = staging ]; then
  status=$(req /robots.txt)
  if [ "$status" = 200 ] && tr -d '\r' < "$BODY" | grep -qx 'Disallow: /'; then
    ok "/robots.txt → 200, Disallow: /"
  else
    bad "/robots.txt: HTTP $status, needs a 'Disallow: /' line (staging must not be indexed)"
  fi
fi

status=$(req /README.md)
if [ "$status" = 404 ]; then ok "/README.md → 404"; else bad "/README.md: HTTP $status, expected 404 (only site files are deployed)"; fi

if [ "$ENV_NAME" = staging ]; then
  for path in / /version.json; do
    status=$(req --no-auth "$path")
    if [ "$status" = 401 ]; then ok "$path without credentials → 401"; else bad "$path without credentials: HTTP $status, expected 401"; fi
  done
fi

exit "$failed"
