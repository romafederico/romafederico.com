#!/usr/bin/env bash
# Build the one package for this commit (#5): exactly the files that go to a
# server. Staging and live install this file and nothing else, and the live
# deploy checks its sha256 against what passed staging.
#
#   deploy/build-package.sh [<out dir>]     (default: dist/)
#
# Writes <out dir>/romafederico-site-<full sha>.tar.gz and its .sha256
# (sha256sum format) and prints the checksum as the last line. Contents:
#   site/<each file in deploy/site-files>   what the web server serves
#   BUILD.json = {"commit":"<full sha>"}    outside site/, so it is never served
# Only committed files (git archive HEAD), so the work tree must be clean.
# Reproducible: sorted names, mtime = commit time, owner 0/0, fixed modes,
# gzip -n.
#
# /version.json is not in here: the gates (deploy-gate-rf #2, rf-live-gate #8)
# write it into the installed site/ at install time, so the checksum is the same
# on staging and live. One line, this format, no other fields:
#   {"site":"romafederico.com","environment":"live","version":"v1.0.0","commit":"<40 hex>","package_sha256":"<64 hex>","installed_at":"2026-11-10T12:00:00Z"}
#   environment     "staging" or "live", fixed in each gate
#   version         "vX.Y.Z" (live) or "sha-<first 7 of commit>" (staging)
#   commit          from BUILD.json
#   package_sha256  the checksum this script prints
#   installed_at    UTC, seconds, Z
# No JavaScript reads it and nothing on the page links to it. Local preview has none.
# Needs GNU tar and sha256sum (Linux, CI).
set -euo pipefail

OUT="${1:-$(dirname "$0")/../dist}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
cd "$(dirname "$0")/.."

tar --version 2>/dev/null | grep -q 'GNU tar' || { echo "build-package: needs GNU tar" >&2; exit 2; }
if [ -n "$(git status --porcelain)" ]; then
  echo "build-package: the work tree is dirty; commit or remove these first:" >&2
  git status --short >&2
  exit 1
fi

SHA=$(git rev-parse HEAD)
WHEN=$(git log -1 --format=%ct HEAD)
NAME="romafederico-site-$SHA.tar.gz"

# The list, without comments and blank lines. Each path must be a committed file
# inside the site, not hidden, and not version.json.
mapfile -t FILES < <(git show HEAD:deploy/site-files | sed -e 's/[[:space:]]*#.*//' -e 's/[[:space:]]*$//' | grep -v '^$')
[ "${#FILES[@]}" -gt 0 ] || { echo "build-package: deploy/site-files lists no files" >&2; exit 1; }
bad=0
for f in "${FILES[@]}"; do
  case "/$f/" in
    /version.json/) echo "build-package: $f: the gates write version.json at install time; remove it from deploy/site-files" >&2; bad=1 ;;
    //*|*/../*|*/./*|*/.*) echo "build-package: $f: not allowed in deploy/site-files (outside the site or hidden)" >&2; bad=1 ;;
    *) [ "$(git cat-file -t "HEAD:$f" 2>/dev/null)" = blob ] \
         || { echo "build-package: $f: listed in deploy/site-files but not a committed file" >&2; bad=1; } ;;
  esac
done
[ "$bad" -eq 0 ] || exit 1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/pkg/site"

git archive --format=tar HEAD -- "${FILES[@]}" | tar -xf - -C "$WORK/pkg/site"
printf '{"commit":"%s"}\n' "$SHA" > "$WORK/pkg/BUILD.json"

tar -C "$WORK/pkg" --format=gnu --sort=name --mtime="@$WHEN" \
  --owner=0 --group=0 --numeric-owner --mode='u=rwX,go=rX' \
  -cf - BUILD.json site \
  | gzip -n -9 > "$OUT/$NAME.tmp"
mv "$OUT/$NAME.tmp" "$OUT/$NAME"
(cd "$OUT" && sha256sum "$NAME" > "$NAME.sha256")

echo "$OUT/$NAME ($(wc -c < "$OUT/$NAME") bytes)"
cut -d' ' -f1 "$OUT/$NAME.sha256"
