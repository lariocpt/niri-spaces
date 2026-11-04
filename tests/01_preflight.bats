#!/usr/bin/env bats
# (a) preflight: the CLI refuses up front when niri or jq is absent, and names
# which. It checks jq first, then niri (niri-spaces), so the missing-tool message
# is the first loop hit.
#
# These drive a verb that talks to the compositor, never --help: --help is answered
# BEFORE this loop on purpose, so a machine with nothing installed can still read
# what to install. Answering --help through the preflight used to be the design, and
# it is what made the page gate read an empty help and blame the page for it.

load helpers/setup

setup() { ns_setup; }

@test "preflight: missing niri refuses and names niri" {
    # jq present (so jq's check passes first), niri absent.
    run env PATH="$(build_min_path sh bash jq)" "$NS_CLI" list
    [ "$status" -eq 1 ]
    [[ "$output" == *"niri is required but not on PATH"* ]]
}

@test "preflight: missing jq refuses and names jq" {
    # Neither present; jq is first in the loop, so jq is named.
    run env PATH="$(build_min_path sh bash)" "$NS_CLI" list
    [ "$status" -eq 1 ]
    [[ "$output" == *"jq is required but not on PATH"* ]]
}

@test "preflight: every verb that needs the compositor is refused without niri" {
    local d; d="$(build_min_path sh bash jq)"
    local verb
    for verb in load start list menu; do
        run env PATH="$d" "$NS_CLI" "$verb" default
        [ "$status" -eq 1 ]
        [[ "$output" == *"niri is required but not on PATH"* ]] || return 1
    done
}

@test "preflight: a verb gets through once both tools are present" {
    local d; d="$(build_min_path sh bash jq awk grep sed)"
    add_niri_to "$d"
    run env PATH="$d" "$NS_CLI" list
    [ "$status" -eq 0 ]
}
