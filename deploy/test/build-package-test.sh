#!/usr/bin/env bash
# Tests for deploy/build-package.sh on a small fixture repo in a temp folder:
# the real checkout is never touched. Run: deploy/test/build-package-test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAILS=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# A fresh fixture repo per case: three site files (one in a subfolder) listed in
# deploy/site-files with a comment and a blank line, plus files that must stay out
# of the package (README.md, .gitignore, .github/, docs/, tests/, a committed .DS_Store).
# Optional: a function name to change the fixture before the commit.
setup() {
  T=$(mktemp -d)
  R="$T/repo"
  mkdir -p "$R/deploy" "$R/img" "$R/.github/workflows" "$R/docs" "$R/tests"
  cp "$ROOT/deploy/build-package.sh" "$R/deploy/"
  printf '# site files\n\nindex.html\nstyle.css\nimg/a.jpg\n' > "$R/deploy/site-files"
  echo '<p>x</p>' > "$R/index.html"
  echo 'p { color: red }' > "$R/style.css"
  printf 'img' > "$R/img/a.jpg"
  echo 'readme' > "$R/README.md"
  echo 'dist/' > "$R/.gitignore"
  echo 'name: CI' > "$R/.github/workflows/ci.yml"
  echo 'runbook' > "$R/docs/runbook.md"
  echo 'print()' > "$R/tests/t.py"
  printf 'junk' > "$R/.DS_Store"
  if [ $# -gt 0 ]; then "$1"; fi
  git -C "$R" init -q
  git -C "$R" add -A -f
  GIT_AUTHOR_DATE="2026-11-01T10:00:00Z" GIT_COMMITTER_DATE="2026-11-01T10:00:00Z" \
    git -C "$R" -c user.name=t -c user.email=t@t commit -q -m fixture
  SHA=$(git -C "$R" rev-parse HEAD)
  PKG="romafederico-site-$SHA.tar.gz"
}

build() { (cd "$R" && deploy/build-package.sh "$@"); }

echo "# builds the package, the .sha256 file and prints the checksum last"
setup
out=$(build "$T/out" 2>"$T/err"); code=$?
check "exit 0" "[ $code = 0 ]"
check "package named after the full sha" "[ -f '$T/out/$PKG' ]"
check ".sha256 next to it, sha256sum format" "(cd '$T/out' && sha256sum -c --quiet '$PKG.sha256')"
sum=$(sha256sum "$T/out/$PKG" | cut -d' ' -f1)
check "last line is the checksum" "[ '$(printf '%s\n' "$out" | tail -n1)' = '$sum' ]"
check "gzip header has no name and no time (gzip -n)" "[ \"\$(od -An -tu4 -j4 -N4 '$T/out/$PKG' | tr -d ' ')\" = 0 ]"

echo "# contains only site/<listed files> and BUILD.json"
tar -tzf "$T/out/$PKG" | sort > "$T/list"
cat > "$T/want" <<'LIST'
BUILD.json
site/
site/img/
site/img/a.jpg
site/index.html
site/style.css
LIST
check "exact file list" "diff -u '$T/want' '$T/list'"
check "BUILD.json is {\"commit\":\"<sha>\"}" \
  "[ \"\$(tar -xzOf '$T/out/$PKG' BUILD.json | jq -c .)\" = '{\"commit\":\"$SHA\"}' ]"
mkdir "$T/unpacked"
tar -xzf "$T/out/$PKG" -C "$T/unpacked"
check "site files are the committed ones" \
  "cmp -s '$R/index.html' '$T/unpacked/site/index.html' && cmp -s '$R/style.css' '$T/unpacked/site/style.css' && cmp -s '$R/img/a.jpg' '$T/unpacked/site/img/a.jpg'"

echo "# owner 0, mtime = commit time, fixed modes, sorted names"
TZ=UTC tar --numeric-owner -tvzf "$T/out/$PKG" > "$T/long"
check "listing not empty" "[ -s '$T/long' ]"
check "every entry owned by 0/0" "! awk '\$2 != \"0/0\"' '$T/long' | grep -q ."
check "every entry dated at the commit" "! grep -v ' 2026-11-01 10:00' '$T/long' | grep -q ."
check "files are -rw-r--r--, folders drwxr-xr-x" "! grep -Ev '^(-rw-r--r--|drwxr-xr-x) ' '$T/long' | grep -q ."
check "names sorted in the archive" "tar -tzf '$T/out/$PKG' | sort -c"

echo "# reproducible: same commit, different checkout, mtimes and umask"
git clone -q "$R" "$T/clone"
touch -d '2001-01-01' "$T/clone/style.css"
out2=$(cd "$T/clone" && umask 077 && deploy/build-package.sh "$T/out2" 2>/dev/null)
check "same sha256 twice" "[ -n '$sum' ] && [ '$(printf '%s\n' "$out2" | tail -n1)' = '$sum' ]"

echo "# default out dir is dist/"
setup
build >/dev/null 2>&1
check "package in dist/" "[ -f '$R/dist/$PKG' ]"

echo "# refuses a dirty work tree"
setup
echo '<p>edit</p>' >> "$R/index.html"
build "$T/out" >/dev/null 2>"$T/err"; code=$?
check "changed file: exit non-zero" "[ $code != 0 ]"
check "changed file: says why" "grep -qi dirty '$T/err'"
check "changed file: no package" "[ ! -e '$T/out/$PKG' ]"
setup
echo new > "$R/new.html"
build "$T/out" >/dev/null 2>&1; code=$?
check "untracked file: exit non-zero" "[ $code != 0 ]"

echo "# refuses a listed file that isn't committed"
no_css() { rm "$R/style.css"; }
setup no_css
build "$T/out" >/dev/null 2>"$T/err"; code=$?
check "exit non-zero" "[ $code != 0 ]"
check "names the file" "grep -q 'style.css' '$T/err'"
check "no package" "[ ! -e '$T/out/$PKG' ]"

echo "# refuses version.json in the list (the gates write it)"
with_version() { echo '{}' > "$R/version.json"; echo version.json >> "$R/deploy/site-files"; }
setup with_version
build "$T/out" >/dev/null 2>"$T/err"; code=$?
check "exit non-zero" "[ $code != 0 ]"
check "says why" "grep -q 'version.json' '$T/err'"
check "no package" "[ ! -e '$T/out/$PKG' ]"

echo "# refuses paths outside the site, hidden files and folders"
for bad in ../x /etc/passwd .DS_Store .github/workflows/ci.yml img/../README.md img; do
  bad_line() { echo "$bad" >> "$R/deploy/site-files"; }
  setup bad_line
  build "$T/out" >/dev/null 2>"$T/err"; code=$?
  check "$bad: refused" "[ $code != 0 ] && [ ! -e '$T/out/$PKG' ]"
done

echo
if [ "$FAILS" -gt 0 ]; then echo "$FAILS failed"; exit 1; fi
echo "all passed"
