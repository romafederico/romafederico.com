"""CI / links: every internal href/src (and CSS url()) points to a file in the repo; #fragments point to an id.

External links are not checked (flaky; out of scope for #4).
Usage: python3 tests/check_links.py
"""

import os
import sys

import sitefiles


def main():
    errors = []
    ids = {}
    checked = 0
    for rel in sitefiles.site_files():
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
