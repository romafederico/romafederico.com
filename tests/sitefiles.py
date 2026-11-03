"""Site files and the local references in them, shared by the CI checks.

Site files are the paths listed in deploy/site-files, the same list deploy/build-package.sh packs (#5).
The checks look for them in the repo, or in $SITE_DIR when it is set: CI / package points it at the
unpacked package's site/, so a file missing from the list fails there.
"""

import os
import re
from html.parser import HTMLParser
from urllib.parse import unquote

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.abspath(os.environ.get("SITE_DIR") or REPO)
LIST = os.path.join(REPO, "deploy", "site-files")

# url(...) and @import "..." in CSS (a <style> block or a style="" attribute too).
CSS_URL = re.compile(r"""url\(\s*(['"]?)(.*?)\1\s*\)|@import\s+(['"])(.*?)\3""", re.I | re.S)
# Anything with a scheme (https:, mailto:, data:, ...) or protocol-relative (//host) is not a local file.
EXTERNAL = re.compile(r"^([a-z][a-z0-9+.-]*:|//)", re.I)
URL_ATTRS = {"href", "src", "poster", "data", "action", "formaction", "cite", "background"}


def css_refs(text, line=1):
    """(line, url) for every url(...) and @import in CSS text that starts at `line`."""
    for m in CSS_URL.finditer(text):
        url = m.group(2) if m.group(2) is not None else m.group(4)
        yield line + text.count("\n", 0, m.start()), url.strip()


class HtmlRefs(HTMLParser):
    """Collects (line, url) references and the ids (and <a name>) of one HTML file."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.refs = []
        self.ids = set()
        self._style = None

    def handle_starttag(self, tag, attrs):
        line = self.getpos()[0]
        for name, value in attrs:
            if value is None:
                continue
            if name == "id" or (tag == "a" and name == "name"):
                self.ids.add(value)
            elif name in URL_ATTRS:
                self.refs.append((line, value.strip()))
            elif name in ("srcset", "imagesrcset"):
                for part in value.split(","):
                    if part.strip():
                        self.refs.append((line, part.split()[0]))
            elif name == "style":
                self.refs.extend(css_refs(value, line))
        if tag == "style":
            self._style = line

    def handle_endtag(self, tag):
        if tag == "style":
            self._style = None

    def handle_data(self, data):
        if self._style is not None:
            self.refs.extend(css_refs(data, self.getpos()[0]))


def parse_html(path):
    parser = HtmlRefs()
    with open(path, encoding="utf-8") as f:
        parser.feed(f.read())
    parser.close()
    return parser


def refs(rel):
    """(line, url) for every reference in the site file `rel` (relative to ROOT)."""
    path = os.path.join(ROOT, rel)
    if rel.endswith((".html", ".htm")):
        return parse_html(path).refs
    if rel.endswith(".css"):
        with open(path, encoding="utf-8") as f:
            return list(css_refs(f.read()))
    return []


def resolve(rel, url):
    """(target path relative to ROOT, fragment) for a local reference, or None if it is external or empty.

    The target may be outside ROOT (starts with "..") or missing; the caller checks.
    """
    if not url or EXTERNAL.match(url):
        return None
    path, _, fragment = url.partition("#")
    path = unquote(path.split("?", 1)[0])
    if not path:
        return rel, fragment
    base = "" if path.startswith("/") else os.path.dirname(rel)
    target = os.path.normpath(os.path.join(base, path.lstrip("/")))
    if path.endswith("/") or os.path.isdir(os.path.join(ROOT, target)):
        target = os.path.normpath(os.path.join(target, "index.html"))
    return target, fragment


def site_files():
    """The paths in deploy/site-files, without comments and blank lines, sorted."""
    with open(LIST, encoding="utf-8") as f:
        lines = (line.split("#", 1)[0].strip() for line in f)
        return sorted({line for line in lines if line})


def missing():
    """(file, 1, message) for every listed site file that isn't in ROOT."""
    return [(rel, 1, f"listed in deploy/site-files but not in {ROOT}")
            for rel in site_files() if not os.path.isfile(os.path.join(ROOT, rel))]


def report(errors):
    """Print "file:line: message" (and a GitHub annotation in Actions); return the exit code."""
    for rel, line, msg in errors:
        print(f"{rel}:{line}: {msg}")
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::error file={rel},line={line}::{msg}")
    return 1 if errors else 0
