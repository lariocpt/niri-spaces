#!/usr/bin/env bats
# (d) spawn pipeline. launch_on_workspace (niri-spaces:93) snapshots the matching
# window ids before a spawn, then diffs the post list to learn the new id and
# emits `move-window-to-workspace`. @action lines then run against the captured
# id. These pin the exact action sequence, the captured id, and the argv each
# fake app received.

load helpers/setup
setup() { ns_setup; }

@test "spawn: 2-app space emits moves then @action focus/set-column-width in order" {
    install_stub_apps foot brave
    write_space two <<'EOF'
@workspace 1
foot | foot --title=l | | lid
brave | brave --url=x | | bid
@action printf '%s %s\n' "$lid" "$bid" >> "$NS_CAPTURE"
@action [ -n "$lid" ] && niri msg action focus-window --id "$lid" && niri msg action set-column-width "50%"
@action [ -n "$bid" ] && niri msg action focus-window --id "$bid" && niri msg action set-column-width "50%"
EOF
    run "$NS_CLI" load two
    [ "$status" -eq 0 ]

    # Captured vars hold the ids the window-diff learned, in spawn order.
    [ "$(cat "$NS_CAPTURE")" = "win-1 win-2" ]

    # The argv each fake app received matches the space file's command fields.
    [ "$(argv_of foot)" = "foot --title=l" ]
    [ "$(argv_of brave)" = "brave --url=x" ]

    # The action sequence, in order: two moves, then focus+width per @action.
    [ "$(nth_action 1)" = "action move-window-to-workspace --window-id win-1 1" ]
    [ "$(nth_action 2)" = "action move-window-to-workspace --window-id win-2 1" ]
    [ "$(nth_action 3)" = "action focus-window --id win-1" ]
    [ "$(nth_action 4)" = "action set-column-width 50%" ]
    [ "$(nth_action 5)" = "action focus-window --id win-2" ]
    [ "$(nth_action 6)" = "action set-column-width 50%" ]
}

@test "spawn: the shipped default.space drives focus-window and set-column-width" {
    install_stub_apps foot brave
    export TERMINAL=foot BROWSER=brave
    cp "$NS_REPO_ROOT/spaces/default.space" "$NIRI_SPACES_DIR/spaces/default.space"
    # "default" seeded empty so both windows move to it by name; an absent
    # name would open it through the create path (spec'd in 16_workspace_ops).
    write_workspaces <<'EOF'
[{"id":1,"idx":1,"name":"default","output":"eDP-1","is_urgent":false,"is_active":false,"is_focused":false,"active_window_id":null}]
EOF
    run "$NS_CLI" load default
    [ "$status" -eq 0 ]
    # Terminal first, browser second, both moved to workspace "default" (its
    # @workspace name), then the two 50/50 @actions.
    [ "$(nth_action 1)" = "action move-window-to-workspace --window-id win-1 default" ]
    [ "$(nth_action 2)" = "action move-window-to-workspace --window-id win-2 default" ]
    [ "$(nth_action 3)" = "action focus-window --id win-1" ]
    [ "$(nth_action 4)" = "action set-column-width 50%" ]
    [ "$(nth_action 5)" = "action focus-window --id win-2" ]
    [ "$(nth_action 6)" = "action set-column-width 50%" ]
}

@test "spawn: the prefix match lets a bare family id capture a versioned window" {
    install_stub_apps pfxwin
    # The space declares the bare app_id "brave"; the fake app reports the
    # versioned "brave-browser-nightly". startswith() in the jq filter (line 100)
    # is what lets the diff learn it — proving the documented prefix behaviour.
    export NIRI_FAKE_WIN_APPID=brave-browser-nightly
    write_space pfx <<'EOF'
@workspace 7
brave | pfxwin | | pid
@action printf '%s\n' "$pid" >> "$NS_CAPTURE"
EOF
    run "$NS_CLI" load pfx
    [ "$status" -eq 0 ]
    [ "$(cat "$NS_CAPTURE")" = "win-1" ]
}

@test "spawn: a window whose app_id never appears leaves the capture empty and warns" {
    # No stub is installed for the target, so no window ever shows up. The CLI
    # warns instead of hanging on the happy path, and the capture stays empty.
    # Kept as a genuine negative despite the ~10s poll: it pins the documented
    # "left where it opened" fallback that @action lines then guard against.
    write_space gone <<'EOF'
@workspace 1
nosuchapp | nosuchapp | | cid
@action printf '[%s]' "$cid" >> "$NS_CAPTURE"
EOF
    run "$NS_CLI" load gone
    [ "$status" -eq 0 ]
    [[ "$output" == *"no new 'nosuchapp' window appeared"* ]]
    [ "$(cat "$NS_CAPTURE")" = "[]" ]
}
