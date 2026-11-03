#!/usr/bin/env bash
# shellcheck disable=SC2034  # the before* snapshots are read inside check's eval strings
# Tests for deploy/dreamhost/rf-live-gate.sh (#8) in a fake DreamHost home
# folder: the romafederico.com site (with an old README.md and a KEEP name),
# the two other live sites, ~/dk-backups, ~/bin and ~/.ssh. Never touches a
# server. Run: deploy/test/rf-live-gate-test.sh
#
# The installed copy differs from the script in two lines only: KEEP holds
# .well-known, and PATH starts with a stub folder whose `mv` can fail the
# rename of the new folder onto the site (RF_STUB_MV, see below).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GATE_SRC="$ROOT/deploy/dreamhost/rf-live-gate.sh"
FAILS=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
H="$T/home"
S="$H/romafederico.com"
B="$H/rf-backups"

# mv stub. RF_STUB_MV changes only the rename of $HOME/.rf-new-* onto the site folder:
#   fail        the rename fails
#   lose-index  the rename works, then index.html is gone (the check after it fails)
#   lose-prev   the previous folder disappears and the rename fails (the rollback can't finish)
mkdir -p "$T/stub"
cat > "$T/stub/mv" <<'EOF'
#!/usr/bin/env bash
src="${*: -2:1}" dst="${*: -1}"
if [ -n "${RF_STUB_MV:-}" ] && [[ "$(basename "$src")" == .rf-new-* ]] && [ "$dst" = "$HOME/romafederico.com" ]; then
  case "$RF_STUB_MV" in
    fail) echo "mv: stub failure" >&2; exit 1 ;;
    lose-index) /bin/mv "$@" || exit; rm -f "$dst/index.html"; exit 0 ;;
    lose-prev) rm -rf "$HOME"/rf-backups/site-*; echo "mv: stub failure" >&2; exit 1 ;;
  esac
fi
exec /bin/mv "$@"
EOF
chmod +x "$T/stub/mv"

# The parts of the home folder the gate must never touch, made once: the
# whole test must leave them exactly as they are.
mkdir -p "$H/bin" "$H/.ssh" "$H/diegokravetz.com/wp-content/themes/diegokravetz" \
  "$H/marielgaribaldi.com/wp-content/plugins" "$H/dk-backups/packages"
echo 'ssh-ed25519 AAAA federico' > "$H/.ssh/authorized_keys"
echo '<?php // secrets' > "$H/diegokravetz.com/wp-config.php"
echo '/* dk theme */' > "$H/diegokravetz.com/wp-content/themes/diegokravetz/style.css"
echo '<?php // other site' > "$H/marielgaribaldi.com/index.php"
echo '2026-11-01T00:00:00Z OK current' > "$H/dk-backups/gate.log"
echo 'sql' | gzip > "$H/dk-backups/live-20261101-120000-before-v1-0-0.sql.gz"
head -c 100 /dev/urandom > "$H/dk-backups/packages/$(printf '%064d' 9).tar.gz"
sed -e 's|^KEEP=()$|KEEP=(.well-known)|' -e "s|^export PATH=/usr/bin:/bin$|export PATH=$T/stub:/usr/bin:/bin|" \
  "$GATE_SRC" > "$H/bin/rf-live-gate"
chmod 755 "$H/bin/rf-live-gate"
check "(test copy differs from the script in KEEP and PATH only)" \
  "[ \"\$(diff '$GATE_SRC' '$H/bin/rf-live-gate' | grep -c '^>')\" = 2 ]"

# Every path, type, mode and file checksum under <dir>, except the gate's own log and lock.
snapshot() {
  (cd "$1" && find . \( -path ./rf-backups/gate.log -o -path ./rf-backups/gate.lock \) -prune -o -printf '%y %m %p\n' | LC_ALL=C sort \
    && find . -type f ! -path ./rf-backups/gate.log ! -path ./rf-backups/gate.lock -exec sha256sum {} + | LC_ALL=C sort -k2)
}
# Like snapshot of $H, but everything outside romafederico.com/ and rf-backups/.
outside() { snapshot "$H" | grep -vE '(^[a-z] [0-7]+ |  )\./(romafederico\.com|rf-backups)(/|$)'; }
OUTSIDE_START=$(outside)

# A fresh site and rf-backups per case; the rest of $H stays.
setup() {
  rm -rf "$S" "$B" "$H"/.rf-new-* "$T"/pkgs
  mkdir -p "$S/.well-known/acme-challenge" "$S/old-dir"
  echo '<!doctype html><title>old</title>' > "$S/index.html"
  echo 'body { color: red }' > "$S/style.css"
  echo '# old README from the rsync deploy' > "$S/README.md"
  echo 'old' > "$S/old-dir/a.txt"
  echo 'token' > "$S/.well-known/acme-challenge/abc"
  mkdir -p "$B/packages"
  chmod 700 "$B" "$B/packages"
}

# gate "<ssh command>" [stdin file]: run like sshd's forced command, from $HOME.
gate() {
  (cd "$H" && SSH_ORIGINAL_COMMAND="$1" HOME="$H" "$H/bin/rf-live-gate" < "${2:-/dev/null}" > "$T/out" 2> "$T/err")
}

COMMIT=0123456789abcdef0123456789abcdef01234567
# make_pkg <name> [extra tar args...]: a package laid out like deploy/build-package.sh's.
# $P/<name>.tar.gz and $SUM; the source tree is $P/<name>/.
make_pkg() {
  local n="$1"; shift
  P="$T/pkgs"
  local src="$P/$n"
  rm -rf "$src"
  mkdir -p "$src/site/img"
  echo "<!doctype html><title>new $n</title>" > "$src/site/index.html"
  echo "body { color: black } /* $n */" > "$src/site/style.css"
  printf 'jpg' > "$src/site/img/avatar.jpg"
  printf '{"commit":"%s"}\n' "$COMMIT" > "$src/BUILD.json"
  tar -C "$src" --sort=name -czf "$P/$n.tar.gz" "$@" BUILD.json site
  SUM=$(sha256sum "$P/$n.tar.gz" | cut -d' ' -f1)
}
repack() { # <name> <tar args...>: $P/<name>.tar.gz from $P/<name>/ with these args, and $SUM
  local n="$1"; shift
  tar -C "$P/$n" -czf "$P/$n.tar.gz" "$@"
  SUM=$(sha256sum "$P/$n.tar.gz" | cut -d' ' -f1)
}

last_log() { tail -n1 "$B/gate.log" 2>/dev/null; }

echo "# refuses anything that is not an exact command, logs it, changes nothing"
setup
make_pkg good
gate "put-package $SUM" "$P/good.tar.gz"
before=$(snapshot "$H")
A=$(printf 'a%.0s' $(seq 33))
refusals=(
  "" "ls" "id" "/bin/sh" "sh" "bash -c id" "bash" "sh -c id" "cat ~/.ssh/authorized_keys" "cat .ssh/authorized_keys"
  "install ../../diegokravetz.com v1.0.0" "install $SUM v1;rm" "install $SUM v1.0.0;rm -rf ~" "install $SUM v1"
  "install $SUM 1.0.0" "install ${SUM^^} v1.0.0" "install $SUM" "install $SUM v1.0.0 extra" "install"
  "install $SUM sha-0123456"
  "put-package abc" "put-package 123" "put-package" "put-package $SUM extra" "put-package ../$SUM"
  "current extra" "current x" "current;id" "current && id" "current | id" "prune now" "prune all" "prune;rm -rf ~"
  "backup" "backup a b" "backup ABC" "backup $A" "backup x/y" "backup ../x" "backup \$(id)" "backup \$(touch $H/pwned)"
  "backup \`touch $H/pwned\`" "backup a*" "backup ~" "backup \$HOME"
  "\$(touch $H/pwned)" "current\$(touch $H/pwned)" "$(printf 'current\nid')" "$(printf 'current\tid')"
  "scp -t x" "scp -t romafederico.com/index.html" "scp -f .ssh/authorized_keys" "scp -t ."
  "rsync --server -vlogDtpre.iLsfxC . romafederico.com" "internal-sftp" "/usr/lib/openssh/sftp-server" "sftp-server"
  "put-htpasswd" "put-htpasswd \$(id)" "put-env" "put-file docker-compose.yml" "set-tag v1" "ghcr-login x"
  "docker ps" "compose ps" "wp option get home" "wp db export -"
  "CURRENT" " current" "current " "rf-live-gate current" "export SITE_DIR=/tmp; current"
)
all_refused=1 all_logged=1
for c in "${refusals[@]}"; do
  gate "$c"; code=$?
  if [ "$code" != 2 ]; then all_refused=0; echo "  not refused (exit $code): $(printf '%q' "$c")"; fi
  if ! last_log | grep -q ' REFUSED '; then all_logged=0; echo "  not logged: $(printf '%q' "$c")"; fi
done
check "all ${#refusals[@]} refused with exit 2" "[ $all_refused = 1 ]"
check "each logged as REFUSED in rf-backups/gate.log" "[ $all_logged = 1 ]"
check "log lines have UTC time, result and request" \
  "grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z REFUSED install ../../diegokravetz.com v1.0.0$' '$B/gate.log'"
check "the empty command is logged too" "grep -qE '^[0-9T:Z-]+ REFUSED $' '$B/gate.log'"
check "a newline or tab in the request becomes ?, one log line per request" \
  "grep -qx '.* REFUSED current?id' '$B/gate.log' && [ \$(grep -c '' '$B/gate.log') = \$(( ${#refusals[@]} + 1 )) ]"
check "nothing changed anywhere (other sites, ~/bin, ~/.ssh, site, backups)" "[ \"\$(snapshot '$H')\" = \"\$before\" ]"
check "no command substitution ran" "[ ! -e '$H/pwned' ]"

echo "# current"
setup
gate current; code=$?
check "before any release: exit 0" "[ $code = 0 ]"
check "before any release: prints none" "[ \"\$(cat '$T/out')\" = none ]"
check "logged as OK" "last_log | grep -q ' OK current$'"

echo "# put-package"
setup
make_pkg good
before=$(snapshot "$H")
wrong=$(printf '%064d' 0)
gate "put-package $wrong" "$P/good.tar.gz"; code=$?
check "wrong checksum: refused (exit 2)" "[ $code = 2 ]"
check "wrong checksum: logged REFUSED" "last_log | grep -q ' REFUSED put-package $wrong$'"
check "wrong checksum: nothing kept" "[ \"\$(snapshot '$H')\" = \"\$before\" ]"
gate "put-package $SUM" "$P/good.tar.gz"; code=$?
check "right checksum: exit 0" "[ $code = 0 ]"
check "right checksum: logged OK" "last_log | grep -q ' OK put-package $SUM$'"
check "right checksum: stored as packages/<sha256>.tar.gz" "cmp -s '$P/good.tar.gz' '$B/packages/$SUM.tar.gz'"
check "right checksum: no temp file left" "[ \"\$(ls -A '$B/packages')\" = '$SUM.tar.gz' ]"
check "right checksum: says so" "grep -qx 'PACKAGE=$SUM [0-9]* bytes' '$T/out'"
check "right checksum: only packages/ changed" \
  "[ \"\$(snapshot '$H' | grep -v '/packages')\" = \"\$(printf '%s\n' \"\$before\" | grep -v '/packages')\" ]"
check "right checksum: package only readable by the user" "[ \"\$(stat -c %a '$B/packages/$SUM.tar.gz')\" = 600 ]"
before=$(snapshot "$H")
gate "put-package $SUM"; code=$?  # no stdin at all
check "same package again: exit 0 without reading stdin" "[ $code = 0 ]"
check "same package again: says it is there already" "grep -qx 'PACKAGE=$SUM [0-9]* bytes, already stored' '$T/out'"
check "same package again: stores nothing" "[ \"\$(snapshot '$H')\" = \"\$before\" ]"
printf 'x' >> "$B/packages/$SUM.tar.gz"
gate "put-package $SUM" "$P/good.tar.gz"; code=$?
check "a damaged stored copy is replaced by a good upload" "[ $code = 0 ] && cmp -s '$P/good.tar.gz' '$B/packages/$SUM.tar.gz'"

bad_pkg() { # <case> <tar.gz>: must be refused, logged and not kept
  local sum
  sum=$(sha256sum "$2" | cut -d' ' -f1)
  before=$(snapshot "$H")
  gate "put-package $sum" "$2"; code=$?
  check "$1: refused (exit 2)" "[ $code = 2 ]"
  check "$1: logged REFUSED" "last_log | grep -q ' REFUSED put-package '"
  check "$1: nothing kept" "[ \"\$(snapshot '$H')\" = \"\$before\" ]"
}
setup
make_pkg symlink
ln -s ../../.ssh/authorized_keys "$P/symlink/site/keys.txt"
repack symlink BUILD.json site
bad_pkg "symlink" "$P/symlink.tar.gz"
make_pkg hardlink
ln "$P/hardlink/site/style.css" "$P/hardlink/site/copy.css"
repack hardlink BUILD.json site
check "(fixture has a hard link)" "tar -tvzf '$P/hardlink.tar.gz' | grep -q '^h'"
bad_pkg "hard link" "$P/hardlink.tar.gz"
make_pkg abs
tar -C "$P/abs" -czPf "$P/abs.tar.gz" BUILD.json site "$P/abs/site/style.css"
check "(fixture has an absolute name)" "tar -tzPf '$P/abs.tar.gz' | grep -q '^/'"
bad_pkg "absolute path" "$P/abs.tar.gz"
make_pkg dotdot
repack dotdot -P --transform 's|^site/style.css$|site/../../diegokravetz.com/x.css|' BUILD.json site
check "(fixture has a .. name)" "tar -tzPf '$P/dotdot.tar.gz' | grep -q '\.\./\.\./'"
bad_pkg "name with .." "$P/dotdot.tar.gz"
make_pkg outside
echo 'x' > "$P/outside/notes.txt"
repack outside BUILD.json site notes.txt
bad_pkg "a file outside site/" "$P/outside.tar.gz"
make_pkg version
echo '{"version":"v9.9.9"}' > "$P/version/site/version.json"
repack version BUILD.json site
bad_pkg "a site/version.json" "$P/version.tar.gz"
make_pkg dotslash
repack dotslash ./BUILD.json ./site
bad_pkg "names starting ./" "$P/dotslash.tar.gz"
make_pkg noindex
rm "$P/noindex/site/index.html"
repack noindex BUILD.json site
bad_pkg "no site/index.html" "$P/noindex.tar.gz"
make_pkg nobuild
repack nobuild site
bad_pkg "no BUILD.json" "$P/nobuild.tar.gz"
make_pkg badbuild
# shellcheck disable=SC2016  # a literal $(id), never expanded
echo '{"commit":"$(id)"}' > "$P/badbuild/BUILD.json"
repack badbuild BUILD.json site
bad_pkg "BUILD.json without a 40-hex commit" "$P/badbuild.tar.gz"
make_pkg oddname
echo x > "$P/oddname/site/a b.html"
repack oddname BUILD.json site
bad_pkg "a name with a space" "$P/oddname.tar.gz"
printf 'not a tarball' > "$P/x.tar.gz"
bad_pkg "not a gzip tar" "$P/x.tar.gz"
: > "$P/x.tar.gz"
bad_pkg "empty upload" "$P/x.tar.gz"
head -c $((10 * 1024 * 1024 + 1)) /dev/zero > "$P/big.tar.gz"
bad_pkg "more than 10 MiB" "$P/big.tar.gz"

echo "# install"
setup
make_pkg good
chmod 600 "$P/good/site/style.css"; chmod 755 "$P/good/site/index.html"; chmod 700 "$P/good/site/img"
repack good BUILD.json site
gate "put-package $SUM" "$P/good.tar.gz"
before_outside=$(outside)
before_site=$(snapshot "$S")
gate "install $SUM v1.2.3"; code=$?
check "exit 0" "[ $code = 0 ]"
check "logged as OK" "last_log | grep -q ' OK install $SUM v1.2.3$'"
check "prints INSTALLED=<version> <sha256>" "grep -qx 'INSTALLED=v1.2.3 $SUM' '$T/out'"
check "the site holds exactly the package's site/, version.json and the KEEP names" \
  "[ \"\$(cd '$S' && find . -mindepth 1 | LC_ALL=C sort)\" = \"\$( (cd '$P/good/site' && find . -mindepth 1; echo ./version.json; echo ./.well-known; echo ./.well-known/acme-challenge; echo ./.well-known/acme-challenge/abc) | LC_ALL=C sort)\" ]"
check "files are the package's" "diff -r -x version.json -x .well-known '$P/good/site' '$S'"
check "the KEEP name is the live one, unchanged" "[ \"\$(cat '$S/.well-known/acme-challenge/abc')\" = token ]"
check "old README.md and old-dir are gone from the site" "[ ! -e '$S/README.md' ] && [ ! -e '$S/old-dir' ]"
prev=$(sed -n 's/^PREVIOUS=//p' "$T/out")
check "prints PREVIOUS=site-<UTC stamp>" "[[ '$prev' =~ ^site-[0-9]{8}-[0-9]{6}$ ]]"
check "the previous folder is kept whole in rf-backups/site-<stamp>" \
  "[ \"\$(snapshot '$B/$prev')\" = \"\$(printf '%s\n' \"\$before_site\")\" ]"
check "version.json: exactly the #5 format, environment live" \
  "jq -e --arg s '$SUM' --arg c '$COMMIT' 'keys_unsorted == [\"site\",\"environment\",\"version\",\"commit\",\"package_sha256\",\"installed_at\"] and .site == \"romafederico.com\" and .environment == \"live\" and .version == \"v1.2.3\" and .commit == \$c and .package_sha256 == \$s and (.installed_at | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$\"))' '$S/version.json' >/dev/null"
check "version.json is one line" "[ \$(wc -l < '$S/version.json') = 1 ]"
check "files 644, folders 755 (package modes ignored)" \
  "[ \"\$(find '$S' -path '$S/.well-known' -prune -o -type f -printf '%m\n' | sort -u)\" = 644 ] && [ \"\$(find '$S' -path '$S/.well-known' -prune -o -type d -printf '%m\n' | sort -u)\" = 755 ]"
check "no .rf-new-* folder left" "[ -z \"\$(find '$H' -maxdepth 1 -name '.rf-new-*')\" ]"
check "nothing outside the site and rf-backups changed" "[ \"\$(outside)\" = \"\$before_outside\" ]"
gate current
check "current prints version.json" "cmp -s '$T/out' '$S/version.json'"

echo "# install: a second release replaces the first"
sleep 1  # one install per second: site-<stamp> names are per second
make_pkg second
gate "put-package $SUM" "$P/second.tar.gz"
gate "install $SUM v1.2.4"; code=$?
check "exit 0" "[ $code = 0 ]"
check "site is the second package's" "diff -r -x version.json -x .well-known '$P/second/site' '$S'"
check "version v1.2.4" "jq -e '.version == \"v1.2.4\"' '$S/version.json' >/dev/null"
check "two site-<stamp> folders, the newer holds v1.2.3" \
  "[ \$(find '$B' -maxdepth 1 -name 'site-*' | wc -l) = 2 ] && jq -e '.version == \"v1.2.3\"' \"\$(find '$B' -maxdepth 1 -name 'site-*' | sort | tail -n1)/version.json\" >/dev/null"

echo "# install: a package from deploy/build-package.sh (fixture repo)"
setup
R="$T/repo"
rm -rf "$R"
mkdir -p "$R/deploy"
cp "$ROOT/deploy/build-package.sh" "$R/deploy/"
printf 'index.html\nstyle.css\navatar.jpg\n' > "$R/deploy/site-files"
echo '<!doctype html><title>built</title>' > "$R/index.html"
echo 'body {}' > "$R/style.css"
printf 'jpg' > "$R/avatar.jpg"
echo '# not served' > "$R/README.md"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -q -m fixture
built=$(cd "$R" && deploy/build-package.sh "$T/built" 2>/dev/null | tail -n1)
gate "put-package $built" "$T/built/romafederico-site-$(git -C "$R" rev-parse HEAD).tar.gz"; code=$?
check "put-package accepts it" "[ $code = 0 ]"
gate "install $built v1.0.0"; code=$?
check "install accepts it" "[ $code = 0 ]"
check "site is the commit's site files" "[ \"\$(cd '$S' && ls -A | LC_ALL=C sort | tr '\n' ' ')\" = '.well-known avatar.jpg index.html style.css version.json ' ]"
check "version.json has the commit from BUILD.json" "jq -e --arg c \"\$(git -C '$R' rev-parse HEAD)\" '.commit == \$c' '$S/version.json' >/dev/null"

echo "# install: refused or failed before the swap changes nothing"
setup
before=$(snapshot "$H")
gate "install $(printf '%064d' 1) v1.0.0"; code=$?
check "never uploaded: exit 1" "[ $code = 1 ]"
check "never uploaded: logged FAILED" "last_log | grep -q ' FAILED install '"
check "never uploaded: nothing changed" "[ \"\$(snapshot '$H')\" = \"\$before\" ]"
make_pkg good
gate "put-package $SUM" "$P/good.tar.gz"
printf 'x' >> "$B/packages/$SUM.tar.gz"
before=$(snapshot "$H")
gate "install $SUM v1.0.0"; code=$?
check "stored copy changed since put-package: exit 1" "[ $code = 1 ]"
check "stored copy changed since put-package: nothing changed" "[ \"\$(snapshot '$H')\" = \"\$before\" ]"
make_pkg script
echo '<p>hi</p><SCRIPT>alert(1)</SCRIPT>' >> "$P/script/site/index.html"
repack script BUILD.json site
gate "put-package $SUM" "$P/script.tar.gz"
before=$(snapshot "$H")
gate "install $SUM v1.0.0"; code=$?
check "<script in index.html: exit 1" "[ $code = 1 ]"
check "<script in index.html: says so" "grep -q 'script' '$T/err'"
check "<script in index.html: nothing changed, no .rf-new-* left" "[ \"\$(snapshot '$H')\" = \"\$before\" ]"
make_pkg keep
mkdir -p "$P/keep/site/.well-known"; echo evil > "$P/keep/site/.well-known/x"
repack keep BUILD.json site
gate "put-package $SUM" "$P/keep.tar.gz"
before=$(snapshot "$H")
gate "install $SUM v1.0.0"; code=$?
check "package holds a KEEP name: exit 1, nothing changed" "[ $code = 1 ] && [ \"\$(snapshot '$H')\" = \"\$before\" ]"
make_pkg good
gate "put-package $SUM" "$P/good.tar.gz"
mv "$S" "$T/real-site"; ln -s "$T/real-site" "$S"
before=$(snapshot "$H")
gate "install $SUM v1.0.0"; code=$?
check "site folder is a symlink: exit 1, nothing changed" "[ $code = 1 ] && [ \"\$(snapshot '$H')\" = \"\$before\" ] && [ -L '$S' ]"
rm "$S"; mv "$T/real-site" "$S"

echo "# install: a failure after the first rename puts the previous folder back"
for mode in fail lose-index; do
  setup
  echo '{"site":"romafederico.com","environment":"live","version":"v1.0.0"}' > "$S/version.json"
  make_pkg good
  gate "put-package $SUM" "$P/good.tar.gz"
  before=$(snapshot "$H")
  RF_STUB_MV=$mode gate "install $SUM v1.1.0"; code=$?
  check "$mode: exit 1" "[ $code = 1 ]"
  check "$mode: logged FAILED" "last_log | grep -q ' FAILED install '"
  check "$mode: says it restored" "grep -q 'previous site folder restored' '$T/err'"
  check "$mode: no RESTORE FAILED" "! grep -q 'RESTORE FAILED' '$T/err'"
  check "$mode: whole home exactly as before (site, backups, no .rf-new-*)" "[ \"\$(snapshot '$H')\" = \"\$before\" ]"
done

echo "# install: a rollback that can't finish says RESTORE FAILED, not restored"
setup
make_pkg good
gate "put-package $SUM" "$P/good.tar.gz"
RF_STUB_MV=lose-prev gate "install $SUM v1.1.0"; code=$?
check "exit 1" "[ $code = 1 ]"
check "says RESTORE FAILED" "grep -q 'RESTORE FAILED' '$T/err'"
check "names the missing folder" "grep -q 'rf-backups/site-.* is missing' '$T/err'"
check "does not say restored" "! grep -q 'previous site folder restored' '$T/err'"
check "logged FAILED" "last_log | grep -q ' FAILED install '"

echo "# install: first install (no site folder yet)"
setup
rm -rf "$S"
make_pkg good
gate "put-package $SUM" "$P/good.tar.gz"
before=$(snapshot "$H")
RF_STUB_MV=lose-index gate "install $SUM v1.0.0"; code=$?
check "a failure: exit 1, says restored, no site folder again" \
  "[ $code = 1 ] && grep -q 'previous site folder restored' '$T/err' && [ \"\$(snapshot '$H')\" = \"\$before\" ]"
gate "install $SUM v1.0.0"; code=$?
check "then it works" "[ $code = 0 ] && diff -r -x version.json '$P/good/site' '$S'"

echo "# backup"
setup
before_outside=$(outside)
before_site=$(snapshot "$S")
gate "backup before-v1-0-0"; code=$?
check "exit 0" "[ $code = 0 ]"
check "logged as OK" "last_log | grep -q ' OK backup before-v1-0-0$'"
name=$(sed -n 's/^BACKUP=//p' "$T/out")
check "prints BACKUP=live-<UTC stamp>-<label>" "[[ '$name' =~ ^live-[0-9]{8}-[0-9]{6}-before-v1-0-0$ ]]"
check "prints the size" "grep -qx '$name.tgz [0-9]* bytes' '$T/out'"
check "gzip -t passes; holds the whole site folder" \
  "gzip -t '$B/$name.tgz' && [ \"\$(tar -tzf '$B/$name.tgz' | sed 's|/$||' | LC_ALL=C sort)\" = \"\$( (cd '$H' && find romafederico.com) | LC_ALL=C sort)\" ]"
check "only readable by the user" "[ \"\$(stat -c %a '$B/$name.tgz')\" = 600 ]"
check "site and everything outside unchanged" "[ \"\$(snapshot '$S')\" = \"\$before_site\" ] && [ \"\$(outside)\" = \"\$before_outside\" ]"
check "no temp file left" "[ \"\$(ls -A '$B' | grep -vE '^(gate\.|packages$)' | tr '\n' ' ')\" = '$name.tgz ' ]"
setup
rm -rf "$S"
before=$(snapshot "$H")
gate "backup x"; code=$?
check "no site folder: exit 1, nothing kept" "[ $code = 1 ] && [ \"\$(snapshot '$H')\" = \"\$before\" ]"
mkdir "$S"
gate "backup x"; code=$?
check "empty site folder: exit 1 (empty backup), nothing kept" \
  "[ $code = 1 ] && [ -z \"\$(find '$B' -name 'live-*' -o -name '*.tmp')\" ]"

echo "# one command at a time"
setup
flock "$B/gate.lock" bash -c "cd '$H' && SSH_ORIGINAL_COMMAND='backup x' HOME='$H' '$H/bin/rf-live-gate' >/dev/null 2>'$T/err'"; code=$?
check "busy: exit 1" "[ $code = 1 ]"
check "busy: says so" "grep -q 'busy' '$T/err'"
check "busy: no backup made" "[ -z \"\$(find '$B' -name 'live-*')\" ]"

echo "# prune"
setup
for i in $(seq -w 1 7); do
  head -c 10 /dev/urandom > "$B/packages/$(printf '%064d' "$i").tar.gz"
  touch -d "2026-10-0$i 12:00" "$B/packages/$(printf '%064d' "$i").tar.gz"
done
for i in $(seq -w 1 12); do
  echo x > "$B/live-202610${i}-120000-before-v1.tgz"
  mkdir "$B/site-202610${i}-120000"; echo x > "$B/site-202610${i}-120000/index.html"
done
# Not made by the gate: kept whatever their age.
echo notes > "$B/notes.txt"
echo x > "$B/live-before-launch.tgz"
echo x > "$B/live-20261001-120000-before-v1.tar.gz"
mkdir "$B/site-old-manual"
echo keep > "$B/packages/README"
echo x > "$B/packages/abc.tar.gz"
touch -d "2026-01-01" "$B/notes.txt" "$B/live-before-launch.tgz" "$B/packages/README" "$B/packages/abc.tar.gz"
before_outside=$(outside)
gate prune; code=$?
check "exit 0, prints PRUNED, logged OK" "[ $code = 0 ] && grep -qx PRUNED '$T/out' && last_log | grep -q ' OK prune$'"
check "5 newest packages kept" \
  "[ \"\$(ls '$B/packages' | grep -cE '^[0-9a-f]{64}\.tar\.gz$')\" = 5 ] && [ ! -e '$B/packages/$(printf '%064d' 2).tar.gz' ] && [ -e '$B/packages/$(printf '%064d' 3).tar.gz' ] && [ -e '$B/packages/$(printf '%064d' 7).tar.gz' ]"
check "10 newest live-* backups kept" \
  "[ \$(ls '$B' | grep -cE '^live-[0-9]{8}-[0-9]{6}-.*\.tgz$') = 10 ] && [ ! -e '$B/live-20261002-120000-before-v1.tgz' ] && [ -e '$B/live-20261003-120000-before-v1.tgz' ] && [ -e '$B/live-20261012-120000-before-v1.tgz' ]"
check "10 newest site-* folders kept" \
  "[ \$(ls '$B' | grep -cE '^site-[0-9]{8}-[0-9]{6}$') = 10 ] && [ ! -e '$B/site-20261002-120000' ] && [ -e '$B/site-20261012-120000' ]"
check "files it didn't make are kept" \
  "[ -e '$B/notes.txt' ] && [ -e '$B/live-before-launch.tgz' ] && [ -e '$B/live-20261001-120000-before-v1.tar.gz' ] && [ -d '$B/site-old-manual' ] && [ -e '$B/packages/README' ] && [ -e '$B/packages/abc.tar.gz' ]"
check "nothing outside rf-backups changed" "[ \"\$(outside)\" = \"\$before_outside\" ]"
gate prune; code=$?
check "a second prune deletes nothing more" \
  "[ $code = 0 ] && [ \$(ls '$B' | grep -cE '^site-[0-9]{8}') = 10 ] && [ \"\$(ls '$B/packages' | grep -cE '^[0-9a-f]{64}')\" = 5 ]"

setup
rm -rf "$B/packages"
echo x > "$B/live-20261001-120000-only.tgz"
mkdir "$B/site-20261001-120000"
gate prune; code=$?
check "no packages/ folder yet: exit 0, PRUNED, logged OK" "[ $code = 0 ] && grep -qx PRUNED '$T/out' && last_log | grep -q ' OK prune$'"
check "the only backup and site folder are kept" "[ -e '$B/live-20261001-120000-only.tgz' ] && [ -d '$B/site-20261001-120000' ]"

setup
for i in $(seq 1 6000); do echo "2026-10-01T00:00:00Z OK old line $i"; done > "$B/gate.log"
gate prune; code=$?
check "gate.log: trimmed to its last 5000 lines (plus prune's own)" "[ $code = 0 ] && [ \$(wc -l < '$B/gate.log') = 5001 ]"
check "gate.log: oldest lines gone, newest kept" \
  "! grep -qx '.* old line 1000' '$B/gate.log' && grep -qx '.* old line 1001' '$B/gate.log' && grep -qx '.* old line 6000' '$B/gate.log' && last_log | grep -q ' OK prune$'"
check "gate.log: only readable by the user, no temp file left" "[ \"\$(stat -c %a '$B/gate.log')\" = 600 ] && [ -z \"\$(find '$B' -name 'gate.log?*')\" ]"

echo "# fixed settings, no shell evaluation"
check "settings are fixed at the top, not read from input" \
  "grep -qx 'SITE_DIR=\"\$HOME/romafederico.com\"' '$GATE_SRC' && grep -qx 'BACKUP_DIR=\"\$HOME/rf-backups\"' '$GATE_SRC' && grep -qx 'KEEP=()' '$GATE_SRC' && grep -qx 'export PATH=/usr/bin:/bin' '$GATE_SRC' && grep -qx 'umask 077' '$GATE_SRC'"
check "no eval, no sh -c" "! grep -nE '(^|[^a-z_])eval |(ba)?sh -c' '$GATE_SRC'"
check "names no other site or backup folder" "! grep -nE 'diegokravetz|marielgaribaldi|dk-backups|\\.ssh|HOME/bin' '$GATE_SRC' | grep -v '^[0-9]*:#'"

echo "# the whole run"
check "everything outside romafederico.com and rf-backups is exactly as at the start" "[ \"\$(outside)\" = \"\$OUTSIDE_START\" ]"

echo
if [ "$FAILS" -gt 0 ]; then echo "$FAILS failed"; exit 1; fi
echo "all passed"
