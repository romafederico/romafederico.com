"""Site files and the local references in them, shared by the CI checks.

Site files are the *.html and *.css at the repo root and the files they reference.
#5 makes the package's file list the single source; until then this reads the repo root.
"""

import os
import re
from html.parser import HTMLParser
from urllib.parse import unquote

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# url(...) and @import "..." in CSS (a <style> block or a style="" attribute too).
CSS_URL = re.compile(r"""url\(\s*(['"]?)(.*?)\1\s*\)|@import\s+(['"])(.*?)\3""", re.I | re.S)
# Anything with a scheme (https:, mailto:, data:, ...) or protocol-relative (//host) is not a local file.
EXTERNAL = re.compile(r"^([a-z][a-z0-9+.-]*:|//)", re.I)
URL_ATTRS = {"href", "src", "poster", "data", "action", "formaction", "cite", "background"}


def root_files():
    """The *.html and *.css at the repo root, sorted."""
    return sorted(f for f in os.listdir(ROOT) if f.endswith((".html", ".css")))


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
    """Root *.html and *.css plus every existing local file they reference, sorted."""
    files = set(root_files())
    for rel in root_files():
        for _, url in refs(rel):
            r = resolve(rel, url)
            if r and not r[0].startswith("..") and os.path.isfile(os.path.join(ROOT, r[0])):
                files.add(r[0])
    return sorted(files)


def report(errors):
    """Print "file:line: message" (and a GitHub annotation in Actions); return the exit code."""
    for rel, line, msg in errors:
        print(f"{rel}:{line}: {msg}")
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::error file={rel},line={line}::{msg}")
    return 1 if errors else 0
