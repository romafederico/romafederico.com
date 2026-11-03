#!/usr/bin/env bash
# Deploy one commit's package (#5) to a pipeline environment. Called by
# .github/workflows/deploy-staging.yml (#7); live (#11) adds --env live here.
#
#   deploy/deploy.sh --env staging --sha <40 hex>
#
# Needs: GH_TOKEN (actions: read, to download the artifact), AWS credentials that can read the
# environment's SSM_PATH (the workflow assumes the role by OIDC), aws, gh, jq, ssh, curl, unzip, and
# docker (to make the bcrypt line with htpasswd from a pinned httpd image).
#
# Steps:
#   1. Download artifact package-<sha> that CI uploaded for that commit on main and check its .sha256.
#      Never rebuilds: if the artifact is gone (kept 90 days), stop.
#   2. Read deploy/environments/<env>.conf (as data, known keys only) and Parameter Store <SSM_PATH>*.
#      Every value is masked before anything else runs. Stop, naming them, if any of REQUIRED_PARAMS
#      are missing.
#   3. Make the htpasswd line (bcrypt) from BASIC_AUTH_USER / BASIC_AUTH_PASSWORD; the password goes
#      in on stdin and never leaves the runner.
#   4. Over SSH send only deploy-gate-rf commands (#2): put-htpasswd, put-package <sha256>,
#      install <sha256> sha-<7>, current (must report the install), prune.
#   5. deploy/smoke-test.sh --env <env>. A failed smoke test fails the deploy; nothing is undone
#      (staging keeps the new install; a manual run with the previous sha puts the old one back).
#
# Writes package_sha256=<64 hex> to GITHUB_OUTPUT as soon as the package is checked (for the
# staging/deploy status). The SSH key is the only secret on disk: a mode-600 temp file, removed on
# exit (also on failure).
# Backticks in single quotes are Markdown for the run summary.
# shellcheck disable=SC2016
set -euo pipefail

DEPLOY_ROOT=$(cd "$(dirname "$0")" && pwd)
ENVIRONMENTS="staging"
REPO="${GITHUB_REPOSITORY:-romafederico/romafederico.com}"
REQUIRED_PARAMS="BASIC_AUTH_USER BASIC_AUTH_PASSWORD DEPLOY_SSH_KEY"
# htpasswd from Apache's own image; bump tag and digest together.
HTPASSWD_IMAGE="httpd:2.4.69-alpine@sha256:070da7661f0be8a05430b2c125c0cde9e53176b4048c813024021969a0e3893c"

die() { echo "::error::$*" >&2; exit 1; }
log() { echo "==> $*"; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; fi; }
output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi; }

USAGE="usage: deploy.sh --env staging --sha <40 hex>"
ENV_NAME=""
SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2;;
    --sha) SHA="${2:-}"; shift 2;;
    *) die "unknown argument: $1 ($USAGE)";;
  esac
done
case " $ENVIRONMENTS " in
  *" $ENV_NAME "*) ;;
  *) die "--env must be one of: $ENVIRONMENTS (got '$ENV_NAME')";;
esac
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "--sha must be a full commit sha, 40 hex (got '$SHA')"
VERSION="sha-${SHA:0:7}"

WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/deploy.XXXXXX")
KEY_FILE="$WORK/key"
trap 'rm -rf "$WORK"' EXIT

# Read deploy/environments/<env>.conf as data, not as a script: only these keys. Sets CONF, CONF_FILE,
# KNOWN_HOSTS and SSM_PATH. Arguments: the keys that must be set.
declare -A CONF=()
read_conf() {
  local line key f
  CONF_FILE="$DEPLOY_ROOT/environments/$ENV_NAME.conf"
  KNOWN_HOSTS="$DEPLOY_ROOT/environments/$ENV_NAME.known_hosts"
  for f in "$CONF_FILE" "$KNOWN_HOSTS"; do
    [ -f "$f" ] || die "missing $f"
  done
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    key="${line%%=*}"
    case "$key" in
      DEPLOY_HOST|DEPLOY_USER|DEPLOY_DIR|SITE_URL|AWS_REGION|AWS_ROLE_ARN|SSM_PATH)
        CONF[$key]="${line#*=}";;
      *) die "$CONF_FILE: unknown setting '$key'";;
    esac
  done < "$CONF_FILE"
  for key in "$@"; do
    [ -n "${CONF[$key]:-}" ] || die "$CONF_FILE: $key is not set"
  done
  SSM_PATH="${CONF[SSM_PATH]}"
  [[ "$SSM_PATH" == /*/ ]] || die "$CONF_FILE: SSM_PATH must start and end with / (got '$SSM_PATH')"
}

# Mask a value before anything else can print it (each line of multi-line ones).
mask() {
  local part
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    while IFS= read -r part; do
      [ -n "$part" ] && echo "::add-mask::$part"
    done <<< "$1"
  fi
  return 0
}

gate() {
  ssh -F /dev/null -i "$KEY_FILE" \
    -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null \
    "${CONF[DEPLOY_USER]}@${CONF[DEPLOY_HOST]}" "$*"
}

# --- 1. Package --------------------------------------------------------------

ARTIFACT="package-$SHA"
PKG_NAME="romafederico-site-$SHA.tar.gz"
log "Downloading artifact $ARTIFACT"
# Only CI's push-to-main runs upload it (ci.yml, job package); the checks below keep it to this repo's main.
artifact_id=$(gh api "repos/$REPO/actions/artifacts?name=$ARTIFACT&per_page=100" \
  | jq -r --arg sha "$SHA" '[.artifacts[]
      | select(.expired == false and .workflow_run.head_sha == $sha and .workflow_run.head_branch == "main"
               and .workflow_run.head_repository_id == .workflow_run.repository_id)]
      | sort_by(.created_at) | last | .id // empty') \
  || die "could not list artifacts for $REPO"
if [ -z "$artifact_id" ]; then
  summary "### Deploy to $ENV_NAME stopped: no package" "" \
    "No artifact \`$ARTIFACT\` from CI on main. CI keeps it 90 days and the deploy never rebuilds." \
    "Deploy a newer commit on main instead."
  die "no artifact $ARTIFACT from CI on main (expired after 90 days, or CI did not upload it): not rebuilding"
fi
gh api "repos/$REPO/actions/artifacts/$artifact_id/zip" > "$WORK/package.zip" || die "could not download artifact $ARTIFACT"
mkdir "$WORK/package"
unzip -q "$WORK/package.zip" -d "$WORK/package" || die "artifact $ARTIFACT is not a zip"
[ "$(cd "$WORK/package" && find . -mindepth 1 | sort | tr '\n' ' ')" = "./$PKG_NAME ./$PKG_NAME.sha256 " ] \
  || die "artifact $ARTIFACT must hold exactly $PKG_NAME and $PKG_NAME.sha256"
PACKAGE="$WORK/package/$PKG_NAME"
read -r PACKAGE_SHA256 sum_name < "$PACKAGE.sha256" || true
if ! [[ "${PACKAGE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || [ "${sum_name:-}" != "$PKG_NAME" ]; then
  die "$PKG_NAME.sha256 is not '<64 hex>  $PKG_NAME'"
fi
(cd "$WORK/package" && sha256sum -c --quiet "$PKG_NAME.sha256") || die "$PKG_NAME does not match its .sha256"
log "ok: $PKG_NAME sha256 $PACKAGE_SHA256"
output package_sha256 "$PACKAGE_SHA256"

# --- 2. Settings -------------------------------------------------------------

read_conf DEPLOY_HOST DEPLOY_USER SITE_URL AWS_REGION SSM_PATH

log "Reading parameters under $SSM_PATH"
declare -A PARAM=()
params_json=$(aws ssm get-parameters-by-path --path "$SSM_PATH" --with-decryption \
  --region "${CONF[AWS_REGION]}" --output json) || die "could not read $SSM_PATH from Parameter Store"
while IFS=$'\t' read -r name value_b64; do
  PARAM[$name]=$(printf '%s' "$value_b64" | base64 -d)
done < <(jq -r --arg p "$SSM_PATH" '.Parameters[]
           | select(.Name | startswith($p))
           | [(.Name | ltrimstr($p)), (.Value | @base64)] | @tsv' <<< "$params_json")
unset params_json

# Mask every value before anything else can print it.
for name in "${!PARAM[@]}"; do
  [ -z "${PARAM[$name]}" ] || mask "${PARAM[$name]}"
done

missing=()
for name in $REQUIRED_PARAMS; do
  [ -n "${PARAM[$name]:-}" ] || missing+=("$SSM_PATH$name")
done
if [ ${#missing[@]} -gt 0 ]; then
  summary "### Deploy to $ENV_NAME stopped: missing parameters" "" \
    "Nothing was sent to the server. Create these in Parameter Store (#6):" "" \
    "$(printf -- '- `%s`\n' "${missing[@]}")"
  die "missing required parameters in Parameter Store: ${missing[*]}"
fi
# The gate's put-htpasswd allows these user names only (#2).
[[ "${PARAM[BASIC_AUTH_USER]}" =~ ^[a-z0-9_-]{1,32}$ ]] \
  || die "${SSM_PATH}BASIC_AUTH_USER must match ^[a-z0-9_-]{1,32}\$ (deploy-gate-rf put-htpasswd)"

# --- 3. htpasswd line --------------------------------------------------------

# bcrypt, cost 10; the password goes in on stdin, only the hash goes to the server.
htline=$(printf '%s\n' "${PARAM[BASIC_AUTH_PASSWORD]}" \
  | docker run --rm -i "$HTPASSWD_IMAGE" htpasswd -niB -C 10 "${PARAM[BASIC_AUTH_USER]}" 2>/dev/null | head -n1) \
  || die "could not make the htpasswd line with $HTPASSWD_IMAGE"
mask "$htline"
[[ "$htline" =~ ^[a-z0-9_-]{1,32}:\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]] \
  || die "htpasswd did not print a 'user:bcrypt' line (deploy-gate-rf put-htpasswd would refuse it)"

# --- 4. Deploy through the gate ----------------------------------------------

( umask 077; printf '%s\n' "${PARAM[DEPLOY_SSH_KEY]%$'\n'}" > "$KEY_FILE" )
chmod 600 "$KEY_FILE"

log "put-htpasswd (bcrypt line, masked)"
printf '%s\n' "$htline" | gate put-htpasswd || die "put-htpasswd failed"
unset htline
log "put-package $PACKAGE_SHA256"
gate put-package "$PACKAGE_SHA256" < "$PACKAGE" || die "put-package failed"
log "install $PACKAGE_SHA256 $VERSION"
out=$(gate install "$PACKAGE_SHA256" "$VERSION" < /dev/null) || die "install failed"
echo "$out"
grep -qxF "installed $VERSION ($PACKAGE_SHA256)" <<< "$out" || die "install did not confirm $VERSION ($PACKAGE_SHA256)"
log "current"
current=$(gate current < /dev/null) || die "current failed"
echo "$current"
[ "$(jq -r '[.environment, .version, .commit, .package_sha256] | join(" ")' <<< "$current" 2>/dev/null)" \
  = "$ENV_NAME $VERSION $SHA $PACKAGE_SHA256" ] \
  || die "current reports '$current', not $ENV_NAME $VERSION $SHA $PACKAGE_SHA256"
log "prune"
gate prune < /dev/null || die "prune failed"

# --- 5. Smoke test -----------------------------------------------------------

log "Smoke test ${CONF[SITE_URL]}"
set +e
BASIC_AUTH_USER="${PARAM[BASIC_AUTH_USER]}" BASIC_AUTH_PASSWORD="${PARAM[BASIC_AUTH_PASSWORD]}" \
  "$DEPLOY_ROOT/smoke-test.sh" --env "$ENV_NAME" --commit "$SHA" --version "$VERSION" --package-sha256 "$PACKAGE_SHA256" \
  2>&1 | tee "$WORK/smoke.log"
smoke_rc=${PIPESTATUS[0]}
set -e
summary "### Deploy to $ENV_NAME" "" \
  "- Site: ${CONF[SITE_URL]}" "- Commit: \`$SHA\` ($VERSION)" "- Package: \`$PKG_NAME\`, sha256 \`$PACKAGE_SHA256\`" "" \
  "Smoke test:" '```' "$(cat "$WORK/smoke.log")" '```'
[ "$smoke_rc" = 0 ] || die "smoke test failed against ${CONF[SITE_URL]}"
log "Done: ${CONF[SITE_URL]} runs $VERSION (sha256 $PACKAGE_SHA256)"
