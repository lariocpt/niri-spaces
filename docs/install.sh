#!/bin/sh
# install.sh — the public installer for niri-spaces.
#
#     curl -fsSL https://lariocpt.github.io/niri-spaces/install.sh | sh
#
# The source of truth is the public GitHub release of lariocpt/niri-spaces. It
# resolves the latest release through the /releases/latest redirect (or a
# pinned --tag), downloads the archive and the .sha256 beside it, verifies the
# checksum, and only then installs:
#
#   niri-spaces, space-splash, niri-terminal-pairs, niri-workspace-colors, niri-workspace-strip ->  $PREFIX/bin          (default ~/.local/bin)
#   settings.json, autostart, spaces/*.space ->  ~/.config/niri-spaces/
#
# Config files are copied only where they do not already exist: a file you have
# edited is kept, and the install says so. Nothing here edits a niri config —
# the Mod+Ctrl+Shift+S keybind and the autostart wiring are printed as
# suggestions.
#
# Tarball contract (a later release workflow builds exactly this):
#
#   niri-spaces-X.Y.Z.tar.gz — a gzip'ed tar whose single root entry is
#     niri-spaces-X.Y.Z/
#       niri-spaces            the CLI
#       space-splash           the splash
#       niri-terminal-pairs    the terminal pairing daemon
#       niri-workspace-colors  the workspace color watcher
#       niri-workspace-strip   the draggable workspace strip
#       settings.json          the default configuration
#       autostart      the default autostart file
#       spaces/        the *.space layouts
#       LICENSE
#       README.md
#   and its checksum sidecar, the archive's own name plus .sha256 —
#   sha256sum format, LF-terminated.
#
# POSIX sh on purpose: this is run by whatever /bin/sh the reader has — dash, ash,
# busybox, bash in posix mode. No arrays, no [[ ]], no `local`, no pipefail.
#
# EVERYTHING LIVES IN FUNCTIONS AND THE LAST LINE IS `main "$@"`. That is not
# style. The script is executed straight off a socket; if the connection dies
# halfway, a top-to-bottom script would run the half that arrived. sh cannot call
# main until it has read the closing brace, so a truncated download does nothing
# at all.
#
# Options (env var in brackets):
#   vX.Y.Z, --tag=vX.Y.Z        install one release, not the latest    [NIRI_SPACES_VERSION]
#   --prefix=DIR                install root; bins go in DIR/bin, default ~/.local  [NIRI_SPACES_PREFIX]
#   -n, --dry-run               verify and print every action; write nothing outside $TMPDIR
#   -h, --help                  this text
#
# Also honoured: NIRI_SPACES_REPO (owner/name, default lariocpt/niri-spaces).
#
# TESTING HOOK, not a user feature: --file=PATH.tar.gz (plus --sha256=HEX, or a
# <PATH.tar.gz>.sha256 sidecar beside it) installs from a local artifact with
# identical verification — same refusal rules, same layout checks, never less.
# CI builds a throwaway tarball to the contract above and installs it from disk,
# which proves the release path end to end before a release exists.
set -eu

NS_REPO_DEFAULT='lariocpt/niri-spaces'

ns_say()  { printf 'niri-spaces: %s\n' "$*"; }
ns_warn() { printf 'niri-spaces: %s\n' "$*" >&2; }
ns_die()  { ns_warn "$*"; exit 1; }
ns_have() { command -v "$1" >/dev/null 2>&1; }

# A heredoc, not a sed range over "$0": piped through sh there is no $0 to read.
ns_usage() {
    cat <<'EOF'
install.sh — install niri-spaces from its published GitHub release.

    curl -fsSL https://lariocpt.github.io/niri-spaces/install.sh | sh
    curl -fsSL https://lariocpt.github.io/niri-spaces/install.sh | sh -s -- --dry-run
    curl -fsSL https://lariocpt.github.io/niri-spaces/install.sh | sh -s -- v0.1.0

Options (env var in brackets):
  vX.Y.Z, --tag=vX.Y.Z        install one release, not the latest    [NIRI_SPACES_VERSION]
  --prefix=DIR                install root; bins go in DIR/bin, default ~/.local  [NIRI_SPACES_PREFIX]
  -n, --dry-run               verify and print every action; write nothing outside $TMPDIR
  --file=PATH.tar.gz          testing hook: install from a local artifact (CI only)
  --sha256=HEX                expected hash for --file (else the <PATH.tar.gz>.sha256 sidecar)
  -h, --help                  this text

Also honoured: NIRI_SPACES_REPO (owner/name, default lariocpt/niri-spaces).
The download is verified against the release's .sha256 before anything runs.
EOF
}

# Invoked only from trap strings, which shellcheck cannot see through — as
# SC2317 on the apt 0.9.0 the runners use and SC2329 on the modern one.
# shellcheck disable=SC2317,SC2329
ns_cleanup() { if [ -n "${NS_TMP:-}" ]; then rm -rf "$NS_TMP"; fi; }

# Fetch https only: this script reaches the public GitHub release and nothing
# else. What makes the transport worth trusting is the sha256 check, which is
# never skipped.
ns_fetch() {                                  # <url> <dest>
    if ns_have curl; then
        curl -fsSL --proto '=https' --retry 3 --retry-delay 1 -o "$2" "$1"
    elif ns_have wget; then
        # busybox wget has no --https-only and rejects the whole command line when
        # it sees one, so ask before using it.
        if ns_wget_https_only; then
            wget -q --https-only -O "$2" "$1"
        else
            wget -q -O "$2" "$1"
        fi
    else
        ns_die 'need curl or wget to download a release'
    fi
}

ns_wget_https_only() {
    if [ -z "${NS_WGET_HTTPS:-}" ]; then
        # wget's help is captured, not piped into grep -q: grep exits on the first
        # match, and a producer cut off mid-write is a failure that only shows up
        # when the shell keeps pipe statuses (ash and bash both can).
        ns_wget_help=$(wget --help 2>&1 || :)
        case "$ns_wget_help" in
            *--https-only*) NS_WGET_HTTPS=yes ;;
            *)              NS_WGET_HTTPS=no ;;
        esac
    fi
    [ "$NS_WGET_HTTPS" = yes ]
}

# Fail closed. A checksum you cannot compute is not a checksum, and the job of
# this script is to put executables on somebody's PATH and copy config next to
# theirs. There is deliberately no branch that skips the check.
ns_sha256() {                                 # <file> -> hex on stdout
    if   ns_have sha256sum; then sha256sum "$1" | cut -d' ' -f1
    elif ns_have shasum;    then shasum -a 256 "$1" | cut -d' ' -f1
    else return 1
    fi
}

ns_verify() {                                 # <file> <want>
    ns_have sha256sum || ns_have shasum || \
        ns_die 'no sha256sum or shasum on this machine — refusing to install an unverified artifact'
    # An empty hash is a hasher that failed, not a file that mismatched; say which.
    got=$(ns_sha256 "$1") || \
        ns_die 'could not hash the file (hasher failed) — refusing to continue'
    [ -n "$got" ] || \
        ns_die 'could not hash the file (hasher failed) — refusing to continue'
    got=$(printf '%s' "$got" | tr 'A-F' 'a-f')
    want=$(printf '%s' "$2" | tr 'A-F' 'a-f')
    [ "$want" = "$got" ] || ns_die "CHECKSUM MISMATCH — do not use the downloaded file
  expected $want
  got      $got"
    ns_say "verified $1"
}

# The sidecar is `sha256sum` format ("hex  filename") or a bare 64-hex line.
# Take the first field and require it to look like a hash before trusting it
# against the computed one — an HTML error page served with a 200 must not
# parse as a checksum.
ns_want_from_file() {                         # <file> -> hex; 1 when it cannot claim one
    [ -r "$1" ] || return 1
    want=$(awk 'NR==1 && length($1)==64 && $1 !~ /[^0-9a-fA-F]/ { print $1 }' "$1" 2>/dev/null) || return 1
    [ -n "$want" ] || return 1
    printf '%s' "$want"
}

# --sha256 is typed by a human or a CI yaml; a typo must refuse, not install.
ns_looks_like_hex() {                         # <string>
    case "$1" in
        '' | *[!0-9a-fA-F]*) return 1 ;;
    esac
    [ "${#1}" -eq 64 ]
}

# Pin the tag ONCE, then fetch the archive and its sidecar from that tag's own
# directory. Two separate trips through /releases/latest/ can straddle a release
# and pair the old checksum with the new file — and then accuse a perfect
# download of tampering. One redirect, no token, no API budget.
ns_latest_tag() {                             # <owner/repo> -> tag on stdout
    url="https://github.com/$1/releases/latest"
    if ns_have curl; then
        loc=$(curl -fsSIL --proto '=https' -o /dev/null -w '%{url_effective}' "$url") || return 1
    else
        loc=$(wget --spider -S "$url" 2>&1 | sed -n 's/^ *[Ll]ocation: *//p' | tail -1)
    fi
    loc=${loc%%\?*}; loc=${loc%/}
    tag=${loc##*/}
    case "$tag" in v[0-9]*) printf '%s' "$tag" ;; *) return 1 ;; esac
}

ns_resolve_github() {                         # -> NS_VERSION, NS_ARCHIVE, NS_URL, NS_SUMS_URL
    repo="${NIRI_SPACES_REPO:-$NS_REPO_DEFAULT}"
    if [ "$NS_VERSION" = latest ]; then
        tag=$(ns_latest_tag "$repo") \
            || ns_die "could not resolve the latest release of $repo — is one published?"
        # The archive is named for the resolved version, never for 'latest'.
        NS_VERSION=${tag#v}
    else
        tag="v$NS_VERSION"                    # GitHub tags carry the v; versions do not
    fi
    NS_ARCHIVE="niri-spaces-$NS_VERSION.tar.gz"
    NS_URL="https://github.com/$repo/releases/download/$tag/$NS_ARCHIVE"
    NS_SUMS_URL="$NS_URL.sha256"
}

# The testing hook: install from a local artifact. The verification below is
# identical to the download path's — that is the point of the hook: CI proves
# the release path without a published release, not a weaker private one.
ns_resolve_local() {                          # -> NS_TARBALL, NS_WANT
    [ -f "$NS_FILE" ] || ns_die "cannot find local artifact $NS_FILE"
    [ -r "$NS_FILE" ] || ns_die "cannot read local artifact $NS_FILE"
    case "$NS_FILE" in /*) ;; *) NS_FILE="$PWD/$NS_FILE" ;; esac
    NS_TARBALL=$NS_FILE
    if [ -n "$NS_SHA256" ]; then
        ns_looks_like_hex "$NS_SHA256" || \
            ns_die "--sha256 must be 64 hex characters, got '$NS_SHA256'"
        NS_WANT=$NS_SHA256
    else
        # The sidecar sits beside the artifact, named for it — the same
        # convention the release publishes.
        NS_WANT=$(ns_want_from_file "$NS_FILE.sha256") || \
            ns_die "no --sha256 given and no readable $NS_FILE.sha256 sidecar — refusing an unverified artifact"
    fi
}

# The archive is unpacked only after it verified; its layout is checked only
# here. Everything the install acts on must name itself, so a stray tarball
# fails on the first member it is missing, not on a confused install.
ns_extract() {                                # -> NS_ROOT, NS_VERSION
    ns_have tar || ns_die 'need tar to unpack the artifact'
    mkdir -p "$NS_TMP/x" || ns_die 'cannot create a work directory'
    tar -xzf "$NS_TARBALL" -C "$NS_TMP/x" || ns_die "could not extract $NS_TARBALL"
    NS_ROOT=$(find "$NS_TMP/x" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
    [ -n "$NS_ROOT" ] || \
        ns_die "$NS_TARBALL has no top-level directory — the contract is a single root dir niri-spaces-X.Y.Z/"
    NS_ROOT=$(cd "$NS_ROOT" && pwd)
    base=${NS_ROOT##*/}
    case "$base" in
        niri-spaces-*) ver=${base#niri-spaces-} ;;
        *) ns_die "unexpected root dir '$base' — the contract is niri-spaces-X.Y.Z/" ;;
    esac
    case "$ver" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) ns_die "root dir '$base' is not niri-spaces-X.Y.Z" ;;
    esac
    if [ "$NS_VERSION" != latest ]; then
        [ "$NS_VERSION" = "$ver" ] || \
            ns_die "artifact is niri-spaces-$ver, not the pinned $NS_VERSION"
    else
        NS_VERSION=$ver                       # 'latest' becomes the concrete version
    fi
    for m in niri-spaces space-splash autostart spaces LICENSE README.md; do
        [ -e "$NS_ROOT/$m" ] || \
            ns_die "$NS_TARBALL is missing the required member '$m' (contract: niri-spaces, space-splash, autostart, spaces/, LICENSE, README.md)"
    done
    [ -d "$NS_ROOT/spaces" ] || \
        ns_die "$NS_TARBALL's 'spaces' entry is not a directory"
    found=''
    for f in "$NS_ROOT"/spaces/*.space; do
        if [ -f "$f" ]; then found=1; break; fi
    done
    [ -n "$found" ] || ns_die "$NS_TARBALL's spaces/ holds no *.space layouts"
}

# The CLI hard-depends on both: without niri there is no compositor to drive,
# and without jq the window diff that learns each spawned window's id yields
# nothing — every app then hits the 10-second timeout and the failure looks
# like niri being slow. Say which is missing, and name the fix, before
# anything is downloaded. Run even for --dry-run: a plan the install would
# refuse to carry out is printed as a refusal, not guessed at.
ns_preflight() {
    for dep in niri jq; do
        if ! ns_have "$dep"; then
            case "$dep" in
                niri) ns_die "niri is not on PATH — install niri (https://github.com/YaLTeR/niri) before installing niri-spaces" ;;
                jq)   ns_die "jq is not on PATH — install jq from your distribution's package manager before installing niri-spaces" ;;
            esac
        fi
    done
    if [ -n "$NS_FILE" ]; then
        :                                     # a local artifact needs no network tool
    else
        ns_have curl || ns_have wget || \
            ns_die 'need curl or wget to download the release (or use --file= for a local artifact)'
    fi
    ns_have tar || ns_die 'need tar to unpack the artifact'
}

# -D makes the parent directories and -m sets the mode in one step. The bins
# are ours, so re-installing replaces them; what is never overwritten is the
# config, below.
ns_install_bin() {                            # <src> <dest>
    install -Dm0755 "$1" "$2" || ns_die "cannot write $2"
}

# Config is the user's after the first install: never overwrite a file that
# already exists, and say plainly when you kept one — a silent keep reads as a
# skipped install.
ns_keep_or_copy() {                           # <src> <dest>
    if [ -e "$2" ]; then
        ns_say "kept existing $2 (not overwritten)"
        return 0
    fi
    mkdir -p "$(dirname "$2")" || ns_die "cannot create $(dirname "$2")"
    cp "$1" "$2" || ns_die "cannot write $2"
    ns_say "installed $2"
}

# The old installer sed'd the user's config.kdl. Editing a file the compositor
# reads is not this installer's job: the exact line goes here, as a suggestion.
ns_suggest_keybind() {
    ns_say "niri keybind — add this line by hand; nothing was edited:
  where:  ~/.config/niri/config.kdl — or, if your config uses the cfg/ split,
          ~/.config/niri/cfg/keybinds.kdl
  line:   Mod+Ctrl+Shift+S hotkey-overlay-title=\"Niri Spaces: Menu\" { spawn \"niri-spaces\" \"menu\"; }
  and, to load the spaces at every session start, have your niri autostart run:
          autostart \"niri-spaces start\""
}

ns_plan_file() {                              # <src> <dest>
    if [ -e "$2" ]; then
        ns_say "    would KEEP existing $2 (it is never overwritten)"
    else
        ns_say "    would install $2"
    fi
}

# A dry run verifies everything read-only and prints the exact plan — which is
# why it still downloads (into the work directory) and verifies: the plan is
# the list of actions as they would really be taken, not a guess. It writes
# nothing outside $TMPDIR.
ns_plan() {
    ns_say "dry run — niri-spaces $NS_VERSION from $NS_SOURCE; nothing below will be written:"
    ns_say "  bins:"
    ns_say "    $NS_PREFIX/bin/niri-spaces"
    ns_say "    $NS_PREFIX/bin/space-splash"
    if [ -f "$NS_ROOT/niri-terminal-pairs" ]; then
        ns_say "    $NS_PREFIX/bin/niri-terminal-pairs"
        ns_plan_file "$NS_ROOT/settings.json" "$NS_CFG/settings.json"
    fi
    if [ -f "$NS_ROOT/niri-workspace-colors" ]; then
        ns_say "    $NS_PREFIX/bin/niri-workspace-colors"
    fi
    if [ -f "$NS_ROOT/niri-workspace-strip" ]; then
        ns_say "    $NS_PREFIX/bin/niri-workspace-strip"
    fi
    ns_say "  config (under $NS_CFG; existing files are kept):"
    ns_plan_file "$NS_ROOT/autostart" "$NS_CFG/autostart"
    for f in "$NS_ROOT"/spaces/*.space; do
        if [ -f "$f" ]; then ns_plan_file "$f" "$NS_CFG/spaces/${f##*/}"; fi
    done
    ns_say "    $NS_CFG/templates/ (directory, created if missing)"
    ns_say "  keybind suggestion, printed at install time, never written:"
    ns_say "    Mod+Ctrl+Shift+S hotkey-overlay-title=\"Niri Spaces: Menu\" { spawn \"niri-spaces\" \"menu\"; }"
}

main() {
    NS_VERSION=${NIRI_SPACES_VERSION:-latest}
    NS_PREFIX=${NIRI_SPACES_PREFIX:-}
    NS_FILE=; NS_SHA256=
    NS_DRY=
    NS_SOURCE=

    # The flag list is ours alone, so an unrecognised argument is an error, not
    # a silent passthrough.
    while [ "$#" -gt 0 ]; do
        case "$1" in
            v[0-9]*)           NS_VERSION=${1#v} ;;
            [0-9]*.[0-9]*)     NS_VERSION=$1 ;;
            --tag=*)           NS_VERSION=${1#--tag=}; NS_VERSION=${NS_VERSION#v} ;;
            --prefix=*)        NS_PREFIX=${1#--prefix=} ;;
            --file=*)          NS_FILE=${1#--file=} ;;
            --sha256=*)        NS_SHA256=${1#--sha256=} ;;
            -n|--dry-run)      NS_DRY=1 ;;
            -h|--help)         ns_usage; exit 0 ;;
            *)                 ns_die "unknown option '$1' — try --help" ;;
        esac
        shift
    done
    case "$NS_VERSION" in
        latest) ;;
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) ns_die "not a version: '$NS_VERSION' (want X.Y.Z, vX.Y.Z or latest)" ;;
    esac
    [ -n "$NS_FILE" ] || [ -z "$NS_SHA256" ] || \
        ns_die '--sha256= is only meaningful with --file='

    [ -n "$NS_PREFIX" ] || NS_PREFIX="$HOME/.local"
    # Absolute, and no trailing slash: the paths we print and compare spell it
    # the same way every time.
    case "$NS_PREFIX" in /*) ;; *) NS_PREFIX="$PWD/$NS_PREFIX" ;; esac
    while :; do case "$NS_PREFIX" in */) NS_PREFIX=${NS_PREFIX%/} ;; *) break ;; esac; done
    NS_CFG="$HOME/.config/niri-spaces"

    ns_preflight

    NS_TMP=$(mktemp -d "${TMPDIR:-/tmp}/niri-spaces.XXXXXX") || ns_die 'mktemp failed'
    # Clean up, then RE-RAISE. A trap that only cleans up swallows the signal:
    # Ctrl-C after the download would fall through to a completed install with
    # exit 0.
    trap 'ns_cleanup' EXIT
    trap 'ns_cleanup; trap - INT EXIT;  kill -INT  $$' INT
    trap 'ns_cleanup; trap - TERM EXIT; kill -TERM $$' TERM
    trap 'ns_cleanup; trap - HUP EXIT;  kill -HUP  $$' HUP

    NS_WANT=
    NS_TARBALL=
    if [ -n "$NS_FILE" ]; then
        ns_resolve_local
        NS_SOURCE="local artifact $NS_FILE"    # $NS_FILE now absolute
    else
        NS_SOURCE="https://github.com/${NIRI_SPACES_REPO:-$NS_REPO_DEFAULT}/releases"
        ns_resolve_github
        NS_TARBALL="$NS_TMP/$NS_ARCHIVE"
        ns_say "downloading $NS_URL"
        ns_fetch "$NS_URL" "$NS_TARBALL" || \
            ns_die "cannot download $NS_URL — is '$NS_VERSION' a published release of ${NIRI_SPACES_REPO:-$NS_REPO_DEFAULT}?"
        ns_say "downloading $NS_SUMS_URL"
        ns_fetch "$NS_SUMS_URL" "$NS_TMP/$NS_ARCHIVE.sha256" || \
            ns_die "cannot download $NS_SUMS_URL — is '$NS_VERSION' a published release of ${NIRI_SPACES_REPO:-$NS_REPO_DEFAULT}?"
        NS_WANT=$(ns_want_from_file "$NS_TMP/$NS_ARCHIVE.sha256") || \
            ns_die "$NS_ARCHIVE.sha256 does not contain a sha256"
    fi

    # Verified before anything is unpacked: a tampered archive never gets the
    # chance to produce a binary at all.
    ns_verify "$NS_TARBALL" "$NS_WANT"
    ns_extract

    if [ -n "$NS_DRY" ]; then
        ns_plan
        exit 0
    fi

    ns_install_bin "$NS_ROOT/niri-spaces" "$NS_PREFIX/bin/niri-spaces"
    ns_install_bin "$NS_ROOT/space-splash" "$NS_PREFIX/bin/space-splash"
    ns_say "installed $NS_PREFIX/bin/niri-spaces and $NS_PREFIX/bin/space-splash"
    # Optional for compatibility with releases before terminal pairing shipped.
    if [ -f "$NS_ROOT/niri-terminal-pairs" ]; then
        ns_install_bin "$NS_ROOT/niri-terminal-pairs" "$NS_PREFIX/bin/niri-terminal-pairs"
        ns_keep_or_copy "$NS_ROOT/settings.json" "$NS_CFG/settings.json"
    fi
    # Same for releases before per-workspace color schemes shipped.
    if [ -f "$NS_ROOT/niri-workspace-colors" ]; then
        ns_install_bin "$NS_ROOT/niri-workspace-colors" "$NS_PREFIX/bin/niri-workspace-colors"
    fi
    # Same for releases before the draggable workspace strip shipped.
    if [ -f "$NS_ROOT/niri-workspace-strip" ]; then
        ns_install_bin "$NS_ROOT/niri-workspace-strip" "$NS_PREFIX/bin/niri-workspace-strip"
    fi

    mkdir -p "$NS_CFG/spaces" "$NS_CFG/templates" || ns_die "cannot create $NS_CFG"
    ns_keep_or_copy "$NS_ROOT/autostart" "$NS_CFG/autostart"
    for f in "$NS_ROOT"/spaces/*.space; do
        if [ -f "$f" ]; then ns_keep_or_copy "$f" "$NS_CFG/spaces/${f##*/}"; fi
    done

    ns_suggest_keybind

    case ":${PATH:-}:" in
        *":$NS_PREFIX/bin:"*) ;;
        *) ns_warn "$NS_PREFIX/bin is not on your PATH. To run niri-spaces by name, add:
      export PATH=\"$NS_PREFIX/bin:\$PATH\"" ;;
    esac
    exit 0
}

main "$@"
