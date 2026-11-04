#!/usr/bin/env bash
# Shared bats setup for the niri-spaces suite. A test file does:
#
#     load helpers/setup
#
# and its own `setup()` calls `ns_setup`. Everything lives under BATS_TEST_TMPDIR:
# a throwaway HOME, the fake niri's state/actions/counter files, a private config
# dir (via $NIRI_SPACES_DIR), and a per-test stub bin we populate with just the
# apps each test wants on PATH. Nothing here touches the real machine or network;
# the only non-stubbed dependency is the real jq the CLI hard-requires.

# Absolute repo paths, computed from the test file's own directory.
NS_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
NS_CLI="$NS_REPO_ROOT/niri-spaces"
NS_SPLASH="$NS_REPO_ROOT/space-splash"
# Consumed by the .bats files that source this harness rather than by the harness
# itself; shellcheck reads this file alone and would call it dead. Same for the
# NS_TEST_* globals ns_build_release sets. Silence the false positive at source.
# shellcheck disable=SC2034
NS_INSTALL="$NS_REPO_ROOT/install.sh"
NS_HELPERS="${BATS_TEST_DIRNAME}/helpers"
NS_STUBS="$NS_HELPERS/stubs"

# Bring up one isolated world for a test. Every test gets its own, so tests are
# independent and order-safe.
ns_setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    # The fake niri's whole world: a window list, an actions log, an argv dir,
    # and a counter that hands out fresh window ids.
    export NIRI_FAKE_STATE="$BATS_TEST_TMPDIR/state.json"
    export NIRI_FAKE_ACTIONS="$BATS_TEST_TMPDIR/actions.log"
    export NIRI_FAKE_ARGV_DIR="$BATS_TEST_TMPDIR/argv"
    export NIRI_FAKE_COUNTER="$BATS_TEST_TMPDIR/counter"
    printf '[]\n' >"$NIRI_FAKE_STATE"
    : >"$NIRI_FAKE_ACTIONS"
    echo 0 >"$NIRI_FAKE_COUNTER"
    mkdir -p "$NIRI_FAKE_ARGV_DIR"

    # Where an @action can echo a captured var for a test to read back.
    export NS_CAPTURE="$BATS_TEST_TMPDIR/capture"
    : >"$NS_CAPTURE"

    # Redirect the CLI's config dir here (niri-spaces honours $NIRI_SPACES_DIR).
    export NIRI_SPACES_DIR="$HOME/.config/niri-spaces"
    mkdir -p "$NIRI_SPACES_DIR/spaces" "$NIRI_SPACES_DIR/templates"

    # Per-test dir we drop fake-app copies into; prepended to PATH so only the
    # apps a test explicitly installs are "found" by the autodetection.
    export NS_STUBBIN="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$NS_STUBBIN"

    # Stub apps bin first, then the stub niri dir, then the real PATH (real jq,
    # coreutils, sed, comm, mktemp). The CLI hard-requires the real jq.
    export PATH="$NS_STUBBIN:$NS_STUBS:$PATH"
}

# Install the shared winapp template under the given names, so `command -v` and
# the candidate-order logic see exactly those apps as installed.
install_stub_apps() {
    local name
    for name in "$@"; do
        cp "$NS_STUBS/winapp" "$NS_STUBBIN/$name"
        chmod +x "$NS_STUBBIN/$name"
    done
}

# The argv a fake app recorded when spawned (empty file if it never ran).
argv_of() {
    local f="$NIRI_FAKE_ARGV_DIR/$1.argv"
    [ -f "$f" ] && cat "$f"
}

# True if the fake app ran at least once (its argv log exists).
app_ran() {
    [ -f "$NIRI_FAKE_ARGV_DIR/$1.argv" ]
}

# True if the fake niri logged a line containing the given fixed string.
actions_has() {
    [ -s "$NIRI_FAKE_ACTIONS" ] && grep -F -- "$1" "$NIRI_FAKE_ACTIONS" >/dev/null
}

# The nth action logged (1-based), stripped of the leading "niri msg ".
nth_action() {
    sed -n "${1}p" "$NIRI_FAKE_ACTIONS" | sed 's/^niri msg //'
}

# Write a .space file into the config dir's spaces/ subdir (content on stdin).
write_space() {
    cat >"$NIRI_SPACES_DIR/spaces/$1.space"
}

# Write a template into templates/ (content on stdin).
write_template() {
    cat >"$NIRI_SPACES_DIR/templates/$1.space"
}

# Build a minimal PATH dir of symlinks to the named real commands plus the shell,
# so `#!/usr/bin/env bash` still resolves. Used to reproduce a machine missing jq
# or niri while keeping every other dependency present. Echoes the dir.
build_min_path() {
    local d="$BATS_TEST_TMPDIR/minbin" name src
    rm -rf "$d"
    mkdir -p "$d"
    for name in "$@"; do
        src=$(command -v "$name") || { printf 'build_min_path: %s not on PATH\n' "$name" >&2; return 1; }
        ln -s "$src" "$d/$name"
    done
    printf '%s' "$d"
}

# Drop the fake niri into a minimal-PATH dir, so "niri is present but is fake"
# without pulling the whole stub-app world back onto PATH.
add_niri_to() {
    cp "$NS_STUBS/niri" "$1/niri"
    chmod +x "$1/niri"
}

# Stage a throwaway release artifact to install.sh's exact tarball contract (a
# single root dir niri-spaces-X.Y.Z/ holding the CLI, splash, autostart, spaces/,
# LICENSE and README.md) and gzip it. Records the path and its sha256 so a test
# can drive the installer's --file/--sha256 seam with a verifiable artifact. The
# bins are the real repo files, so a green install proves the shipped CLI runs.
ns_build_release() {
    local ver="${1:-0.1.0}"
    local stage="$BATS_TEST_TMPDIR/release" root
    root="$stage/niri-spaces-$ver"
    rm -rf "$stage"
    mkdir -p "$root/spaces"
    cp "$NS_CLI"    "$root/niri-spaces"
    cp "$NS_SPLASH" "$root/space-splash"
    printf 'load default\n'            >"$root/autostart"
    printf '@workspace 1\nfoot | foot\n' >"$root/spaces/main.space"
    printf 'MIT\n'                      >"$root/LICENSE"
    printf '# niri-spaces\n'            >"$root/README.md"
    NS_TEST_TARBALL="$BATS_TEST_TMPDIR/niri-spaces-$ver.tar.gz"
    tar -czf "$NS_TEST_TARBALL" -C "$stage" "niri-spaces-$ver"
    # shellcheck disable=SC2034  # read back by the install specs, not used here
    NS_TEST_SHA="$(sha256sum "$NS_TEST_TARBALL" | cut -d' ' -f1)"
}
