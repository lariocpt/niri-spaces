#!/usr/bin/env bats
# (h) menu. There is no fuzzel in this environment (and no WAYLAND_DISPLAY), so
# cmd_menu (niri-spaces:236) always uses the plain `select` fallback, which is
# INDEX-based: it reads a number, not a name. These assert the real behaviour of
# that path — a valid index loads, and the failure paths exit non-zero without
# spawning anything. There is no name-typed input in this branch, so "an unknown
# selection" is exercised as an out-of-range/absent index; the one graceful menu
# error the code does emit is the empty-spaces refusal.

load helpers/setup
setup() { ns_setup; }

@test "menu: selecting index 1 loads the first space" {
    install_stub_apps foot brave
    write_space alpha <<'EOF'
@workspace 1
foot | foot
EOF
    write_space beta <<'EOF'
@workspace 2
brave | brave
EOF
    run env -u WAYLAND_DISPLAY bash -c 'printf "1\n" | "$0" menu' "$NS_CLI"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Loading space 'alpha'"* ]]
    app_ran foot
    refute_app_ran brave
}

@test "menu: no selection (EOF) exits non-zero and loads nothing" {
    install_stub_apps foot brave
    write_space alpha <<'EOF'
@workspace 1
foot | foot
EOF
    run env -u WAYLAND_DISPLAY bash -c '"$0" menu </dev/null' "$NS_CLI"
    [ "$status" -ne 0 ]
    refute_app_ran foot
    refute_app_ran brave
}

@test "menu: an out-of-range index then EOF exits non-zero and loads nothing" {
    install_stub_apps foot brave
    write_space alpha <<'EOF'
@workspace 1
foot | foot
EOF
    write_space beta <<'EOF'
@workspace 2
brave | brave
EOF
    run env -u WAYLAND_DISPLAY bash -c 'printf "99\n" | "$0" menu' "$NS_CLI"
    [ "$status" -ne 0 ]
    refute_app_ran foot
    refute_app_ran brave
}

@test "menu: an empty spaces dir is a clean refusal that names the directory" {
    run env -u WAYLAND_DISPLAY bash -c 'printf "1\n" | "$0" menu' "$NS_CLI"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No spaces defined in $NIRI_SPACES_DIR/spaces."* ]]
}
