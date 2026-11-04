#!/usr/bin/env bats
# --help is generated from the header comment block at the top of niri-spaces
# (extracted with awk, stopping at the first non-# line) and answered before the
# dependency preflight, so it works on a machine where nothing is installed yet.
# These tests pin the two things that used to break: the extraction must not run past
# the comment block into the executable lines (the old `sed -n '2,15p'` leaked
# `set -uo pipefail`), and it must advertise ONLY the subcommands the dispatcher
# actually implements (load/start/menu/list) — never the workspace verbs the
# public release trimmed out.

load helpers/setup

setup() { ns_setup; }

# Run the CLI's --help with a working (stub) niri and the real jq on PATH.
run_help() {
    local d; d="$(build_min_path sh bash jq awk)"
    add_niri_to "$d"
    run env PATH="$d" "$NS_CLI" --help
}

@test "help: first line is the tool summary" {
    run_help
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "niri-spaces — declarative workspace layout manager for niri." ]
}

@test "help: lists the subcommands the CLI actually implements" {
    run_help
    [[ "$output" == *"niri-spaces load "* ]]
    [[ "$output" == *"niri-spaces start"* ]]
    [[ "$output" == *"niri-spaces menu"* ]]
    [[ "$output" == *"niri-spaces list"* ]]
}

@test "help: documents the .space file format" {
    run_help
    [[ "$output" == *"@workspace"* ]]
    [[ "$output" == *"@action"* ]]
}

@test "help: does not leak executable source lines" {
    run_help
    [[ "$output" != *"pipefail"* ]]
    [[ "$output" != *"set -uo"* ]]
    [[ "$output" != *"while IFS"* ]]
}

@test "help: does not advertise subcommands that were removed" {
    run_help
    for verb in switch new save current delete workspace-to add-workspace; do
        [[ "$output" != *"niri-spaces $verb"* ]]
    done
}

@test "help: unknown subcommand is rejected on stderr" {
    local d; d="$(build_min_path sh bash jq awk)"
    add_niri_to "$d"
    run env PATH="$d" "$NS_CLI" switch now
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown subcommand: switch"* ]]
}

# The defect that broke the release gate: --help sat behind the jq/niri preflight, so
# on any machine missing either tool it exited 1 with a dependency error and printed
# nothing. A page gate that compares itself to `--help` then reported every real verb
# as missing, and pointed at the page. Help is what you read to find out what to
# install, so it must not need the things it is telling you about.
@test "help: answered on a machine with neither niri nor jq installed" {
    run env PATH="$(build_min_path sh bash awk)" "$NS_CLI" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"niri-spaces load "* ]]
    [[ "$output" != *"required but not on PATH"* ]]
}

@test "help: bare invocation is help, not a dependency error" {
    run env PATH="$(build_min_path sh bash awk)" "$NS_CLI"
    [ "$status" -eq 0 ]
    [[ "$output" == *"declarative workspace layout manager"* ]]
    [[ "$output" != *"required but not on PATH"* ]]
}
