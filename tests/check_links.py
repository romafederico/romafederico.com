"""CI / links: every internal href/src (and CSS url()) points to a site file; #fragments point to an id.

Site files are the ones in deploy/site-files; a reference to a file that isn't listed fails too,
because the package (#5) wouldn't have it. External links are not checked (flaky; out of scope for #4).
Usage: python3 tests/check_links.py         (SITE_DIR=<dir> to check an unpacked package's site/)
"""

import os
import sys

import sitefiles


def main():
    errors = sitefiles.missing()
    listed = set(sitefiles.site_files())
    ids = {}
    checked = 0
    for rel in sorted(listed - {e[0] for e in errors}):
        for line, url in sitefiles.refs(rel):
            r = sitefiles.resolve(rel, url)
            if r is None:
                continue
            checked += 1
            target, fragment = r
            if target.startswith("..") or os.path.isabs(target):
                errors.append((rel, line, f"{url!r} points outside the site"))
                continue
            if not os.path.isfile(os.path.join(sitefiles.ROOT, target)):
                errors.append((rel, line, f"{url!r}: no file {target}"))
                continue
            if target not in listed:
                errors.append((rel, line, f"{url!r}: {target} is not in deploy/site-files"))
                continue
            if fragment and target.endswith((".html", ".htm")):
                if target not in ids:
                    ids[target] = sitefiles.parse_html(os.path.join(sitefiles.ROOT, target)).ids
                if fragment not in ids[target]:
                    errors.append((rel, line, f"{url!r}: no id {fragment!r} in {target}"))
    code = sitefiles.report(errors)
    if not code:
        print(f"{checked} internal references OK in {', '.join(sitefiles.site_files())}")
    return code


if __name__ == "__main__":
    sys.exit(main())
