#!/usr/bin/env bats
# (e) $TERMINAL/$BROWSER/$*_APPID resolution and app_id derivation. These drive
# resolve_defaults in a hermetic PATH: only the stub apps a test installs are
# visible, and the real host's apps can never leak in. The CLI file is sourced, and
# it detects that (BASH_SOURCE vs $0) and skips help, its dependency preflight and
# its dispatcher, so the functions are callable in isolation in a shell that survives
# the source. The empty argument is a leftover of the earlier contract, when the
# sourced file reached the dispatcher and needed a harmless one.

load helpers/setup
setup() { ns_setup; }

# Echo "TERMINAL|BROWSER|TERMINAL_APPID|BROWSER_APPID" after resolve_defaults,
# with the four vars explicitly unset so autodetection is what is observed.
resolve_autodetect() {
    local d; d="$(build_min_path bash jq basename sed)"; add_niri_to "$d"
    run env -u TERMINAL -u BROWSER -u TERMINAL_APPID -u BROWSER_APPID \
        PATH="$NS_STUBBIN:$d" \
        bash -c 'src="$1"; source "$src" "" >/dev/null 2>&1; resolve_defaults >/dev/null 2>&1; printf "%s|%s|%s|%s" "$TERMINAL" "$BROWSER" "$TERMINAL_APPID" "$BROWSER_APPID"' _ "$NS_CLI"
    printf '%s' "$output"
}

# Same, but with pre-set TERMINAL/BROWSER — exported values must win.
resolve_with_export() { # <TERMINAL> <BROWSER>
    local d; d="$(build_min_path bash jq basename sed)"; add_niri_to "$d"
    run env TERMINAL="$1" BROWSER="$2" \
        PATH="$NS_STUBBIN:$d" \
        bash -c 'src="$1"; source "$src" "" >/dev/null 2>&1; resolve_defaults >/dev/null 2>&1; printf "%s|%s|%s|%s" "$TERMINAL" "$BROWSER" "$TERMINAL_APPID" "$BROWSER_APPID"' _ "$NS_CLI"
    printf '%s' "$output"
}

@test "resolve: exported TERMINAL and BROWSER win over autodetection" {
    install_stub_apps foot firefox
    # ghostty and brave are the first candidates but are not installed; even if
    # they were, an exported value must override the pick.
    [ "$(resolve_with_export foot firefox)" = "foot|firefox|foot|firefox" ]
}

@test "resolve: terminal candidate order skips absent earlier choices" {
    install_stub_apps alacritty            # ghostty, foot absent → alacritty
    [ "$(resolve_autodetect)" = "alacritty||Alacritty|" ]
}

@test "resolve: terminal picks the earliest installed candidate" {
    install_stub_apps foot kitty           # foot before kitty → foot
    [ "$(resolve_autodetect)" = "foot||foot|" ]
}

@test "resolve: terminal picks the last candidate when it is the only one" {
    install_stub_apps kitty                # only kitty → kitty, app_id falls through
    [ "$(resolve_autodetect)" = "kitty||kitty|" ]
}

@test "resolve: browser candidate order prefers brave-origin then brave" {
    install_stub_apps brave-origin brave   # brave-origin is first
    [ "$(resolve_autodetect)" = "|brave-origin||brave" ]
}

@test "resolve: browser falls through to firefox when no brave exists" {
    install_stub_apps firefox
    [ "$(resolve_autodetect)" = "|firefox||firefox" ]
}

@test "resolve: app_id derivation maps known families to their window id" {
    install_stub_apps foot
    # Drive app_id_for directly through the exported-terminal path.
    local d; d="$(build_min_path bash jq basename sed)"; add_niri_to "$d"
    run env -u TERMINAL -u BROWSER -u TERMINAL_APPID -u BROWSER_APPID \
        PATH="$NS_STUBBIN:$d" \
        bash -c 'src="$1"; source "$src" "" >/dev/null 2>&1
                 printf "%s %s %s %s %s %s %s" \
                   "$(app_id_for ghostty)" "$(app_id_for alacritty)" \
                   "$(app_id_for footclient)" "$(app_id_for wezterm)" \
                   "$(app_id_for google-chrome)" "$(app_id_for google-chrome-stable)" \
                   "$(app_id_for firefox)"' _ "$NS_CLI"
    [ "$output" = "com.mitchellh.ghostty Alacritty foot org.wezfurlong.wezterm google-chrome google-chrome firefox" ]
}

@test "resolve: app_id_for prefix-matches a versioned browser name to the family" {
    # brave* covers brave-browser-nightly-style names; google-chrome* likewise.
    local d; d="$(build_min_path bash jq basename sed)"; add_niri_to "$d"
    run env PATH="$NS_STUBBIN:$d" \
        bash -c 'src="$1"; source "$src" "" >/dev/null 2>&1
                 printf "%s/%s" "$(app_id_for brave-browser-nightly)" "$(app_id_for google-chrome-beta)"' _ "$NS_CLI"
    [ "$output" = "brave/google-chrome" ]
}

@test "resolve: wezterm is not auto-detected" {
    install_stub_apps wezterm             # only wezterm present, but it is not a candidate
    # So no terminal is found: TERMINAL resolves empty (with a warning on stderr).
    local d; d="$(build_min_path bash jq basename sed)"; add_niri_to "$d"
    run env -u TERMINAL -u BROWSER -u TERMINAL_APPID -u BROWSER_APPID \
        PATH="$NS_STUBBIN:$d" \
        bash -c 'src="$1"; source "$src" "" >/dev/null 2>&1; resolve_defaults 2>/dev/null; printf "[%s]" "$TERMINAL"' _ "$NS_CLI"
    [ "$output" = "[]" ]
}

@test "resolve: wezterm is honoured when explicitly exported" {
    install_stub_apps foot
    # app_id_for maps wezterm, but resolve_defaults only picks it if exported.
    local d; d="$(build_min_path bash jq basename sed)"; add_niri_to "$d"
    run env -u BROWSER -u TERMINAL_APPID -u BROWSER_APPID TERMINAL=wezterm \
        PATH="$NS_STUBBIN:$d" \
        bash -c 'src="$1"; source "$src" "" >/dev/null 2>&1; resolve_defaults 2>/dev/null; printf "%s=%s" "$TERMINAL" "$TERMINAL_APPID"' _ "$NS_CLI"
    [ "$output" = "wezterm=org.wezfurlong.wezterm" ]
}
