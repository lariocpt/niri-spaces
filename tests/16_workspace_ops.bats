#!/usr/bin/env bats
# (p) workspace operations (0.4.0). Three behaviours share the fake niri's
# workspace list ($NIRI_FAKE_WORKSPACES, served by `msg --json workspaces`):
#
#   * @workspace <name> resolution in run_space_file (niri-spaces): an absent
#     name is CREATED by parking the first window one slot past the end and
#     naming it; an empty bearer is REUSED; a busy bearer gets a fresh
#     "<name> N" sibling — never a merge into someone's workspace.
#   * cmd_menu's fuzzel branch: rows are numbered so the number alone opens a
#     workspace, and the picked line's prefix is stripped before loading.
#   * the niri-workspace-strip one-shot commands (status, reorder) against
#     the fake IPC, plus cmd_start's spawn wiring.

load helpers/setup
setup() { ns_setup; }

# ---------------------------------------------------------------- creation

@test "create: a fresh name spawns, parks the window past the end, then names the slot" {
    install_stub_apps foot
    write_space proj <<'EOF'
@workspace my project
foot | foot
EOF
    run "$NS_CLI" load proj
    [ "$status" -eq 0 ]
    # One move to index 1 (0 live + 1), then the naming of exactly that slot.
    [ "$(nth_action 1)" = "action move-window-to-workspace --window-id win-1 1" ]
    [ "$(nth_action 2)" = "action set-workspace-name my project --workspace 1" ]
    # The fake world now really bears the name — the create round trip closed.
    run jq -r '.[0].name' "$NIRI_FAKE_WORKSPACES"
    [ "$output" = "my project" ]
}

@test "reuse: an empty bearer takes the windows by name, with no slot created" {
    install_stub_apps foot
    write_workspaces <<'EOF'
[{"id":2,"idx":1,"name":null,"output":"eDP-1","is_urgent":false,"is_active":false,"is_focused":false,"active_window_id":null},
 {"id":9,"idx":2,"name":"proj","output":"eDP-1","is_urgent":false,"is_active":false,"is_focused":false,"active_window_id":null}]
EOF
    write_space proj <<'EOF'
@workspace proj
foot | foot
EOF
    run "$NS_CLI" load proj
    [ "$status" -eq 0 ]
    [ "$(nth_action 1)" = "action move-window-to-workspace --window-id win-1 proj" ]
    # No renaming and no past-the-end move: the name already had a home.
    ! actions_has 'set-workspace-name'
    ! actions_has '--window-id win-1 3'
    run jq 'length' "$NIRI_FAKE_WORKSPACES"
    [ "$output" = "2" ]
}

@test "busy: a name holding windows opens the next free '<name> N' sibling" {
    install_stub_apps foot
    write_workspaces <<'EOF'
[{"id":9,"idx":1,"name":"proj","output":"eDP-1","is_urgent":false,"is_active":true,"is_focused":false,"active_window_id":77},
 {"id":10,"idx":2,"name":"proj 2","output":"eDP-1","is_urgent":false,"is_active":false,"is_focused":false,"active_window_id":88}]
EOF
    write_space proj <<'EOF'
@workspace proj
foot | foot
EOF
    run "$NS_CLI" load proj
    [ "$status" -eq 0 ]
    # proj AND proj 2 both hold windows, so the sibling is proj 3: parked one
    # past the end (2 live + 1), then named.
    [ "$(nth_action 1)" = "action move-window-to-workspace --window-id win-1 3" ]
    [ "$(nth_action 2)" = "action set-workspace-name proj 3 --workspace 3" ]
}

@test "busy: a second section re-mentioning the created name opens its sibling" {
    install_stub_apps foot brave
    write_space two <<'EOF'
@workspace proj
foot | foot
@workspace proj
brave | brave
EOF
    run "$NS_CLI" load two
    [ "$status" -eq 0 ]
    # The first section creates the slot and names it; by the second section
    # the fake world shows that slot holding foot's window — busy — so the
    # documented shape is a fresh "proj 2", not a merge.
    [ "$(nth_action 1)" = "action move-window-to-workspace --window-id win-1 1" ]
    [ "$(nth_action 2)" = "action set-workspace-name proj --workspace 1" ]
    [ "$(nth_action 3)" = "action move-window-to-workspace --window-id win-2 2" ]
    [ "$(nth_action 4)" = "action set-workspace-name proj 2 --workspace 2" ]
}

# -------------------------------------------------------------------- menu

@test "menu: fuzzel rows are numbered so the number alone is a complete pick" {
    install_stub_apps foot brave
    write_space alpha <<'EOF'
@workspace 1
foot | foot
EOF
    write_space beta <<'EOF'
@workspace 2
brave | brave
EOF
    export NS_MENU_INPUT="$BATS_TEST_TMPDIR/menu-input"
    run env WAYLAND_DISPLAY=wayland-1 bash -c '"$0" menu </dev/null' "$NS_CLI"
    [ "$status" -eq 0 ]
    # The rows the picker saw: index, two spaces, name — alphabetical, so a
    # preset's number is stable between opens.
    [ "$(sed -n 1p "$NS_MENU_INPUT")" = " 1  alpha" ]
    [ "$(sed -n 2p "$NS_MENU_INPUT")" = " 2  beta" ]
    # The default pick (first row) loaded alpha, prefix stripped.
    app_ran foot
    refute_app_ran brave
}

@test "menu: a typed number is stripped from the picked line before loading" {
    install_stub_apps foot brave
    write_space alpha <<'EOF'
@workspace 1
foot | foot
EOF
    write_space beta <<'EOF'
@workspace 2
brave | brave
EOF
    export NS_MENU_PICK=" 2  beta"
    run env WAYLAND_DISPLAY=wayland-1 bash -c '"$0" menu </dev/null' "$NS_CLI"
    [ "$status" -eq 0 ]
    app_ran brave
    refute_app_ran foot
}

@test "menu: a cancelled fuzzel selection loads nothing and exits clean" {
    install_stub_apps foot
    write_space alpha <<'EOF'
@workspace 1
foot | foot
EOF
    export NS_MENU_CANCEL=1
    run env WAYLAND_DISPLAY=wayland-1 bash -c '"$0" menu </dev/null' "$NS_CLI"
    [ "$status" -eq 0 ]
    refute_app_ran foot
}

# ------------------------------------------------------------- strip CLI

@test "strip: --check reports the toggle and the GTK binding without niri" {
    run "$NS_CLI" workspace-strip --check
    [ "$status" -eq 0 ]
    [[ "$output" == *disabled* ]]
    [[ "$output" == *"gtk layer-shell"* ]]
}

@test "strip: status lists the live workspaces in displayed order" {
    write_workspaces <<'EOF'
[{"id":6,"idx":2,"name":"purple","output":"eDP-1","is_urgent":false,"is_active":true,"is_focused":true,"active_window_id":12},
 {"id":1,"idx":1,"name":null,"output":"eDP-1","is_urgent":false,"is_active":false,"is_focused":false,"active_window_id":null}]
EOF
    run "$NS_CLI" workspace-strip status
    [ "$status" -eq 0 ]
    # Creation order (6 before 1) must not leak: chips read 1..n.
    [ "$(echo "$output" | sed -n 2p)" = "  [1] (unnamed)        no scheme" ]
    [[ "$output" == *"  [2] purple           purple"* ]]
}

@test "strip: reorder moves the workspace at FROM onto TO by reference" {
    write_workspaces <<'EOF'
[{"id":1,"idx":1,"name":null,"output":"eDP-1","is_urgent":false,"is_active":false,"is_focused":false,"active_window_id":null},
 {"id":5,"idx":2,"name":"yellow","output":"eDP-1","is_urgent":false,"is_active":false,"is_focused":false,"active_window_id":null},
 {"id":6,"idx":3,"name":"purple","output":"eDP-1","is_urgent":false,"is_active":false,"is_focused":false,"active_window_id":null}]
EOF
    run "$NS_CLI" workspace-strip reorder 2 3
    [ "$status" -eq 0 ]
    [ "$(nth_action 1)" = "action move-workspace-to-index 3 --reference 2" ]
}

@test "strip: reorder refuses positions with no workspace" {
    write_workspaces <<'EOF'
[{"id":1,"idx":1,"name":null,"output":"eDP-1","is_urgent":false,"is_active":false,"is_focused":false,"active_window_id":null}]
EOF
    run "$NS_CLI" workspace-strip reorder 4 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"no workspace at index 4"* ]]
    ! actions_has 'move-workspace-to-index'
}

@test "start: the strip helper is spawned next to the other daemons" {
    install_stub_apps foot
    printf 'load alpha\n' >"$NIRI_SPACES_DIR/autostart"
    write_space alpha <<'EOF'
@workspace 1
foot | foot
EOF
    run "$NS_CLI" start
    [ "$status" -eq 0 ]
    actions_has 'action spawn -- '
    actions_has 'niri-workspace-strip'
    actions_has 'niri-workspace-colors'
}
