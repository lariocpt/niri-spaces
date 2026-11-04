#!/usr/bin/env python3
"""Fail if a public artifact breaks a promise the repo can't keep.

The docs page and the README are the front door every `curl | sh` reader walks
through, so their claims are gated like code. This checks, offline, that:

  * the page fetches nothing at load — no script/style/img/iframe/@import to a
    remote host, so the page renders identically with no network and leaks no
    visitor to a third party (system fonts only, nothing hosted);
  * the "Install" command points at the Pages route this repo actually deploys;
  * the "Commands" block is `niri-spaces --help` verbatim, so the page can't
    advertise a subcommand the CLI dropped or leak one it never had;
  * every subcommand either file advertises really exists in the CLI;
  * the hero showcase is exactly what tools/gen-showcase.py regenerates;
  * neither file claims the installer binds a keybind — it prints one;
  * no internal hostname or path from the author's machines, and no unreplaced
    placeholder, survived into a public file.

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
README = os.path.join(ROOT, "README.md")
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

# Placeholders that were never meant to be published. `myrepo-mono` was a real
# one: the README documented templating with a private example repository that
# does not exist in this release.
PLACEHOLDERS = (
    "myrepo-mono",
    "TODO",
    "FIXME",
    "mycompany",
    "example.com",
)

# Things the installer does NOT do, which an earlier README claimed it did. It
# prints the keybind line and refuses to edit a niri config; wording that says it
# binds, sets or writes the keybind is a false claim about shipped behaviour.
KEYBIND_CLAIMS = (
    "automatically binds",
    "auto-binds",
    "binds Mod+Ctrl+Shift+S for you",
    "sets the keybind",
    "writes the keybind",
)
KEYBIND_MENTIONS = ("Mod+Ctrl+Shift+S", "keybind")


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


def cli_help():
    """The CLI's own --help, or a hard stop naming the CLI as the failure.

    An empty --help is what this gate once received when the CLI died inside its own
    dependency preflight: every verb then looked unadvertised and the blame landed on the
    page. A CLI that cannot answer --help is the bug, so say that instead.
    """
    r = subprocess.run([CLI, "--help"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"{CLI} --help exited {r.returncode}: "
                 f"{(r.stderr or r.stdout).strip()[:200]}")
    text = r.stdout.strip()
    if not text:
        sys.exit(f"{CLI} --help printed nothing; the page cannot be checked against it")
    return text


def check_public_text(name, raw, helptext):
    """Claims shared by every public text artifact: README.md and docs/index.html.

    These files are the only thing most readers ever see, so a sentence here that
    the code does not support is a bug with the same severity as a broken command.
    """
    errors = []
    for s in FORBIDDEN:
        if s in raw:
            errors.append(f"{name}: forbidden internal string present: {s}")
    for s in PLACEHOLDERS:
        if s in raw:
            errors.append(f"{name}: unreplaced placeholder published: {s}")

    # The installer prints the keybind line and edits nothing (tests/10_install.bats
    # asserts both). Any phrasing that says otherwise describes behaviour that does
    # not exist, so check any keybind mention for a binding claim.
    low = raw.lower()
    for mention in KEYBIND_MENTIONS:
        if mention.lower() in low:
            for claim in KEYBIND_CLAIMS:
                if claim in low:
                    errors.append(
                        f"{name}: claims the installer '{claim}', but it only prints "
                        "the line and edits no niri config")
            break

    # A README code fence may advertise a subcommand; it must exist. Checked
    # against --help rather than against prose, so a renamed verb cannot survive.
    real = set(re.findall(r'^\s+niri-spaces\s+([\w-]+)', helptext, re.M))
    if not real:
        # Never blame the artifact for a help text that lists nothing.
        errors.append(f"{name}: the CLI's --help lists no subcommands to check against")
    for verb in set(re.findall(r'^\s*niri-spaces\s+([a-z][\w-]*)', raw, re.M)):
        if verb in ("--help",):
            continue
        if verb not in real:
            errors.append(f"{name}: advertises 'niri-spaces {verb}' which the CLI does not accept")

    # The advertised install command must be the route that answers.
    if INSTALL_URL not in raw:
        errors.append(f"{name}: does not reference the Pages install route {INSTALL_URL}")
    return errors


def check_local_refs(name, raw, path):
    """Every locally-referenced file must exist in the repo.

    This gate was written after a README shipped `<img src="docs/showcase/...">`
    for PNGs that nothing in this repository generates: the showcase was a
    picture of a product that does not exist, and nothing failed. A reference to
    a file that isn't there is the same class of defect as a command that lies
    about what it does, so it fails the build the same way.
    """
    base = os.path.dirname(path) or "."
    refs = set()
    for m in re.finditer(r'<img\b[^>]*\bsrc\s*=\s*["\']([^"\']+)["\']', raw, re.I):
        refs.add(m.group(1))
    for m in re.finditer(r'!\[[^\]]*\]\(\s*([^)\s]+)', raw):        # markdown image
        refs.add(m.group(1))
    for m in re.finditer(r'(?<!!)\]\(\s*([^)\s]+)', raw):           # markdown link
        refs.add(m.group(1))

    errors = []
    for ref in sorted(refs):
        if _is_external(ref) or ref.startswith(("#", "/", "mailto:")):
            continue
        target = ref.split("#", 1)[0].split("?", 1)[0]
        if not target:
            continue
        if not os.path.exists(os.path.join(base, target)):
            errors.append(f"{name}: references {ref}, which does not exist in this repo")
    return errors


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
    helptext = cli_help()
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
    helptext = cli_help()

    errs = []
    for name, path in (("README.md", README), ("docs/index.html", PAGE)):
        if not os.path.exists(path):
            errs.append(f"{name} is missing")
            continue
        with open(path) as f:
            raw = f.read()
        if name == "docs/index.html":
            errs += check(raw)
        errs += check_public_text(name, raw, helptext)
        errs += check_local_refs(name, raw, path)
    if errs:
        print("check-site: FAILED")
        for e in errs:
            print("  - " + e)
        return 1
    print("check-site: README.md and docs/index.html are self-contained, on-route, and match the CLI")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
