"""CI / no-js: the site has no JavaScript.

Federico wants romafederico.com to stay hand-written HTML + CSS with no JavaScript (epic #1, #4).
Fails on <script (any case), an on...= event attribute or a javascript: URL in a site file,
or any *.js / *.mjs / *.cjs file in the repo outside .github/.
Usage: python3 tests/no_js.py
"""

import os
import re
import sys
from html.parser import HTMLParser

import sitefiles

TEXT = (".html", ".htm", ".css", ".svg", ".xml")
PATTERNS = [
    (re.compile(r"<script", re.I), "<script> tag"),
    (re.compile(r"javascript\s*:", re.I), "javascript: URL"),
]


class EventAttrs(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.found = []

    def handle_starttag(self, tag, attrs):
        for name, _ in attrs:
            if name.startswith("on"):
                self.found.append((self.getpos()[0], f"{name}= event attribute on <{tag}>"))


def main():
    errors = []
    files = [f for f in sitefiles.site_files() if f.endswith(TEXT)]
    for rel in files:
        with open(os.path.join(sitefiles.ROOT, rel), encoding="utf-8") as f:
            text = f.read()
        for pattern, what in PATTERNS:
            for m in pattern.finditer(text):
                errors.append((rel, text.count("\n", 0, m.start()) + 1, what))
        if not rel.endswith(".css"):
            parser = EventAttrs()
            parser.feed(text)
            parser.close()
            errors.extend((rel, line, what) for line, what in parser.found)

    for dirpath, dirnames, filenames in os.walk(sitefiles.ROOT):
        dirnames[:] = sorted(d for d in dirnames if not (dirpath == sitefiles.ROOT and d in (".git", ".github")))
        for name in sorted(filenames):
            if name.endswith((".js", ".mjs", ".cjs")):
                rel = os.path.relpath(os.path.join(dirpath, name), sitefiles.ROOT)
                errors.append((rel, 1, "JavaScript file in the repo"))

    code = sitefiles.report(errors)
    if not code:
        print(f"no JavaScript in {', '.join(files)} or the repo")
    return code


if __name__ == "__main__":
    sys.exit(main())
