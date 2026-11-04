#!/usr/bin/env python3
"""Fail if docs/index.html breaks a promise the repo can't keep.

The docs page is the front door every `curl | sh` reader walks through, so its
claims are gated like code. This checks, offline, that:

  * the page fetches nothing at load — no script/style/img/iframe/@import to a
    remote host, so the page renders identically with no network and leaks no
    visitor to a third party (system fonts only, nothing hosted);
  * the "Install" command points at the Pages route this repo actually deploys;
  * the "Commands" block is `niri-spaces --help` verbatim, so the page can't
    advertise a subcommand the CLI dropped or leak one it never had;
  * every subcommand the page shows really exists in the CLI;
  * the hero showcase is exactly what tools/gen-showcase.py regenerates;
  * no internal hostname or path from the author's machines leaked into the page.

Exits non-zero with a readable list of every violation.
"""
import html
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PAGE = os.path.join(ROOT, "docs", "index.html")
CLI = os.path.join(ROOT, "niri-spaces")

# Hosts the page may LINK to (clicking is fine; auto-loading is not).
ALLOWED_LINK_HOSTS = {"github.com", "lariocpt.github.io"}
# The installer URL must be exactly this — the Pages route that serves docs/.
INSTALL_URL = "https://lariocpt.github.io/niri-spaces/install.sh"

# Strings that would betray the author's private network. A public page must not
# carry any of them.
FORBIDDEN = (
    "apps.in.drlario.org",
    "/srv/apps",
    "/opt/publish",
    "drlario",
    "timbuk",
)


def _attr_urls(raw):
    """(tag, url) for every auto-loading element or remote CSS we must not have."""
    hits = []
    for m in re.finditer(r'<(script|link|img|iframe)\b[^>]*>', raw, re.I):
        tag = m.group(0)
        u = re.search(r'(?:src|href)\s*=\s*["\']([^"\']+)["\']', tag, re.I)
        if u:
            hits.append((m.group(1).lower(), u.group(1)))
    for m in re.finditer(r'@import\s+url\(([^)]+)\)', raw, re.I):
        hits.append(("@import", m.group(1).strip('\'"')))
    for m in re.finditer(r'\bsrcset\s*=\s*["\']([^"\']+)["\']', raw, re.I):
        hits.append(("srcset", m.group(1).split()[0]))
    return hits


def _is_external(url):
    return bool(re.match(r'(?:https?:)?//', url)) or url.lower().startswith("data:text/html")


def check(raw):
    errors = []
    # 1. Nothing auto-loads from a remote host.
    for tag, url in _attr_urls(raw):
        if _is_external(url):
            errors.append(f"page auto-loads a remote resource: <{tag}> {url}")

    # 2. Links point only at allowed hosts.
    for m in re.finditer(r'href\s*=\s*["\'](https?://[^"\']+)["\']', raw, re.I):
        url = m.group(1)
        host = re.match(r'https?://([^/]+)', url).group(1).lower()
        if host not in ALLOWED_LINK_HOSTS:
            errors.append(f"page links to an unexpected host: {url}")

    # 3. Install command is the Pages route, in both the snippet and its caption.
    if INSTALL_URL not in raw:
        errors.append(f"install command does not reference the Pages route {INSTALL_URL}")
    # The shown command pipes that exact URL to sh.
    if not re.search(re.escape(INSTALL_URL) + r'\s*\|\s*sh', raw):
        errors.append("install snippet does not pipe the Pages installer to sh")

    # 4. Commands block == `--help` verbatim.
    helptext = subprocess.run(
        [CLI, "--help"], capture_output=True, text=True,
    ).stdout.strip()
    unescaped = html.unescape(raw)
    if helptext not in unescaped:
        errors.append("the Commands block is not `niri-spaces --help` verbatim")

    # 5. Every subcommand advertised inside the help block really exists. Only the
    #    block that renders `--help` is inspected, so prose ("niri-spaces loads…")
    #    can't be mistaken for a command; a verb the CLI dropped is still caught.
    real = set(re.findall(r'^\s+niri-spaces\s+([\w-]+)', helptext, re.M))
    m = re.search(r'id="help-text"[^>]*>(.*?)</pre>', raw, re.S)
    block = html.unescape(m.group(1)) if m else ""
    advertised = set(re.findall(r'^\s+niri-spaces\s+([a-z][\w-]*)', block, re.M))
    for verb in advertised - real:
        errors.append(
            "help block advertises 'niri-spaces %s' but the CLI's --help does not list it" % verb)
    if not advertised:
        errors.append("help block lists no subcommands")

    # 6. Showcase markers present and non-empty.
    if "<!-- BEGIN GENERATED SHOWCASE" not in raw or "<!-- END GENERATED SHOWCASE" not in raw:
        errors.append("generated-showcase markers missing from the page")

    # 7. No private hostnames/paths.
    for s in FORBIDDEN:
        if s in raw:
            errors.append(f"forbidden internal string present in the page: {s}")

    return errors


def main():
    with open(PAGE) as f:
        raw = f.read()
    errs = check(raw)
    if errs:
        print("check-site: FAILED")
        for e in errs:
            print("  - " + e)
        return 1
    print("check-site: docs/index.html is self-contained, on-route, and matches the CLI")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
