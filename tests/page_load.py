"""CI / page-load: serve the site with python3 -m http.server and open / in headless Chromium.

Fails on any console error, page error, failed request or response that isn't 2xx/3xx,
a missing <title>, or avatar.jpg not loading. The browser's own /favicon.ico request is
ignored: the site has no favicon. Saves a full-page screenshot at 390 and 1440 wide.
Usage: python3 tests/page_load.py <screenshot dir>
Needs Playwright for Python and its Chromium (CI runs it in mcr.microsoft.com/playwright/python).
"""

import os
import socket
import subprocess
import sys
import time
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WIDTHS = (390, 1440)


def ignored(url):
    return urlparse(url).path == "/favicon.ico"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for(port):
    for _ in range(50):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return
        except OSError:
            time.sleep(0.1)
    sys.exit(f"http.server did not start on port {port}")


def check(browser, base, width, shots):
    errors = []
    page = browser.new_page(viewport={"width": width, "height": 900})
    page.on("console", lambda m: m.type == "error" and not ignored(m.location.get("url", ""))
            and errors.append(f"console error: {m.text} ({m.location.get('url')})"))
    page.on("pageerror", lambda e: errors.append(f"page error: {e}"))
    page.on("requestfailed", lambda r: not ignored(r.url)
            and errors.append(f"request failed: {r.url} ({r.failure})"))
    page.on("response", lambda r: r.status >= 400 and not ignored(r.url)
            and errors.append(f"HTTP {r.status}: {r.url}"))

    response = page.goto(base + "/", wait_until="load")
    if response is None or not response.ok:
        errors.append(f"/ returned {response.status if response else 'nothing'}")
    if not page.title().strip():
        errors.append("missing or empty <title>")
    avatars = page.locator("img[src$='avatar.jpg']")
    if avatars.count() == 0:
        errors.append("no <img> for avatar.jpg")
    elif not avatars.first.evaluate("img => img.complete && img.naturalWidth > 0"):
        errors.append("avatar.jpg did not load")

    path = os.path.join(shots, f"page-{width}.png")
    page.screenshot(path=path, full_page=True)
    print(f"{width}px: {'OK' if not errors else f'{len(errors)} error(s)'}, screenshot {path}")
    page.close()
    return [f"{width}px: {e}" for e in errors]


def main():
    shots = sys.argv[1] if len(sys.argv) > 1 else "screenshots"
    os.makedirs(shots, exist_ok=True)
    port = free_port()
    server = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", ROOT],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        wait_for(port)
        with sync_playwright() as p:
            browser = p.chromium.launch()
            errors = []
            for width in WIDTHS:
                errors += check(browser, f"http://127.0.0.1:{port}", width, shots)
            browser.close()
    finally:
        server.terminate()
        server.wait()
    for e in errors:
        print(e)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::error file=index.html::{e}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
