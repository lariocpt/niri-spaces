#!/usr/bin/env python3
"""Generate the hero showcase shown on the docs page and in the README, from the
real splash.

The page and the README both render `space-splash` against a throwaway git repo so
the picture is the program's actual output, not a screenshot of a moment in time.
Two things in the splash would otherwise make that output drift and so defeat
`--check`:

  * the commit line is `git log -1 --format='%s (%cr)'` — the `%cr` "3 hours ago"
    ages forever, so a committed copy would differ from a regenerated one;
  * a dirty tree would print a different modified-file count than a clean one.

So we build a scratch repo with a pinned author date and a clean tree, and put a
`git` shim on PATH that answers the single `%cr` query with a fixed line while
forwarding every other call to the real git unchanged. The branch, subject, clean
status and box width are all real splash output; only the relative-time suffix is
frozen, which is exactly the part that could not be made stable by pinning a date
(`%cr` measures distance to *now*).

Run with `--check` to fail if either document's showcase block no longer matches
a fresh generation.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SPLASH = os.path.join(ROOT, "space-splash")
PAGE = os.path.join(ROOT, "docs", "index.html")

BEGIN = "<!-- BEGIN GENERATED SHOWCASE (tools/gen-showcase.py) -->"
END = "<!-- END GENERATED SHOWCASE -->"

# The frozen git identity the showcase pretends to be. "web" is the space a user
# would actually load (the browser workspace), so the ASCII art reads WEB.
SCRATCH_DIR = "web"
FIXED_BRANCH = "main"
FIXED_SUBJECT = "declarative layouts"
FIXED_LOG_LINE = f"{FIXED_SUBJECT} (2 hours ago)"
FIXED_DATE = "2026-01-01T00:00:00+00:00"


def _write(path, text, mode=0o644):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


def render_splash():
    """Run the real space-splash against a pinned scratch git repo."""
    real_git = shutil.which("git")
    if not real_git:
        raise SystemExit("gen-showcase: git is required to build the scratch repo")

    # The splash sizes its box from the longest line and TRUNCATES each info line
    # to (box_width - 6) chars. Two constraints set the fixed path length:
    #   * the Path line is "Path:      " (11 chars) + the absolute path, and must
    #     fit under the 48-char cut, so the path is at most 37;
    #   * a git line forces the content width to 50 (box_width 54), so the commit
    #     line "Commit: ... (2 hours ago)" (44 chars) fits under the 48-char cut.
    # A 37-char path satisfies both: it shows in full, the box is a stable width,
    # and the bytes are identical for anyone running the generator.
    SCRATCH_LEN = 37
    leaf = SCRATCH_DIR                       # "web"
    tmp = tempfile.gettempdir().rstrip(os.sep) or os.sep
    pad = SCRATCH_LEN - len(tmp) - 2 - len(leaf)   # two separators: tmp/root and root/web
    if pad < 1:
        raise SystemExit("gen-showcase: temp root too long to build a fixed-length path")
    scratch_root = "x" * pad                # fills the gap so len(repo) is fixed
    repo = os.path.join(tmp, scratch_root, leaf)
    assert len(repo) == SCRATCH_LEN, (len(repo), repo)

    shutil.rmtree(os.path.join(tmp, scratch_root), ignore_errors=True)
    base = os.path.dirname(repo)
    os.makedirs(base, exist_ok=True)
    try:
        shim_dir = os.path.join(base, ".gen-shim")
        shutil.rmtree(shim_dir, ignore_errors=True)
        os.makedirs(shim_dir)
        # Forward every git call to the real binary except the one relative-time
        # query the splash makes, which gets a frozen answer.
        _write(
            os.path.join(shim_dir, "git"),
            "#!/bin/sh\n"
            'if [ "$1" = log ]; then printf \'%s\\n\'; exit 0; fi\n'
            'exec "%s" "$@"\n' % (FIXED_LOG_LINE, real_git),
            0o755,
        )

        os.makedirs(repo)
        env = dict(
            os.environ,
            PATH=shim_dir + os.pathsep + os.environ.get("PATH", ""),
            GIT_AUTHOR_DATE=FIXED_DATE,
            GIT_COMMITTER_DATE=FIXED_DATE,
            GIT_AUTHOR_NAME="niri-spaces",
            GIT_AUTHOR_EMAIL="showcase@localhost",
            GIT_COMMITTER_NAME="niri-spaces",
            GIT_COMMITTER_EMAIL="showcase@localhost",
        )
        git = ["git", "-c", "commit.gpgsign=false"]
        subprocess.run(git + ["init", "-q", "-b", FIXED_BRANCH], cwd=repo, env=env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _write(os.path.join(repo, "web.space"), "@workspace 2\nbrave | brave\n")
        subprocess.run(git + ["add", "-A"], cwd=repo, env=env, check=True)
        subprocess.run(git + ["commit", "-q", "-m", FIXED_SUBJECT], cwd=repo, env=env,
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        out = subprocess.run(
            [sys.executable, SPLASH, repo], env=env, check=True,
            capture_output=True, text=True,
        ).stdout
        # Show a presentable path padded to the scratch path's exact width (so the
        # box, sized from that width, stays aligned), then rstrip — trailing space
        # is invisible and keeps the committed bytes identical on every machine.
        pretty = "~/dev/projects/web".ljust(len(repo))
        return "\n".join(ln.rstrip() for ln in out.replace(repo, pretty).split("\n"))
    finally:
        shutil.rmtree(os.path.join(tmp, scratch_root), ignore_errors=True)


def wrap(splash_out, style):
    """Embed the art in the target's own dialect: an HTML <pre> for the page,
    a fenced block for the README. Same bytes, two containers."""
    if style == "html":
        indented = "\n".join("    " + ln for ln in splash_out.rstrip("\n").split("\n"))
        return "{b}\n<pre class=\"splash\">\n{body}\n</pre>\n{e}".format(
            b=BEGIN, body=indented, e=END)
    return "{b}\n```text\n{body}\n```\n{e}".format(
        b=BEGIN, body=splash_out.rstrip("\n"), e=END)


# The same real splash output appears on the page and at the top of the README.
# Splicing it into both is the point: neither document can drift from what the
# program prints, and neither can claim a picture the program does not draw.
TARGETS = (
    (PAGE, "html"),
    (os.path.join(ROOT, "README.md"), "md"),
)


def read(path):
    with open(path) as f:
        return f.read()


def splice(html, block):
    i = html.index(BEGIN)
    j = html.index(END) + len(END)
    return html[:i] + block + html[j:]


def main():
    check = "--check" in sys.argv[1:]
    art = render_splash()
    stale = []
    for path, style in TARGETS:
        block = wrap(art, style)
        doc = read(path)
        if BEGIN not in doc or END not in doc:
            raise SystemExit("gen-showcase: markers not found in %s" % path)
        current = doc[doc.index(BEGIN):doc.index(END) + len(END)]
        if current == block:
            continue
        stale.append(path)
        if not check:
            with open(path, "w") as f:
                f.write(splice(doc, block))
    if stale and check:
        sys.stderr.write(
            "gen-showcase: showcase is STALE in: %s\n"
            "Re-run: python3 tools/gen-showcase.py\n" % ", ".join(
                os.path.relpath(p, ROOT) for p in stale))
        return 1
    if stale:
        print("gen-showcase: updated showcase in %s"
              % ", ".join(os.path.relpath(p, ROOT) for p in stale))
    else:
        print("gen-showcase: showcase is up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
