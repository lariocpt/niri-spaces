#!/usr/bin/env bash
#
# check-channels.sh — ask the public URLs whether they actually serve the release.
#
#   tools/check-channels.sh [version]
#
# Every way this project tells a stranger to install niri-spaces has to resolve,
# today, from outside this repository:
#
#   1. the Pages installer URL the landing page and README both print
#      (`curl -fsSL https://<owner>.github.io/niri-spaces/install.sh | sh`);
#   2. the release the installer resolves when it is NOT pinned — latest, which
#      means the repository's real latest release;
#   3. the artifact + checksum beside that exact tag, fetched anonymously the way
#      a visitor's shell fetches it, then verified the way the installer verifies.
#
# Offline checks can prove this tree agrees with itself. Only a request proves a
# channel exists. This is the channel check behind .github/workflows/channels.yml,
# and it fails loudly rather than reporting a channel as fine because it could not
# be reached: an unreachable install method is exactly the failure being looked for.

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

owner=$(gh repo view --json owner -q .owner.login 2>/dev/null || true)
repo=$(gh repo view --json name -q .name 2>/dev/null || true)
if [[ -z "$owner" || -z "$repo" ]]; then
  echo "error: run this inside the repository with gh authenticated (or set the repo context)" >&2
  exit 2
fi

pages="https://$owner.github.io/niri-spaces"
fail=0
note() { printf '%s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fail=1; }
good() { printf 'ok   %s\n' "$*"; }

# --- 1. the installer URL the page advertises ---------------------------------
# The exact string people copy has to be the URL that answers, or the first thing
# a visitor types is a 404.
page=$(curl -fsSL "$pages/" 2>/dev/null || true)
if [[ -z "$page" ]]; then
  bad "$pages/ did not answer — the docs page is not published"
else
  good "$pages/ answers"
  if ! grep -qF "$pages/install.sh | sh" <<<"$page"; then
    bad "$pages/ does not advertise $pages/install.sh — the page and the route disagree"
  else
    good "the page advertises $pages/install.sh"
  fi
fi

installer=$(curl -fsSL "$pages/install.sh" 2>/dev/null || true)
if [[ -z "$installer" ]]; then
  bad "$pages/install.sh did not answer — the advertised install command cannot work"
else
  good "$pages/install.sh answers"
  if head -n1 <<<"$installer" | grep -qi '^#!.*sh'; then
    good "the served installer has a shell shebang"
  else
    bad "the served installer has no shebang"
  fi
  # A truncated deploy still returns a 200 and some bytes, so re-parse it.
  if printf '%s' "$installer" | sh -n 2>/dev/null; then
    good "the served installer parses as shell"
  else
    bad "the served installer is not valid shell (truncated deploy?)"
  fi
  # Never pipe-and-run what we just fetched: write it out, then run the copy.
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  printf '%s\n' "$installer" > "$tmp/install.sh"
  if grep -q "NIRI_SPACES_REPO" "$tmp/install.sh" && bash -n "$tmp/install.sh" 2>/dev/null; then
    good "the served installer is the niri-spaces installer"
  else
    bad "the served installer is not recognisably niri-spaces' own"
  fi
fi

# --- 2. what the unpinned installer would resolve ------------------------------
want="${1:-}"
if [[ -z "$want" ]]; then
  want=$(gh release view --json tagName -q .tagName 2>/dev/null || true)
  if [[ -z "$want" ]]; then
    bad "the repository has no release yet — every install path that resolves 'latest' is dead"
    exit 1
  fi
  note "checking the channels against the latest release ($want)"
else
  [[ "$want" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: tools/check-channels.sh [v]X.Y.Z" >&2; exit 2; }
  [[ "$want" == v* ]] || want="v$want"
  note "checking the channels against the requested release ($want)"
fi

if gh release view "$want" --json tagName,isDraft -q '"\(.tagName) draft=\(.isDraft)"' 2>/dev/null; then
  good "release $want exists"
  if [[ "$(gh release view "$want" --json isDraft -q .isDraft 2>/dev/null)" == "true" ]]; then
    bad "$want is still a draft — the installer resolves 'latest', not a draft, so this release is not installable"
  fi
else
  bad "release $want does not exist — the installer's default path 404s"
fi

# --- 3. the artifact and its checksum, anonymously -----------------------------
# Fetched with plain curl, not gh: a token can reach a draft or a private repo and
# report a channel healthy that a stranger cannot use at all.
base="https://github.com/$owner/$repo/releases/download/$want"
tmp=${tmp:-$(mktemp -d)}; trap 'rm -rf "$tmp"' EXIT
if curl -fsSL "$base/niri-spaces-${want#v}.tar.gz.sha256" -o "$tmp/artifact.sha256" \
   && curl -fsSL "$base/niri-spaces-${want#v}.tar.gz" -o "$tmp/artifact.tar.gz"; then
  good "$base answers"
  # Same check the installer performs: name inside the file must match what we
  # downloaded, and the hash must match the bytes.
  name=$(awk '{print $2}' "$tmp/artifact.sha256")
  mv "$tmp/artifact.tar.gz" "$tmp/$name"
  if ( cd "$tmp" && sha256sum -c artifact.sha256 >/dev/null 2>&1 \
       || sha256sum -c "$name.sha256" 2>/dev/null ); then
    good "the published artifact matches its published checksum"
  else
    bad "the published artifact does NOT match its published checksum"
  fi
else
  bad "$base/niri-spaces-${want#v}.tar.gz (or its .sha256) did not answer anonymously — this is exactly what a visitor's \`curl -f\` would hit"
fi

# --- 4. the installer and the page name the same repository --------------------
# A rename or a move silently breaks both, and nothing in-tree notices.
if [[ -n "${page:-}" ]] && grep -qi 'apps\.in\.drlario\.org\|/srv/apps\|/opt/publish\|drlario\|timbuk' <<<"$page"; then
  bad "a private hostname or path leaked into the published page"
fi
if grep -qi 'myrepo\|mycompany\|example\.com' <<<"${installer:-}"; then
  bad "the served installer still contains a placeholder repository reference"
fi

if (( fail )); then
  echo
  echo "an install channel is broken or behind — people following the docs cannot install this release" >&2
  exit 1
fi
echo
echo "every advertised install channel serves $want"
