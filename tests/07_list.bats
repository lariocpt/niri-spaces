#!/usr/bin/env bats
# (g) list: print the two sections and their members. cmd_list (niri-spaces:225)
# always prints both headers, so the shape is stable even when a section is empty.

load helpers/setup
setup() { ns_setup; }

@test "list: shows spaces and templates under their headers" {
    write_space alpha <<'EOF'
@workspace 1
EOF
    write_space beta <<'EOF'
@workspace 2
EOF
    write_template mono <<'EOF'
@workspace $1
EOF
    run "$NS_CLI" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Spaces ($NIRI_SPACES_DIR/spaces):"* ]]
    [[ "$output" == *"Templates ($NIRI_SPACES_DIR/templates) — need args:"* ]]
    grep -qx '  alpha' <<<"$output"
    grep -qx '  beta' <<<"$output"
    grep -qx '  mono' <<<"$output"
}

@test "list: empty sections still print both headers" {
    run "$NS_CLI" list
    [ "$status" -eq 0 ]
    # Both headers, and nothing listed beneath them (no indented name lines).
    [[ "$output" == *"Spaces ("* ]]
    [[ "$output" == *"Templates ("* ]]
    [ "$(grep -c '^  ' <<<"$output")" -eq 0 ]
}
