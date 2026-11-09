#!/usr/bin/env bats
# (q) session snapshot & restore (0.5.0). The niri-session-snapshot helper
# driven against the fake niri: CLI dispatch, --check validation, status,
# restore (dry run, create-and-name replay, existing-workspace moves, group
# dedup, skips, geometry replay), the daemon's capture-on-exit path, and
# cmd_start's wiring (daemon spawn + the autostart `restore` line).

load helpers/setup
setup() { ns_setup; }
NS_SESSION="$NS_REPO_ROOT/niri-session-snapshot"

# Write a snapshot into the state dir the helper reads ($HOME/.local/state).
write_snapshot() {
    mkdir -p "$HOME/.local/state/niri-spaces"
    cat >"$HOME/.local/state/niri-spaces/session.json"
}

# One restorable window on one named workspace, in the stored schema.
simple_snapshot() {
    write_snapshot <<'EOF'
{"version": 1, "saved": 0, "focused": null, "workspaces": [
 {"idx": 1, "name": "proj", "output": null, "focused": false, "windows": [
   {"app_id": "foot", "title": "shell", "rule": "terminal", "command": ["foot"],
    "group": null, "column": null, "tile": null, "width": null,
    "floating": false, "skip_reason": null}]}]}
EOF
}

# ---------------------------------------------------------------- dispatch

@test "dispatch: niri-spaces session reaches the helper (--check)" {
    run "$NS_CLI" session --check
    [ "$status" -eq 0 ]
    [[ "$output" == "session: enabled=False debounce=2s"* ]]
    [[ "$output" == *"no snapshot yet"* ]]
}

@test "check: invalid settings are reported, not swallowed" {
    printf '{"session_snapshot": "yes"}\n' >"$NIRI_SPACES_DIR/settings.json"
    run "$NS_CLI" session --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"settings invalid"* ]]
}

# ---------------------------------------------------------------- status

@test "status: no snapshot yet is a clean answer" {
    run "$NS_CLI" session status
    [ "$status" -eq 0 ]
    [ "$output" = "session: no snapshot yet" ]
}

@test "status: counts restorable windows and names every skip" {
    write_snapshot <<'EOF'
{"version": 1, "saved": 0, "focused": null, "workspaces": [
 {"idx": 1, "name": "teal", "output": "eDP-1", "focused": true, "windows": [
   {"app_id": "foot", "title": null, "rule": "terminal", "command": ["foot"],
    "group": null, "column": 0, "tile": 0, "width": 0.5,
    "floating": false, "skip_reason": null},
   {"app_id": "org.videolan.VLC", "title": null, "rule": "skip", "command": null,
    "group": null, "column": null, "tile": null, "width": null,
    "floating": false, "skip_reason": "no restore rule for org.videolan.VLC"}]}]}
EOF
    run "$NS_CLI" session status
    [ "$status" -eq 0 ]
    [ "$(sed -n '2p' <<<"$output")" = "  [1] teal: 1 restorable, 1 skipped" ]
    [[ "$output" == *"skip: org.videolan.VLC — no restore rule"* ]]
}

# ---------------------------------------------------------------- restore

@test "restore: no snapshot is a quiet success (autostart-safe)" {
    run "$NS_CLI" session restore
    [ "$status" -eq 0 ]
    [ "$output" = "session restore: no snapshot yet (nothing to restore)" ]
}

@test "restore --dry-run: prints the plan and launches nothing" {
    install_stub_apps foot
    simple_snapshot
    run "$NS_CLI" session restore --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[proj] foot: foot"* ]]
    [[ "$output" == *"1 windows, 1 workspaces"* ]]
    refute_app_ran foot
    [ ! -s "$NIRI_FAKE_ACTIONS" ]
}

@test "restore: creates the named workspace and places the window on it" {
    install_stub_apps foot
    simple_snapshot
    run "$NS_CLI" session restore
    [ "$status" -eq 0 ]
    [[ "$output" == *"placed 1 of 1 windows"* ]]
    app_ran foot
    [ "$(nth_action 1)" = "action move-window-to-workspace --window-id win-1 1" ]
    [ "$(nth_action 2)" = "action set-workspace-name proj --workspace 1" ]
    run jq -r '.[0].name' "$NIRI_FAKE_WORKSPACES"
    [ "$output" = "proj" ]
}

@test "restore: an existing named workspace is entered by name, never recreated" {
    install_stub_apps foot
    write_workspaces <<'EOF'
[{"id":5,"idx":1,"name":"proj","output":"eDP-1","is_urgent":false,"is_active":false,"is_focused":false,"active_window_id":null}]
EOF
    simple_snapshot
    run "$NS_CLI" session restore
    [ "$status" -eq 0 ]
    [ "$(nth_action 1)" = "action move-window-to-workspace --window-id win-1 proj" ]
    refute_actions_has "set-workspace-name"
}

@test "restore: one launch per group — a browser instance opens its own tabs" {
    install_stub_apps foot
    write_snapshot <<'EOF'
{"version": 1, "saved": 0, "focused": null, "workspaces": [
 {"idx": 1, "name": "web", "output": null, "focused": false, "windows": [
   {"app_id": "foot", "title": "a", "rule": "browser", "command": ["foot"],
    "group": "browser:77", "column": null, "tile": null, "width": null,
    "floating": false, "skip_reason": null},
   {"app_id": "foot", "title": "b", "rule": "browser", "command": ["foot"],
    "group": "browser:77", "column": null, "tile": null, "width": null,
    "floating": false, "skip_reason": null},
   {"app_id": "foot", "title": "c", "rule": "browser", "command": ["foot"],
    "group": "browser:77", "column": null, "tile": null, "width": null,
    "floating": false, "skip_reason": null}]}]}
EOF
    run "$NS_CLI" session restore
    [ "$status" -eq 0 ]
    # One launch for the whole group; the extra windows never appeared, which
    # is reported, not guessed at.
    [ "$(argv_of foot | wc -l)" -eq 1 ]
    [[ "$output" == *"placed 1 of 3 windows"* ]]
    [[ "$output" == *"left to the app's own restore"* ]]
}

@test "restore: skipped windows are never launched" {
    install_stub_apps foot
    write_snapshot <<'EOF'
{"version": 1, "saved": 0, "focused": null, "workspaces": [
 {"idx": 1, "name": "misc", "output": null, "focused": false, "windows": [
   {"app_id": "foot", "title": null, "rule": "skip", "command": null,
    "group": null, "column": null, "tile": null, "width": null,
    "floating": false, "skip_reason": "no restore rule for foot"}]}]}
EOF
    run "$NS_CLI" session restore
    [ "$status" -eq 0 ]
    [ "$output" = "session restore: nothing restorable in the snapshot" ]
    refute_app_ran foot
}

@test "restore: replays column order, widths, floating and focus" {
    install_stub_apps foot
    write_snapshot <<'EOF'
{"version": 1, "saved": 0, "focused": 1, "workspaces": [
 {"idx": 1, "name": "proj", "output": "eDP-1", "focused": true, "windows": [
   {"app_id": "foot", "title": "left", "rule": "terminal", "command": ["foot"],
    "group": null, "column": 0, "tile": 0, "width": 0.4,
    "floating": false, "skip_reason": null},
   {"app_id": "foot", "title": "float", "rule": "terminal", "command": ["foot"],
    "group": null, "column": 1, "tile": 0, "width": 0.6,
    "floating": true, "skip_reason": null}]}]}
EOF
    run "$NS_CLI" session restore
    [ "$status" -eq 0 ]
    [[ "$output" == *"placed 2 of 2 windows"* ]]
    actions_has "action move-column-to-index 1"
    actions_has "action set-column-width 40%"
    actions_has "action toggle-window-floating"
    actions_has "action focus-workspace proj"
}

# ---------------------------------------------------------------- daemon

@test "daemon: disabled by default — starts and leaves no snapshot" {
    export NIRI_SOCKET=/fake XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$XDG_RUNTIME_DIR"
    run "$NS_SESSION"
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.local/state/niri-spaces/session.json" ]
}

@test "daemon: enabled — captures the live session when the stream ends" {
    printf '{"session_snapshot": true}\n' >"$NIRI_SPACES_DIR/settings.json"
    export NIRI_SOCKET=/fake XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$XDG_RUNTIME_DIR"
    write_workspaces <<'EOF'
[{"id":1,"idx":1,"name":"teal","output":"eDP-1","is_urgent":false,"is_active":true,"is_focused":true,"active_window_id":null}]
EOF
    # The fake event stream is empty and closes at once: the daemon reads the
    # EOF as "compositor gone" and takes its save-on-exit path.
    run "$NS_SESSION"
    [ "$status" -eq 0 ]
    [[ "$output" == *"snapshot saved on exit"* ]]
    local snap="$HOME/.local/state/niri-spaces/session.json"
    [ -f "$snap" ]
    [ "$(stat -c %a "$snap")" = "600" ]
    run jq -r '.workspaces[0].name' "$snap"
    [ "$output" = "teal" ]
}

# ---------------------------------------------------------------- start wiring

@test "start: the session daemon is spawned next to the other helpers" {
    install_stub_apps foot
    printf 'load alpha\n' >"$NIRI_SPACES_DIR/autostart"
    write_space alpha <<'EOF'
@workspace 1
foot | foot
EOF
    run "$NS_CLI" start
    [ "$status" -eq 0 ]
    actions_has 'niri-session-snapshot'
}

@test "start: an autostart restore line replays the session" {
    install_stub_apps foot
    printf 'restore\n' >"$NIRI_SPACES_DIR/autostart"
    simple_snapshot
    run "$NS_CLI" start
    [ "$status" -eq 0 ]
    [[ "$output" == *"placed 1 of 1 windows"* ]]
    app_ran foot
}

@test "start: a restore failure warns but does not abort autostart" {
    install_stub_apps foot
    printf 'restore\nload alpha\n' >"$NIRI_SPACES_DIR/autostart"
    write_space alpha <<'EOF'
@workspace 1
foot | foot
EOF
    mkdir -p "$HOME/.local/state/niri-spaces"
    printf 'not json\n' >"$HOME/.local/state/niri-spaces/session.json"
    run "$NS_CLI" start
    [ "$status" -eq 0 ]
    [[ "$output" == *"session restore failed"* ]]
    # The load line still ran after the failed restore.
    app_ran foot
}
