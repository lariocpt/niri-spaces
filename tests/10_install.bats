#!/usr/bin/env bats
# (j) install.sh, driven end to end through its --file=/--sha256= testing seam.
# The seam is the release path with the network removed: same verification, same
# layout checks, same refusal rules (install.sh:49). The installer honours $HOME
# for both the bin prefix ($HOME/.local) and config ($HOME/.config/niri-spaces),
# and ns_setup already points HOME and PATH at a throwaway world with a fake niri
# and the real jq/tar/coreutils, so a real install never touches the machine.

load helpers/setup

# Resolve the bin/config paths AFTER ns_setup has repointed HOME at the temp
# world — at file-load time $HOME is still the real one, and baking the paths
# in there would both mis-assert and point at the developer's own install.
setup() {
    ns_setup
    BIN="$HOME/.local/bin"
    CFG="$HOME/.config/niri-spaces"
}

@test "install: a good artifact verifies, installs executable bins and copies config, and suggests the keybind" {
    ns_build_release 0.1.0
    run sh "$NS_INSTALL" --file="$NS_TEST_TARBALL" --sha256="$NS_TEST_SHA"
    [ "$status" -eq 0 ]
    [[ "$output" == *"verified"* ]]
    [[ "$output" == *"installed $BIN/niri-spaces and $BIN/space-splash"* ]]
    # The suggestion is printed, and the installer insists it edited nothing.
    [[ "$output" == *"Mod+Ctrl+Shift+S"* ]]
    [[ "$output" == *"nothing was edited"* ]]
    # The bins really land and are executable.
    [ -x "$BIN/niri-spaces" ]
    [ -x "$BIN/space-splash" ]
    # Config: autostart and the layout copied, the templates dir created.
    [ -f "$CFG/autostart" ]
    [ -f "$CFG/spaces/main.space" ]
    [ -d "$CFG/templates" ]
}

@test "install: a tampered artifact is refused as a checksum mismatch and writes nothing" {
    ns_build_release 0.1.0
    # Corrupt the bytes AFTER the expected sha was recorded, so verification fails.
    printf 'tampered' >>"$NS_TEST_TARBALL"
    run sh "$NS_INSTALL" --file="$NS_TEST_TARBALL" --sha256="$NS_TEST_SHA"
    [ "$status" -eq 1 ]
    [[ "$output" == *"CHECKSUM MISMATCH"* ]]
    # Verify runs before anything is unpacked, so no executable and no config file.
    [ ! -e "$BIN/niri-spaces" ]
    [ ! -e "$CFG/autostart" ]
}

@test "install: a re-install replaces the bins but keeps a config the user edited" {
    ns_build_release 0.1.0
    run sh "$NS_INSTALL" --file="$NS_TEST_TARBALL" --sha256="$NS_TEST_SHA"
    [ "$status" -eq 0 ]
    # Replace the config with a user edit, then install again.
    printf 'MY EDITED AUTOSTART\n' >"$CFG/autostart"
    run sh "$NS_INSTALL" --file="$NS_TEST_TARBALL" --sha256="$NS_TEST_SHA"
    [ "$status" -eq 0 ]
    [[ "$output" == *"kept existing $CFG/autostart (not overwritten)"* ]]
    grep -qx 'MY EDITED AUTOSTART' "$CFG/autostart"
}

@test "install: --dry-run prints the plan and writes nothing outside the work dir" {
    ns_build_release 0.1.0
    run sh "$NS_INSTALL" --file="$NS_TEST_TARBALL" --sha256="$NS_TEST_SHA" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry run"* ]]
    [[ "$output" == *"$BIN/niri-spaces"* ]]
    [[ "$output" == *"would install $CFG/autostart"* ]]
    # Nothing outside the temporary work directory was created.
    [ ! -e "$BIN/niri-spaces" ]
    [ ! -e "$CFG/autostart" ]
}

@test "install: an artifact whose version is not the pinned one is refused" {
    ns_build_release 0.1.0
    # The tarball is 0.1.0 but we pin 9.9.9; extraction must refuse the mismatch.
    run sh "$NS_INSTALL" --file="$NS_TEST_TARBALL" --sha256="$NS_TEST_SHA" --tag=9.9.9
    [ "$status" -eq 1 ]
    [[ "$output" == *"artifact is niri-spaces-0.1.0, not the pinned 9.9.9"* ]]
    [ ! -e "$BIN/niri-spaces" ]
}

@test "install: an unrecognised option is an error, not a silent passthrough" {
    run sh "$NS_INSTALL" --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option '--bogus'"* ]]
}

@test "install: refuses when niri is not on PATH and names it" {
    ns_build_release 0.1.0
    local d; d="$(build_min_path sh)"   # sh only: no niri, no jq
    run env -i PATH="$d" HOME="$HOME" sh "$NS_INSTALL" --file="$NS_TEST_TARBALL" --sha256="$NS_TEST_SHA"
    [ "$status" -eq 1 ]
    [[ "$output" == *"niri is not on PATH"* ]]
}

@test "install: refuses when jq is not on PATH (niri present) and names it" {
    ns_build_release 0.1.0
    local d; d="$(build_min_path sh)"; add_niri_to "$d"   # sh + niri, but no jq
    run env -i PATH="$d" HOME="$HOME" sh "$NS_INSTALL" --file="$NS_TEST_TARBALL" --sha256="$NS_TEST_SHA"
    [ "$status" -eq 1 ]
    [[ "$output" == *"jq is not on PATH"* ]]
}
