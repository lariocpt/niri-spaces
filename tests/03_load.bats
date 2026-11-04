#!/usr/bin/env bats
# (c) load: resolve a name to a file (spaces/, or templates/ with $1..$9
# substituted) and run it. resolve_space at niri-spaces:171; the template loop
# substitutes exactly `$#` args, so a missing arg is left as a literal `$N`.

load helpers/setup
setup() { ns_setup; }

@test "load: loads a named space from the config dir" {
    install_stub_apps foot
    write_space mine <<'EOF'
@workspace 1
foot | foot
EOF
    run "$NS_CLI" load mine
    [ "$status" -eq 0 ]
    [[ "$output" == *"Loading space 'mine'"* ]]
    [[ "$output" == *"Space 'mine' loaded."* ]]
    app_ran foot
}

@test "load: template args substitute into @workspace, app_id and command" {
    install_stub_apps foot
    # $1 -> @workspace target, $2 -> app_id field, $3 -> command field.
    export NIRI_FAKE_WIN_APPID=APPIDX
    write_template tmpl <<'EOF'
@workspace $1
$2 | foot --a=$3 | | cap
@action printf '%s\n' "$cap" >> "$NS_CAPTURE"
EOF
    run "$NS_CLI" load tmpl WSNAME APPIDX CMDARG
    [ "$status" -eq 0 ]
    actions_has "action move-window-to-workspace --window-id win-1 WSNAME"
    [ "$(argv_of foot)" = "foot --a=CMDARG" ]
    [[ "$output" == *"launching APPIDX"* ]]
    [ "$(cat "$NS_CAPTURE")" = "win-1" ]
}

@test "load: template with too few args substitutes what it has and skips the rest" {
    install_stub_apps foot brave
    # Only 2 args are given for a template using $1..$3. The loop runs seq 1 2,
    # so $3 is never substituted and stays a literal `$3` in the file; when the
    # command field is later eval'd it references an unset positional and the
    # launch subshell dies on `set -u`. The documented, observed behaviour: the
    # provided args are used, the too-few line does not spawn, and load still
    # exits 0 — it is not treated as a fatal error.
    write_template few <<'EOF'
@workspace $1
foot | foot --a=$2 | | x
brave | brave --b=$3 | | y
EOF
    run "$NS_CLI" load few main secondary
    [ "$status" -eq 0 ]
    app_ran foot
    [ "$(argv_of foot)" = "foot --a=secondary" ]
    [ "$(argv_of brave)" = "" ]                    # the $3 line never launched
    [[ "$output" == *'$3: unbound variable'* ]]
    [[ "$output" == *"Space 'few' loaded."* ]]
}

@test "load: unknown space name is a non-zero refusal that names it" {
    run "$NS_CLI" load nosuchspace
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error: no space or template named 'nosuchspace'"* ]]
}

@test "load: no arguments is a usage error" {
    run "$NS_CLI" load
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: niri-spaces load"* ]]
}
