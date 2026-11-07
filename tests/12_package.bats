#!/usr/bin/env bats
#
# The packer and the installer have to agree, and 10_install.bats feeds the
# installer a fixture assembled by hand. That proves the installer accepts a
# correct archive; it cannot prove scripts/package.sh produces one. This file
# closes that gap: it runs the real packer on the real tree and installs the
# result, so a packaging change that drops or renames a member fails here rather
# than on the first user who runs curl | sh.

load helpers/setup

setup() {
    ns_setup
    BIN="$HOME/.local/bin"
    CFG="$HOME/.config/niri-spaces"
}

@test "package: the real artifact installs, and carries every member the installer requires" {
    dist="$BATS_TEST_TMPDIR/dist"
    run bash "$NS_REPO_ROOT/scripts/package.sh" v0.0.0 --out "$dist"
    [ "$status" -eq 0 ]

    tarball="$dist/niri-spaces-0.0.0.tar.gz"
    [ -f "$tarball" ]
    [ -f "$tarball.sha256" ]

    # The contract docs/install.sh checks member-by-member. Asserted here too, so
    # a failure names the missing member instead of just "install failed". The list
    # is captured once: `tar | grep -q` is a race (grep -q closes the pipe, tar dies
    # with "stdout: write error"), which the pages workflow already learned the hard
    # way under `set -o pipefail`.
    members=$(tar -tzf "$tarball")
    for m in niri-spaces space-splash niri-terminal-pairs niri-workspace-colors settings.json autostart LICENSE README.md install.sh; do
        case $'\n'"$members"$'\n' in
            *$'\n'"niri-spaces-0.0.0/$m"$'\n'*) ;;
            *) echo "the artifact has no niri-spaces-0.0.0/$m" >&2; return 1 ;;
        esac
    done
    case $'\n'"$members"$'\n' in
        *$'\n'"niri-spaces-0.0.0/spaces/"*".space"$'\n'*) ;;
        *) echo "the artifact carries no .space file under spaces/" >&2; return 1 ;;
    esac

    # Checksum file is the format the installer parses: "<hex>  <basename>" + LF,
    # with no directory prefix, because it is verified from the download dir.
    grep -Eqx '[0-9a-f]{64}  niri-spaces-0\.0\.0\.tar\.gz' "$tarball.sha256"

    # Install it for real, into the temp HOME the harness set up.
    sha=$(awk '{print $1}' "$tarball.sha256")
    run sh "$NS_INSTALL" --file="$tarball" --sha256="$sha"
    [ "$status" -eq 0 ]
    [[ "$output" == *"verified"* ]]
    [ -x "$BIN/niri-spaces" ]
    [ -x "$BIN/space-splash" ]
    [ -x "$BIN/niri-terminal-pairs" ]
    [ -x "$BIN/niri-workspace-colors" ]
    [ -f "$CFG/settings.json" ]
    run "$BIN/niri-spaces" terminal-pairs --check
    [ "$status" -eq 0 ]
    [[ "$output" == *disabled* ]]
    # The color-scheme watcher ships disabled too: its --check must say so
    # without touching niri or the managed include file.
    run "$BIN/niri-spaces" workspace-colors --check
    [ "$status" -eq 0 ]
    [[ "$output" == *disabled* ]]
    [ -f "$CFG/autostart" ]
    [ -f "$CFG/spaces/main.space" ]

    # The install.sh inside the archive is the same script the site serves, so a
    # user who extracts and runs it gets the code they were shown.
    tmp="$BATS_TEST_TMPDIR/extract"
    mkdir -p "$tmp"
    tar -xzf "$tarball" -C "$tmp"
    cmp "$tmp/niri-spaces-0.0.0/install.sh" "$NS_INSTALL"
}

@test "package: the artifact is byte-reproducible" {
    a="$BATS_TEST_TMPDIR/a"
    b="$BATS_TEST_TMPDIR/b"
    run bash "$NS_REPO_ROOT/scripts/package.sh" v0.0.0 --out "$a"
    [ "$status" -eq 0 ]
    run bash "$NS_REPO_ROOT/scripts/package.sh" v0.0.0 --out "$b"
    [ "$status" -eq 0 ]
    # release.yml rebuilds and compares to prove published bytes can be re-derived;
    # that only means something if two runs really are identical.
    cmp "$a/niri-spaces-0.0.0.tar.gz" "$b/niri-spaces-0.0.0.tar.gz"
}

@test "package: a malformed tag is refused rather than mis-named" {
    # The installer derives the URL by stripping a leading `v`, so a tag it cannot
    # parse must be refused at build time, not shipped under a wrong name.
    for bad in 0.1.0 v0.1 v0.1.0-rc1 v0.1.0.0 nope; do
        run bash "$NS_REPO_ROOT/scripts/package.sh" "$bad" --out "$BATS_TEST_TMPDIR/out"
        [ "$status" -ne 0 ]
        [[ "$output" == *"not vX.Y.Z"* ]]
    done
}
