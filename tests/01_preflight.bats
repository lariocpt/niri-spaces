#!/usr/bin/env bats
# (a) preflight: the CLI refuses up front when niri or jq is absent, and names
# which. It checks jq first, then niri (niri-spaces:25), so the missing-tool
# message is the first loop hit. These run through `--help`, whose dispatcher
# branch is the first thing reached AFTER the preflight loop — so a refusal here
# proves the preflight, not the subcommand.

load helpers/setup

setup() { ns_setup; }

@test "preflight: missing niri refuses and names niri" {
    # jq present (so jq's check passes first), niri absent.
    run env PATH="$(build_min_path sh bash jq)" "$NS_CLI" --help
    [ "$status" -eq 1 ]
    [[ "$output" == *"niri is required but not on PATH"* ]]
}

@test "preflight: missing jq refuses and names jq" {
    # Neither present; jq is first in the loop, so jq is named.
    run env PATH="$(build_min_path sh bash)" "$NS_CLI" --help
    [ "$status" -eq 1 ]
    [[ "$output" == *"jq is required but not on PATH"* ]]
}

@test "preflight: both niri and jq present passes" {
    # awk is needed only because --help extracts the header comment block off the
    # script; the refusal tests never get that far (they exit inside the loop).
    local d; d="$(build_min_path sh bash jq awk)"
    add_niri_to "$d"
    run env PATH="$d" "$NS_CLI" --help
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "niri-spaces — declarative workspace layout manager for niri." ]
}
