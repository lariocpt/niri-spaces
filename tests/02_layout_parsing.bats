#!/usr/bin/env bats
# (b) layout parsing. The fields are split on `|` (niri-spaces:142), the command
# field is eval'd, the app_id field is expanded only when it holds a `$`. These
# assert what the parser actually does with each shape — including the two places
# where the code is silent rather than fatal.

load helpers/setup
setup() { ns_setup; }

@test "layout: @workspace by name is echoed and used as the move target" {
    install_stub_apps foot
    write_space ws <<'EOF'
@workspace myspace
foot | foot
EOF
    run "$NS_CLI" load ws
    [ "$status" -eq 0 ]
    [[ "$output" == *"-> workspace: myspace"* ]]
    actions_has "action move-window-to-workspace --window-id win-1 myspace"
}

@test "layout: @workspace by index is used verbatim as the move target" {
    install_stub_apps foot
    write_space ws <<'EOF'
@workspace 2
foot | foot
EOF
    run "$NS_CLI" load ws
    [ "$status" -eq 0 ]
    actions_has "action move-window-to-workspace --window-id win-1 2"
}

@test "layout: 2-field app line (app_id + command) launches" {
    install_stub_apps foot
    write_space ws <<'EOF'
@workspace 1
foot | foot --title=t
EOF
    run "$NS_CLI" load ws
    [ "$status" -eq 0 ]
    [ "$(argv_of foot)" = "foot --title=t" ]
}

@test "layout: 3-field app line (adds an env-vars field) launches with the env accepted" {
    install_stub_apps foot
    write_space ws <<'EOF'
@workspace 1
foot | foot --title=e | FOO=bar
EOF
    run "$NS_CLI" load ws
    [ "$status" -eq 0 ]
    app_ran foot
}

@test "layout: 4-field app line (adds a capture var) stores the learned id" {
    install_stub_apps foot
    write_space ws <<'EOF'
@workspace 1
foot | foot | | myid
@action printf '%s\n' "$myid" >> "$NS_CAPTURE"
EOF
    run "$NS_CLI" load ws
    [ "$status" -eq 0 ]
    [ "$(cat "$NS_CAPTURE")" = "win-1" ]
}

@test "layout: comments and blank lines are ignored" {
    install_stub_apps foot
    write_space ws <<'EOF'
# a comment
@workspace 1

   # indented comment

foot | foot
EOF
    run "$NS_CLI" load ws
    [ "$status" -eq 0 ]
    # exactly one launch happened, and it is the foot line.
    [ "$(grep -c launching <<<"$output")" -eq 1 ]
    [[ "$output" == *"launching foot: foot"* ]]
}

@test "layout: a launch command with a pipe is split at the pipe (README's prohibition)" {
    install_stub_apps foot
    # Intended command contained a `|`. The field splitter cuts there: only the
    # part before the first `|` launches, and the remainder lands in the env field
    # (which then fails its `export`, printed to stderr). This is the real, silent
    # consequence the README warns about — not a hard error.
    write_space ws <<'EOF'
@workspace 5
foot | foot --a | --b | cap
EOF
    run "$NS_CLI" load ws
    [ "$status" -eq 0 ]
    [ "$(argv_of foot)" = "foot --a" ]            # truncated at the pipe, not "foot --a --b"
    [[ "$output" == *"invalid option"* ]]         # the misparsed "--b" env field
}

@test "layout: an unknown @directive warns on stderr and continues" {
    install_stub_apps foot
    # @workspace and @action are the only recognised directives. Any other line
    # that starts with @ now emits a warning naming the directive and its
    # file:line, then is ignored so the rest of the file still runs.
    write_space ws <<'EOF'
@workspace 1
@frobnicate nonsense
foot | foot
EOF
    run "$NS_CLI" load ws
    [ "$status" -eq 0 ]
    # warning names the directive and points at line 2
    [[ "$output" == *"warning: unknown directive '@frobnicate'"* ]]
    [[ "$output" == *":2 (ignored)"* ]]
    # and loading still proceeds past it
    app_ran foot
    [ "$(grep -c launching <<<"$output")" -eq 1 ]
}

@test "layout: app_id and command fields both shell-expand" {
    install_stub_apps foot
    # PROBEID drives the app_id field (expanded via the `$`-case at niri-spaces:147),
    # PROBE drives the command field (expanded by the launch eval). The fake app
    # reports NIRI_FAKE_WIN_APPID so the expanded app_id actually matches the
    # window — if expansion were broken the diff would find nothing.
    export PROBEID=customapp PROBE=hello NIRI_FAKE_WIN_APPID=customapp
    write_space ws <<'EOF'
@workspace 3
$PROBEID | foot --x=$PROBE | | cap
@action printf '%s\n' "$cap" >> "$NS_CAPTURE"
EOF
    run "$NS_CLI" load ws
    [ "$status" -eq 0 ]
    [ "$(argv_of foot)" = "foot --x=hello" ]      # command field expanded
    [[ "$output" == *"launching customapp"* ]]    # app_id field expanded and echoed
    [ "$(cat "$NS_CAPTURE")" = "win-1" ]          # app_id expanded, so the diff matched
}
