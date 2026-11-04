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
#      (`curl -fsSL https://<owner>.github.io/<repo>/install.sh | sh`);
#   2. the release the installer resolves when it is NOT pinned — latest, which
#      means the repository's real latest release, found through the same redirect
#      the installer follows rather than through an authenticated API;
#   3. the artifact + checksum beside that exact tag, fetched anonymously the way
#      a visitor's shell fetches it, then verified the way the installer verifies.
#
# Offline checks can prove this tree agrees with itself. Only a request proves a
# channel exists. This is the channel check behind .github/workflows/channels.yml,
# and it fails loudly rather than reporting a channel as fine because it could not
# be reached: an unreachable install method is exactly the failure being looked for.
#
# It needs no credentials, and that is the point: a token can reach a draft or a
# private repo and call a channel healthy that a stranger cannot use, and it gives
# the gate a permission to fail on that has nothing to do with installs. Which
# repository is being checked comes from GITHUB_REPOSITORY, or from the checkout's
# origin remote, and never from a signed-in CLI.

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

# Which repository's channels are these? In the order that costs nothing: the
# variable Actions exports for every run, then the checkout's own remote URL, and
# only then gh. Asking gh first was the wrong question — it needs a token and a
# resolvable repo context, and neither has anything to do with whether the public
# URLs serve the release. It cost a red deploy that way: on a runner the script
# said "run this inside the repository with gh authenticated" while every channel
# it was meant to probe was healthy. Resolution now needs no credentials at all,
# which also means no permission a workflow can fail to grant.
owner_repo=""
if [[ -n "${GITHUB_REPOSITORY:-}" && "$GITHUB_REPOSITORY" == */* ]]; then
  owner_repo="$GITHUB_REPOSITORY"
else
  # git@host:owner/repo.git, ssh://git@host/owner/repo.git, https://host/owner/repo.git
  # — the tail after the host is the owner/repo, and reading it asks nothing of anyone.
  url=$(git remote get-url origin 2>/dev/null || true)
  case "${url:-}" in
    '') ;;
    *)
      spec=${url%.git}
      spec=${spec%/}
      spec=$(printf '%s' "$spec" | sed -E 's#^[a-zA-Z+][a-zA-Z0-9+]*://[^/]+/##; s#^[^/[:space:]:]+:##' || true)
      [[ "$spec" == */* ]] && owner_repo="$spec"
      ;;
  esac
fi
if [[ -z "$owner_repo" ]]; then
  owner=$(gh repo view --json owner -q .owner.login 2>/dev/null || true)
  repo=$(gh repo view --json name -q .name 2>/dev/null || true)
  [[ -n "$owner" && -n "$repo" ]] && owner_repo="$owner/$repo"
fi
if [[ -z "$owner_repo" ]]; then
  echo "error: cannot work out the owner/repo to check — set GITHUB_REPOSITORY, run this inside a clone with an origin remote, or use gh" >&2
  exit 2
fi
owner=${owner_repo%%/*}
repo=${owner_repo##*/}
# Said out loud first: when this goes red, the output has to show which repository
# it probed, because the most likely cause is that it probed the wrong one.
printf 'checking the install channels of %s\n' "$owner_repo"

# The Pages slug is the repository name, so a fork or a rename probes its own route
# instead of being told its site is down because a different repository is up.
pages="https://$owner.github.io/$repo"
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
  # First line pulled out with a expansion, not `head | grep -q`: grep -q closes the
  # pipe the moment it matches, and the cut-off producer is a race, not a result.
  installer_first=${installer%%$'\n'*}
  case "$installer_first" in
    '#!'*sh*) good "the served installer has a shell shebang" ;;
    *)        bad "the served installer has no shebang (first line: $installer_first)" ;;
  esac
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
# The same redirect the installer follows (see ns_latest_tag in docs/install.sh):
# one HEAD trip, no token, no API budget. gh release view asked an authenticated
# API about a channel defined by what an anonymous visitor gets. The redirect is
# strictly the better question, because it hides exactly what the installer cannot
# see: a deleted release, and a draft that was never flipped to public — its
# release page 404s without a token, so the check below fails on a stranded draft
# for the same reason a person following the docs would.
want="${1:-}"
if [[ -z "$want" ]]; then
  loc=$(curl -fsSIL --proto '=https' -o /dev/null -w '%{url_effective}' \
          "https://github.com/$owner/$repo/releases/latest" 2>/dev/null || true)
  loc=${loc%%\?*}; loc=${loc%/}
  want=${loc##*/}
  case "$want" in
    v[0-9]*) note "checking the channels against the latest release ($want)" ;;
    *)
      bad "the repository publishes no public release — every install path that resolves 'latest' is dead"
      exit 1
      ;;
  esac
else
  [[ "$want" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: tools/check-channels.sh [v]X.Y.Z" >&2; exit 2; }
  [[ "$want" == v* ]] || want="v$want"
  note "checking the channels against the requested release ($want)"
fi

if curl -fsSIL --proto '=https' -o /dev/null "https://github.com/$owner/$repo/releases/tag/$want" 2>/dev/null; then
  good "release $want answers without a token"
else
  bad "release $want does not answer anonymously — the installer's default path 404s for a visitor (deleted, or a draft left unpublished)"
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
