#!/usr/bin/env bash
# Deploy one commit's package (#5) to a pipeline environment. Called by
# .github/workflows/deploy-staging.yml (#7), .github/workflows/release.yml (#11) and
# .github/workflows/rollback-live.yml (#12).
#
#   deploy/deploy.sh --env staging --sha <40 hex>
#   deploy/deploy.sh --env live --release vX.Y.Z[-rc.N] [--dry-run]
#   deploy/deploy.sh --env live --rollback vX.Y.Z [--dry-run]
#
# Needs: GH_TOKEN (staging: actions: read, to download the artifact; live: contents: read and
# statuses: read), AWS credentials that can read the environment's SSM_PATH (the workflow assumes the
# role by OIDC), aws, gh, jq, ssh, curl; staging also unzip and docker (to make the bcrypt line with
# htpasswd from a pinned httpd image); live also git (a checkout of the tag with main's history).
#
# Staging, steps:
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
# Live (#11): the package of a published release, the very file that passed staging. Steps:
#   1. Guards, before anything reaches AWS or the server: the run's triggering actor is in
#      deploy/live-actors (as checked out from the tag); the run is on refs/tags/<release> and the
#      checkout is that tag's commit, which is on main; the release is published (not a draft) and
#      has the assets romafederico-site-<commit>.tar.gz and its .sha256; the package matches its
#      .sha256, and that checksum equals both the release's "Staging proof" sha256
#      (deploy/draft-release.sh, #10) and the commit's staging/deploy status description
#      ("sha256 <64 hex>", #7).
#   2. Read deploy/environments/live.conf and only <SSM_PATH>DEPLOY_SSH_KEY (masked).
#   3. Over SSH send only rf-live-gate commands (#8): put-package <sha256>, backup <label>
#      (the release with dots as dashes, v1.0.0 → v1-0-0: the gate allows a-z 0-9 - only),
#      install <sha256> <release>, current (must report the release and package).
#   4. deploy/smoke-test.sh --env live.
#   Dry run (--dry-run, or a pre-release: vX.Y.Z-rc.N or marked pre-release on GitHub): the guards,
#   put-package, backup and current only. Never install, no smoke test (live still runs the old site).
#
# Rollback live (#12): --rollback vA.B.C puts an earlier published release back the same way: the
# same guards (actor, tag run, on main, published, assets, Staging proof, staging/deploy), and if the
# release's notes record a "## Live deploy" (release.yml), its sha256 must be this package's too. A
# release candidate or a release marked pre-release never went live: refused. Then put-package,
# backup rollback-vA-B-C, install, current and the smoke test expecting version vA.B.C.
#
# Writes to GITHUB_OUTPUT: package_sha256=<64 hex> as soon as the package is checked (staging: for
# the staging/deploy status). Live also: commit, package, release_id and dry_run once the release is
# known, mode=release|rollback, backup=<gate's BACKUP= name> as soon as the backup exists, and failed_step=<step> on failure
# (guards, settings, put-package, backup, install, current, smoke-test), for the release notes.
# The SSH key is the only secret on disk: a mode-600 temp file, removed on exit (also on failure).
# Backticks in single quotes are Markdown for the run summary.
# shellcheck disable=SC2016
set -euo pipefail

DEPLOY_ROOT=$(cd "$(dirname "$0")" && pwd)
ENVIRONMENTS="staging live"
REPO="${GITHUB_REPOSITORY:-romafederico/romafederico.com}"
REQUIRED_PARAMS="BASIC_AUTH_USER BASIC_AUTH_PASSWORD DEPLOY_SSH_KEY"
# htpasswd from Apache's own image; bump tag and digest together.
HTPASSWD_IMAGE="httpd:2.4.69-alpine@sha256:070da7661f0be8a05430b2c125c0cde9e53176b4048c813024021969a0e3893c"

die() { echo "::error::$*" >&2; exit 1; }
log() { echo "==> $*"; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; fi; }
output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi; }

USAGE="usage: deploy.sh --env staging --sha <40 hex> | --env live --release vX.Y.Z[-rc.N] [--dry-run] | --env live --rollback vX.Y.Z [--dry-run]"
ENV_NAME=""
SHA=""
RELEASE=""
ROLLBACK_TO=""
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2;;
    --sha) SHA="${2:-}"; shift 2;;
    --release) RELEASE="${2:-}"; shift 2;;
    --rollback) ROLLBACK_TO="${2:-}"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    *) die "unknown argument: $1 ($USAGE)";;
  esac
done
case " $ENVIRONMENTS " in
  *" $ENV_NAME "*) ;;
  *) die "--env must be one of: $ENVIRONMENTS (got '$ENV_NAME')";;
esac
ROLLBACK=false
MODE=release
if [ "$ENV_NAME" = live ]; then
  # Only the logins listed may start a live deploy or rollback. The list is the one in the checked-out tag:
  # changing it needs a reviewed PR and a release.
  ACTORS_FILE="$DEPLOY_ROOT/live-actors"
  [ -f "$ACTORS_FILE" ] || die "missing $ACTORS_FILE: nobody may deploy live"
  ACTOR="${GITHUB_TRIGGERING_ACTOR:-}"
  if ! [[ "$ACTOR" =~ ^[A-Za-z0-9-]+$ ]] || ! grep -vE '^[[:space:]]*(#|$)' "$ACTORS_FILE" | grep -qxF -- "$ACTOR"; then
    die "'${ACTOR:-unset}' is not in deploy/live-actors: only those logins may start a live deploy or rollback"
  fi
  log "ok: started by $ACTOR (deploy/live-actors)"
  [ -z "$SHA" ] || die "live takes --release vX.Y.Z, not --sha: it installs the package that release's commit passed staging with"
  if [ -n "$ROLLBACK_TO" ]; then
    [ -z "$RELEASE" ] || die "--release or --rollback, not both"
    # A release candidate never went live, so there is nothing to go back to.
    [[ "$ROLLBACK_TO" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
      || die "--rollback must be vX.Y.Z, a published release (got '$ROLLBACK_TO')"
    RELEASE="$ROLLBACK_TO"
    ROLLBACK=true
    MODE=rollback
  fi
  [[ "$RELEASE" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.[1-9][0-9]*)?$ ]] \
    || die "--release must be vX.Y.Z or vX.Y.Z-rc.N (got '$RELEASE')"
  if [ -n "${BASH_REMATCH[4]}" ] && [ "$DRY_RUN" = false ]; then
    log "$RELEASE is a release candidate: dry run"
    DRY_RUN=true
  fi
  # Live deploys only from the release's own tag run (the AWS role trusts refs/tags/v* only, #3;
  # this makes the script refuse on its own too).
  [ "${GITHUB_REF:-}" = "refs/tags/$RELEASE" ] \
    || die "live deploys only from a run on tag refs/tags/$RELEASE (GITHUB_REF is '${GITHUB_REF:-unset}')"
  # The gate's backup label allows a-z 0-9 - only (#8).
  BACKUP_LABEL="${RELEASE//./-}"
  [ "$ROLLBACK" = false ] || BACKUP_LABEL="rollback-$BACKUP_LABEL"
  # Headings for the run summary.
  if [ "$ROLLBACK" = true ]; then TITLE="Rollback live to $RELEASE"; BEFORE="Backup before rollback"
  else TITLE="Live deploy $RELEASE"; BEFORE="Backup before deploy"; fi
else
  if [ -n "$RELEASE" ] || [ -n "$ROLLBACK_TO" ] || [ "$DRY_RUN" = true ]; then die "--release, --rollback and --dry-run are for live only"; fi
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "--sha must be a full commit sha, 40 hex (got '$SHA')"
  VERSION="sha-${SHA:0:7}"
fi

WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/deploy.XXXXXX")
KEY_FILE="$WORK/key"
STEP=guards     # live: the step running now, for failed_step
BACKUP=""

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

on_exit() {
  local rc=$?
  set +e
  if [ "$rc" != 0 ] && [ "$ENV_NAME" = live ]; then
    output failed_step "$STEP"
    {
      echo
      echo "### $TITLE failed at $STEP"
      echo
      case "$STEP" in
        guards|settings|put-package) echo "The live site was not changed: nothing was installed.";;
        backup) echo "The live site was not changed: the backup did not complete, so nothing was installed.";;
        install) echo "The gate puts the previous site folder back if the install fails; check the gate's messages above.";;
        *) if [ "$ROLLBACK" = true ]; then
             echo "**$RELEASE is installed on the live site**, but the checks after it failed; see above."
           else
             echo "**The new package is installed on the live site**, but the checks after it failed; see above."
             echo "To go back: Federico orders **Rollback live** on the previous release's tag (#12)."
           fi;;
      esac
      echo
      if [ -n "$BACKUP" ]; then
        echo "- $BEFORE: \`$BACKUP\` (.tgz in ~/rf-backups)"
      else
        echo "- $BEFORE: none made"
      fi
    } > "$WORK/failure.md"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$WORK/failure.md" >> "$GITHUB_STEP_SUMMARY"; else cat "$WORK/failure.md"; fi
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap on_exit EXIT

# --- Live --------------------------------------------------------------------

deploy_live() {
  local commit release_json release_id prerelease ids f sum_name proofs state description deployed out current smoke_rc key

  # 1. Guards. The checkout (fetch-depth 0) is the tagged commit; main is fetched fresh.
  log "Release guards for $RELEASE"
  commit=$(git rev-parse --verify -q "refs/tags/$RELEASE^{commit}" || true)
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "tag $RELEASE not found in the checkout"
  [ "$(git rev-parse HEAD)" = "$commit" ] || die "the checkout is not the commit tagged $RELEASE ($commit)"
  git fetch -q origin main || die "could not fetch main"
  git merge-base --is-ancestor "$commit" FETCH_HEAD || die "$RELEASE ($commit) is not on main"
  log "ok: $RELEASE is $commit, on main"

  # GitHub finds no draft by tag (a draft has no tag); check the flag anyway.
  release_json=$(gh api "repos/$REPO/releases/tags/$RELEASE" 2>/dev/null || true)
  [ "$(jq -r '.draft' <<< "$release_json" 2>/dev/null)" = false ] \
    || die "no published release $RELEASE (only Federico publishes releases; a draft does not deploy)"
  release_id=$(jq -r .id <<< "$release_json")
  [[ "$release_id" =~ ^[0-9]+$ ]] || die "release $RELEASE has no id"
  prerelease=$(jq -r '.prerelease' <<< "$release_json")
  if [ "$prerelease" = true ] && [ "$ROLLBACK" = true ]; then
    die "$RELEASE is marked pre-release on GitHub: it never went live, so there is nothing to roll back to"
  fi
  if [ "$prerelease" = true ] && [ "$DRY_RUN" = false ]; then
    log "$RELEASE is marked pre-release on GitHub: dry run"
    DRY_RUN=true
  fi
  output dry_run "$DRY_RUN"
  output release_id "$release_id"
  output commit "$commit"
  log "ok: release $RELEASE is published$([ "$prerelease" = true ] && echo ' (pre-release)')"

  PKG_NAME="romafederico-site-$commit.tar.gz"
  output package "$PKG_NAME"
  mkdir "$WORK/package"
  for f in "$PKG_NAME" "$PKG_NAME.sha256"; do
    ids=$(jq -r --arg n "$f" '[.assets[]? | select(.name == $n and .state == "uploaded") | .id] | map(tostring) | join(" ")' <<< "$release_json")
    [[ "$ids" =~ ^[0-9]+$ ]] || die "release $RELEASE has no asset $f (prepare releases with deploy/draft-release.sh)"
    gh api -H "Accept: application/octet-stream" "repos/$REPO/releases/assets/$ids" > "$WORK/package/$f" \
      || die "could not download asset $f of release $RELEASE"
  done
  PACKAGE="$WORK/package/$PKG_NAME"
  read -r PACKAGE_SHA256 sum_name < "$PACKAGE.sha256" || true
  if ! [[ "${PACKAGE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || [ "${sum_name:-}" != "$PKG_NAME" ]; then
    die "$PKG_NAME.sha256 is not '<64 hex>  $PKG_NAME'"
  fi
  (cd "$WORK/package" && sha256sum -c --quiet "$PKG_NAME.sha256") || die "$PKG_NAME does not match its .sha256"

  # The draft's "Staging proof" (#10) names the package staging ran; edits in the web form add \r.
  proofs=$(jq -r '.body // ""' <<< "$release_json" | tr -d '\r' \
    | awk '/^## /{ on = ($0 == "## Staging proof") } on' | grep -oE '^- sha256: `[0-9a-f]{64}`$' | grep -oE '[0-9a-f]{64}' | sort -u || true)
  [ -n "$proofs" ] || die "release $RELEASE has no Staging proof sha256 (prepare releases with deploy/draft-release.sh)"
  [ "$(grep -c . <<< "$proofs")" = 1 ] || die "release $RELEASE's Staging proof names more than one sha256"
  [ "$proofs" = "$PACKAGE_SHA256" ] \
    || die "$PKG_NAME is sha256 $PACKAGE_SHA256, but the release's Staging proof says $proofs"

  IFS=$'\t' read -r state description < <(gh api "repos/$REPO/commits/$commit/status" \
    -q '.statuses[] | select(.context == "staging/deploy") | [.state, .description] | @tsv') || true
  [ "${state:-}" = success ] || die "staging/deploy for $commit is '${state:-missing}', not success: it did not pass staging"
  [ "${description#sha256 }" = "$PACKAGE_SHA256" ] \
    || die "$PKG_NAME is sha256 $PACKAGE_SHA256, but staging/deploy for $commit says '$description'"
  log "ok: $PKG_NAME sha256 $PACKAGE_SHA256 = Staging proof = staging/deploy"

  if [ "$ROLLBACK" = true ]; then
    # The package live ran for this release, if it went live: every "## Live deploy" section that
    # release.yml's notes job wrote (#11), also a FAILED one, must name this sha256.
    deployed=$(jq -r '.body // ""' <<< "$release_json" | tr -d '\r' \
      | awk '/^## /{ on = ($0 ~ /^## Live deploy/) } on' | grep -oE '^- Package: [^ ]+, sha256 [0-9a-f]{64}$' \
      | grep -oE '[0-9a-f]{64}$' | sort -u || true)
    for f in $deployed; do
      [ "$f" = "$PACKAGE_SHA256" ] || die "the release notes record a live deploy of sha256 $f, not $PACKAGE_SHA256: not rolling back"
    done
    if [ -n "$deployed" ]; then log "ok: rollback to $RELEASE uses the package its Live deploy recorded"
    else log "ok: rollback to $RELEASE uses its Staging proof package (no Live deploy recorded)"; fi
  fi
  output package_sha256 "$PACKAGE_SHA256"
  output mode "$MODE"
  summary "### $TITLE$([ "$DRY_RUN" = true ] && echo ' (dry run)')" "" \
    "- Started by: \`$ACTOR\`" "- Commit: \`$commit\`" "- Package: \`$PKG_NAME\`, sha256 \`$PACKAGE_SHA256\`" ""

  # 2. Settings and the one parameter.
  STEP=settings
  read_conf DEPLOY_HOST DEPLOY_USER SITE_URL AWS_REGION SSM_PATH
  log "Reading ${SSM_PATH}DEPLOY_SSH_KEY"
  out=$(aws ssm get-parameters --names "${SSM_PATH}DEPLOY_SSH_KEY" --with-decryption \
    --region "${CONF[AWS_REGION]}" --output json) || die "could not read ${SSM_PATH}DEPLOY_SSH_KEY from Parameter Store"
  key=$(jq -r --arg n "${SSM_PATH}DEPLOY_SSH_KEY" '.Parameters[] | select(.Name == $n) | .Value' <<< "$out")
  unset out
  [ -n "$key" ] || die "missing ${SSM_PATH}DEPLOY_SSH_KEY in Parameter Store (#6): nothing was sent to the server"
  mask "$key"
  ( umask 077; printf '%s\n' "${key%$'\n'}" > "$KEY_FILE" )
  chmod 600 "$KEY_FILE"
  unset key

  # 3. Through rf-live-gate (#8). Its progress goes to stderr (the log), results to stdout.
  STEP=put-package
  log "put-package $PACKAGE_SHA256"
  out=$(gate put-package "$PACKAGE_SHA256" < "$PACKAGE") || die "put-package failed"
  echo "$out"
  grep -q "^PACKAGE=$PACKAGE_SHA256 " <<< "$out" || die "put-package did not confirm $PACKAGE_SHA256"

  STEP=backup
  log "backup $BACKUP_LABEL (site folder, ~/rf-backups)"
  out=$(gate backup "$BACKUP_LABEL" < /dev/null) || die "backup failed: nothing was installed"
  echo "$out"
  BACKUP=$(grep -oE "^BACKUP=live-[0-9]{8}-[0-9]{6}-$BACKUP_LABEL$" <<< "$out" | cut -d= -f2 || true)
  [ -n "$BACKUP" ] || die "backup did not report BACKUP=live-<stamp>-$BACKUP_LABEL: nothing was installed"
  output backup "$BACKUP"
  summary "- $BEFORE: \`$BACKUP\` (.tgz in ~/rf-backups)"

  if [ "$DRY_RUN" = true ]; then
    STEP=current
    log "dry run: not installing; live runs:"
    gate current < /dev/null || die "current failed"
    summary "" "**Dry run:** guards, put-package and backup done. No install, no smoke test; the live site was not changed."
    log "Done (dry run): $RELEASE checked, package on the server, backup $BACKUP"
    return 0
  fi

  STEP=install
  log "install $PACKAGE_SHA256 $RELEASE"
  out=$(gate install "$PACKAGE_SHA256" "$RELEASE" < /dev/null) || die "install failed"
  echo "$out"
  grep -qx "INSTALLED=$RELEASE $PACKAGE_SHA256" <<< "$out" || die "install did not confirm $RELEASE $PACKAGE_SHA256"

  STEP=current
  current=$(gate current < /dev/null) || die "current failed"
  echo "$current"
  [ "$(jq -r '[.environment, .version, .commit, .package_sha256] | join(" ")' <<< "$current" 2>/dev/null)" \
    = "live $RELEASE $commit $PACKAGE_SHA256" ] \
    || die "current reports '$current', not live $RELEASE $commit $PACKAGE_SHA256"

  # 4. Smoke test, no password on live.
  STEP=smoke-test
  log "Smoke test ${CONF[SITE_URL]}"
  set +e
  env -u BASIC_AUTH_USER -u BASIC_AUTH_PASSWORD \
    "$DEPLOY_ROOT/smoke-test.sh" --env live --commit "$commit" --version "$RELEASE" --package-sha256 "$PACKAGE_SHA256" \
    2>&1 | tee "$WORK/smoke.log"
  smoke_rc=${PIPESTATUS[0]}
  set -e
  summary "" "Smoke test:" '```' "$(cat "$WORK/smoke.log")" '```'
  [ "$smoke_rc" = 0 ] || die "smoke test failed against ${CONF[SITE_URL]}"
  STEP=finished
  log "Done: ${CONF[SITE_URL]} runs $RELEASE (sha256 $PACKAGE_SHA256), backup $BACKUP"
}

if [ "$ENV_NAME" = live ]; then
  deploy_live
  exit 0
fi

# --- Staging -----------------------------------------------------------------

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
