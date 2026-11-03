#!/usr/bin/env bash
# Live deploy gate on DreamHost (#8): the forced command of the live deploy key (#9):
#   restrict,command="/home/<user>/bin/rf-live-gate" ssh-ed25519 … rf-live-deploy
# installed as ~/bin/rf-live-gate, mode 755, from the merged deploy/dreamhost/rf-live-gate.sh.
#
# The same DreamHost user also hosts diegokravetz.com and marielgaribaldi.com
# (both live), so this script only ever touches $SITE_DIR, $BACKUP_DIR and its
# own $HOME/.rf-new-<stamp> folder. Never ~/bin, ~/.ssh, the other site
# folders, ~/dk-backups or anything else in $HOME.
#
# Commands (in $SSH_ORIGINAL_COMMAND, split on spaces, never expanded):
#   put-package <sha256>          stdin → $PKG_DIR/<sha256>.tar.gz, checked
#   backup <label>                whole site folder → $BACKUP_DIR/live-<UTC stamp>-<label>.tgz
#   install <sha256> <vX.Y.Z>     unpack site/, write version.json, swap folders; puts the old one back on failure
#   current                       $SITE_DIR/version.json, or "none"
#   prune                         keeps 5 packages, 10 backups, 10 site folders made by this script; trims gate.log
# Anything else: exit 2 and a REFUSED line in $BACKUP_DIR/gate.log. Every
# command run is logged there too (OK / FAILED). Results go to stdout,
# progress and errors to stderr.
set -euo pipefail
umask 077

# --- Fixed settings (no input changes them) ----------------------------------

SITE_DIR="$HOME/romafederico.com"
BACKUP_DIR="$HOME/rf-backups"
PKG_DIR="$BACKUP_DIR/packages"
LOG="$BACKUP_DIR/gate.log"
MAX_PACKAGE_BYTES=$((10 * 1024 * 1024))
KEEP_PACKAGES=5
KEEP_BACKUPS=10
LOG_KEEP_LINES=5000
# Names in the live folder that are not in the package but must stay (copied
# into each new folder). Only by a reviewed PR (#9 step 2).
KEEP=()

export PATH=/usr/bin:/bin

SHA_RE='^[0-9a-f]{64}$'
VERSION_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
LABEL_RE='^[a-z0-9-]{1,32}$'
# Names a package may hold (as written by deploy/build-package.sh).
PKG_NAME_RE='^(BUILD\.json|site/|site/[A-Za-z0-9._/-]+)$'
BUILD_RE='^\{"commit":"[0-9a-f]{40}"\}$'

# --- Log and exit -------------------------------------------------------------

REQUEST="${SSH_ORIGINAL_COMMAND-}"
unset SSH_ORIGINAL_COMMAND

# Cleaned up on any exit: temp files, the install's new folder, and a
# half-done swap (put back). Then one log line.
TMP_FILES=()
STAGE=""
WHEN=""
SWAPPED=""  # 1 once the live folder is out of the way, until the install is done
NO_PREV=""  # 1 if there was no live folder before (nothing to put back)
mkdir -p "$BACKUP_DIR"
on_exit() {
  local rc=$? result=FAILED
  if [ -n "$SWAPPED" ]; then
    if restore; then say "previous site folder restored"; else say "RESTORE FAILED: check $SITE_DIR"; rc=1; fi
  fi
  if [ "${#TMP_FILES[@]}" -gt 0 ]; then rm -f "${TMP_FILES[@]}"; fi
  if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi
  [ "$rc" = 0 ] && result=OK
  [ "$rc" = 2 ] && result=REFUSED
  # Non-printable characters (newlines too) become "?", so one request is one line.
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$result" \
    "$(printf '%s' "${REQUEST:0:300}" | tr -c '[:print:]' '?')" >> "$LOG" || true
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 1' HUP INT TERM PIPE

say() { echo "rf-live-gate: $*" >&2; }
refuse() { say "refused: $*"; exit 2; }
die() { say "FAILED: $*"; exit 1; }

# --- Parse: exact command name, argument count and argument shapes -------------

# Only these characters, so no quoting, expansion, separator or newline gets through.
[[ "$REQUEST" =~ ^[a-z0-9.-]+( [a-z0-9.-]+)*$ ]] || refuse "not a gate command"
IFS=' ' read -r -a ARGS <<< "$REQUEST"
CMD="${ARGS[0]}"
NARGS=$((${#ARGS[@]} - 1))

need() { # <count> <regex>... : exact argument count and shapes
  local n="$1" i=1
  shift
  [ "$NARGS" = "$n" ] || refuse "$CMD takes $n argument(s)"
  for re in "$@"; do
    [[ "${ARGS[$i]}" =~ $re ]] || refuse "$CMD: bad argument $i"
    i=$((i + 1))
  done
}

case "$CMD" in
  put-package) need 1 "$SHA_RE" ;;
  backup)      need 1 "$LABEL_RE" ;;
  install)     need 2 "$SHA_RE" "$VERSION_RE" ;;
  current)     need 0 ;;
  prune)       need 0 ;;
  *)           refuse "unknown command" ;;
esac
[ "$CMD" = put-package ] || exec < /dev/null

# One command at a time (current only reads).
if [ "$CMD" != current ]; then
  exec 9>> "$BACKUP_DIR/gate.lock"
  flock -n 9 || die "busy: another gate command is running"
fi

stamp() { date -u +%Y%m%d-%H%M%S; }

# Every entry of the package is a plain file or folder at an allowed name, and
# BUILD.json holds a commit.
check_package() { # <file>; exit 2 if it is not one of ours
  local list names
  list=$(tar --numeric-owner -tvzf "$1" 2> /dev/null) || refuse "not a gzip tar"
  names=$(tar -tzf "$1" 2> /dev/null) || refuse "not a gzip tar"
  [ -n "$names" ] || refuse "empty package"
  if grep -qv '^[-d]' <<< "$list"; then refuse "package holds links or special files"; fi
  if grep -qvE "$PKG_NAME_RE" <<< "$names"; then refuse "package holds names outside BUILD.json and site/"; fi
  if grep -qE '//|(^|/)\.\.?(/|$)' <<< "$names"; then refuse "package holds a . or .. path"; fi
  if grep -qx 'site/version.json' <<< "$names"; then refuse "package holds site/version.json (the gate writes it)"; fi
  grep -qx 'site/index.html' <<< "$names" || refuse "package has no site/index.html"
  [ "$(grep -cx 'BUILD.json' <<< "$names")" = 1 ] || refuse "package has no BUILD.json"
  [[ "$(tar -xzOf "$1" BUILD.json 2> /dev/null)" =~ $BUILD_RE ]] || refuse "BUILD.json is not {\"commit\":\"<40 hex>\"}"
}

# --- Commands -------------------------------------------------------------------

cmd_put_package() {
  local sha="$1" pkg="$PKG_DIR/$1.tar.gz" tmp got
  if [ -f "$pkg" ] && [ "$(sha256sum "$pkg" | cut -d' ' -f1)" = "$sha" ]; then
    check_package "$pkg"
    echo "PACKAGE=$sha $(stat -c %s "$pkg") bytes, already stored"
    return
  fi
  mkdir -p "$PKG_DIR"
  tmp=$(mktemp "$PKG_DIR/.incoming-XXXXXX")
  TMP_FILES+=("$tmp")
  head -c $((MAX_PACKAGE_BYTES + 1)) > "$tmp"
  [ "$(stat -c %s "$tmp")" -le "$MAX_PACKAGE_BYTES" ] || refuse "package larger than $MAX_PACKAGE_BYTES bytes"
  got=$(sha256sum "$tmp" | cut -d' ' -f1)
  [ "$got" = "$sha" ] || refuse "checksum is $got, not $sha"
  check_package "$tmp"
  mv -f "$tmp" "$pkg"
  echo "PACKAGE=$sha $(stat -c %s "$pkg") bytes"
}

cmd_backup() {
  local name file rc=0
  name="live-$(stamp)-$1"
  file="$BACKUP_DIR/$name.tgz"
  TMP_FILES+=("$file.tmp")
  [ -d "$SITE_DIR" ] || die "no site folder $SITE_DIR"
  [ ! -e "$file" ] || die "$name exists already"

  say "site folder → $name.tgz"
  # Exit 1 = a file changed while it was read: warn, keep going.
  tar -C "$(dirname "$SITE_DIR")" -czf "$file.tmp" "$(basename "$SITE_DIR")" || rc=$?
  [ "$rc" -le 1 ] || die "tar of the site folder failed"
  [ "$rc" = 0 ] || say "warning: some files changed while they were copied"
  gzip -t "$file.tmp" || die "site archive is not valid gzip"
  # More than the top folder itself.
  [ -n "$(tar -tzf "$file.tmp" | sed -n 2p)" ] || die "site archive is empty"

  mv "$file.tmp" "$file"
  echo "BACKUP=$name"
  echo "$name.tgz $(stat -c %s "$file") bytes"
}

# Puts back what the install swapped: the new folder out of $SITE_DIR, the
# site-<stamp> one back in. Runs as an `if` condition, where set -e is off, so
# every step checks itself and it returns 1 if the old folder is not back.
restore() {
  local prev="$BACKUP_DIR/site-$WHEN"
  SWAPPED=""
  if [ -e "$SITE_DIR" ] || [ -L "$SITE_DIR" ]; then
    # The new folder is in place: back to $STAGE, which on_exit removes.
    # -T: never into an existing folder.
    mv -T "$SITE_DIR" "$STAGE" || return 1
  fi
  [ -n "$NO_PREV" ] && return 0
  [ -e "$prev" ] || { say "$prev is missing"; return 1; }
  mv -T "$prev" "$SITE_DIR"
}

cmd_install() {
  local sha="$1" version="$2" pkg="$PKG_DIR/$1.tar.gz" prev commit name
  [ -f "$pkg" ] || die "no package $sha: put-package it first"
  [ "$(sha256sum "$pkg" | cut -d' ' -f1)" = "$sha" ] || die "stored package does not match $sha"
  check_package "$pkg"
  [ ! -L "$SITE_DIR" ] || die "$SITE_DIR is a symlink; not touching it"
  [[ "$(tar -xzOf "$pkg" BUILD.json)" =~ \"([0-9a-f]{40})\" ]] && commit="${BASH_REMATCH[1]}"

  WHEN=$(stamp)
  prev="$BACKUP_DIR/site-$WHEN"
  [ ! -e "$prev" ] || die "$prev exists already: one install per second"
  # In $HOME (same filesystem as $SITE_DIR and $BACKUP_DIR), so the swap is renames.
  mkdir "$HOME/.rf-new-$WHEN" || die "cannot make $HOME/.rf-new-$WHEN"
  STAGE="$HOME/.rf-new-$WHEN"
  tar -xzf "$pkg" -C "$STAGE" --no-same-owner --no-same-permissions --strip-components=1 site
  find "$STAGE" -type d -exec chmod 755 {} +
  find "$STAGE" -type f -exec chmod 644 {} +
  [ -f "$STAGE/index.html" ] || die "package has no index.html"
  if grep -qiF '<script' "$STAGE/index.html"; then die "index.html has a <script; nothing was changed"; fi

  if [ "${#KEEP[@]}" -gt 0 ]; then
    for name in "${KEEP[@]}"; do
      [ ! -e "$STAGE/$name" ] || die "package holds $name, which the gate keeps from the live folder"
      if [ -e "$SITE_DIR/$name" ]; then cp -a "$SITE_DIR/$name" "$STAGE/$name"; fi
    done
  fi

  printf '{"site":"romafederico.com","environment":"live","version":"%s","commit":"%s","package_sha256":"%s","installed_at":"%s"}\n' \
    "$version" "$commit" "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STAGE/version.json"
  chmod 644 "$STAGE/version.json"

  say "swapping in $version"
  # Only marked swapped once the live folder is out of the way: if that mv
  # fails, the live folder is untouched and restore must leave it alone.
  if [ -e "$SITE_DIR" ]; then mv -T "$SITE_DIR" "$prev"; else NO_PREV=1; fi
  SWAPPED=1
  mv -T "$STAGE" "$SITE_DIR" || die "could not move the new folder into place"
  if [ ! -r "$SITE_DIR/version.json" ] || [ ! -r "$SITE_DIR/index.html" ]; then
    die "new site folder is not readable"
  fi
  SWAPPED=""
  STAGE=""

  echo "INSTALLED=$version $sha"
  if [ -z "$NO_PREV" ]; then echo "PREVIOUS=site-$WHEN"; fi
}

cmd_current() {
  if [ -f "$SITE_DIR/version.json" ]; then cat "$SITE_DIR/version.json"; else echo none; fi
}

# Only names this script makes; anything else never matches. tail -n +N+1
# with N >= 1 never deletes the newest of each.
cmd_prune() {
  local f
  if [ -d "$PKG_DIR" ]; then
    find "$PKG_DIR" -maxdepth 1 -type f -name '.incoming-*' -mmin +1440 -delete
    find "$PKG_DIR" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9a-f]{64}\.tar\.gz' -printf '%T@ %p\n' \
      | sort -rn | tail -n +$((KEEP_PACKAGES + 1)) | cut -d' ' -f2- \
      | while IFS= read -r f; do say "removing ${f#"$BACKUP_DIR/"}"; rm -f "$f"; done
  fi
  find "$BACKUP_DIR" -maxdepth 1 -type f -regextype posix-extended -regex '.*/live-[0-9]{8}-[0-9]{6}-[a-z0-9-]{1,32}\.tgz' -printf '%f\n' \
    | sort -r | tail -n +$((KEEP_BACKUPS + 1)) \
    | while IFS= read -r f; do say "removing $f"; rm -f "${BACKUP_DIR:?}/$f"; done
  find "$BACKUP_DIR" -maxdepth 1 -type d -regextype posix-extended -regex '.*/site-[0-9]{8}-[0-9]{6}' -printf '%f\n' \
    | sort -r | tail -n +$((KEEP_BACKUPS + 1)) \
    | while IFS= read -r f; do say "removing $f"; rm -rf "${BACKUP_DIR:?}/$f"; done
  # Refused requests add a line each, so the log is trimmed here (under the lock).
  if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt "$LOG_KEEP_LINES" ]; then
    TMP_FILES+=("$LOG.tmp")
    tail -n "$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp"
    mv -f "$LOG.tmp" "$LOG"
  fi
  echo "PRUNED"
}

case "$CMD" in
  put-package) cmd_put_package "${ARGS[1]}" ;;
  backup)      cmd_backup "${ARGS[1]}" ;;
  install)     cmd_install "${ARGS[1]}" "${ARGS[2]}" ;;
  current)     cmd_current ;;
  prune)       cmd_prune ;;
esac
