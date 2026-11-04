#!/usr/bin/env bats
# (f) start: run every `load` line in the autostart file, then land on workspace
# 1. cmd_start (niri-spaces:206) reads the file line by line, calls cmd_load for
# `load <name>` lines, warns on anything else it is not told to run, and closes
# with `niri msg action focus-workspace 1`.

load helpers/setup
setup() { ns_setup; }

@test "start: loads autostart spaces in order, then focuses workspace 1" {
    install_stub_apps foot brave
    export TERMINAL=foot BROWSER=brave
    cp "$NS_REPO_ROOT/spaces/main.space" "$NS_REPO_ROOT/spaces/web.space" "$NIRI_SPACES_DIR/spaces/"
    cat >"$NIRI_SPACES_DIR/autostart" <<'EOF'
# comment lines and blanks are skipped
load main
load web
EOF
    run "$NS_CLI" start
    [ "$status" -eq 0 ]

    # main loads before web (its lines appear earlier in the transcript).
    local main_line web_line
    main_line=$(grep -n "Loading space 'main'" <<<"$output" | head -1 | cut -d: -f1)
    web_line=$(grep -n "Loading space 'web'" <<<"$output" | head -1 | cut -d: -f1)
    [ -n "$main_line" ] && [ -n "$web_line" ] && [ "$main_line" -lt "$web_line" ]

    # main's first window lands on workspace 1, web's first on workspace 2.
    actions_has "action move-window-to-workspace --window-id win-1 1"
    actions_has "action move-window-to-workspace --window-id win-3 2"

    # The run closes by focusing workspace 1 — the very last action emitted.
    [ "$(tail -n1 "$NIRI_FAKE_ACTIONS")" = "niri msg action focus-workspace 1" ]
}

@test "start: no autostart file is not an error" {
    run "$NS_CLI" start
    [ "$status" -eq 0 ]
    [[ "$output" == *"No autostart file at"*"nothing to do"* ]]
}

@test "start: an unrecognized autostart line warns and is skipped, load still closes on workspace 1" {
    install_stub_apps foot
    export TERMINAL=foot
    write_space one <<'EOF'
@workspace 1
foot | foot
EOF
    cat >"$NIRI_SPACES_DIR/autostart" <<'EOF'
load one
bogus thing here
EOF
    run "$NS_CLI" start
    [ "$status" -eq 0 ]
    [[ "$output" == *"warning: unrecognized autostart line: bogus thing here"* ]]
    app_ran foot
    [ "$(tail -n1 "$NIRI_FAKE_ACTIONS")" = "niri msg action focus-workspace 1" ]
}
