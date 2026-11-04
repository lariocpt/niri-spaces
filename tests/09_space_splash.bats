#!/usr/bin/env bats
# (i) space-splash. It is a standalone CLI (python3 space-splash <dir>), so these
# invoke it as a subprocess — not unit tests. Its contract (space-splash:98):
# it always draws a box and always prints the "Workspace:" and "Path:" lines, and
# it adds the "Branch:"/"Commit:"/"Status:" block only when <dir> is inside a git
# work tree. It never fails for a plain directory, so the exit code is always 0.

load helpers/setup
setup() { ns_setup; }

# Invoke the splash on a directory and capture stdout+status.
run_splash() { run python3 "$NS_SPLASH" "$1"; }

@test "splash: a plain directory gets a box with Workspace and Path, and no git lines" {
    dir="$BATS_TEST_TMPDIR/plainproj"
    mkdir -p "$dir"
    run_splash "$dir"
    [ "$status" -eq 0 ]
    # The always-present identity lines. The box is sized to the banner, and the
    # info block is truncated to that width, so match the short Workspace line
    # and the Path label rather than a width-sensitive full path.
    [[ "$output" == *"Workspace: plainproj"* ]]
    [[ "$output" == *"Path:"* ]]
    # A non-work-tree must not fabricate git state.
    [[ "$output" != *"Branch:"* ]]
    [[ "$output" != *"Status:"* ]]
}

@test "splash: a clean git repo reports branch, commit subject and 0 modified files" {
    dir="$BATS_TEST_TMPDIR/cleanrepo"
    mkdir -p "$dir"
    git -C "$dir" init -q -b feature/demo
    echo hello >"$dir/file.txt"
    git -C "$dir" add file.txt
    git -c user.email=t@example.com -c user.name=tester \
        -C "$dir" commit -qm "initial commit subject"
    run_splash "$dir"
    [ "$status" -eq 0 ]
    grep -Fq "Branch:    feature/demo" <<<"$output"
    grep -Fq "Commit:    initial commit subject" <<<"$output"
    grep -Fq "Status:    0 modified files" <<<"$output"
}

@test "splash: a dirty git repo counts the modified files" {
    dir="$BATS_TEST_TMPDIR/dirtyrepo"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    echo one >"$dir/tracked.txt"
    git -C "$dir" add tracked.txt
    git -c user.email=t@example.com -c user.name=tester \
        -C "$dir" commit -qm "base"
    echo dirty >>"$dir/tracked.txt"          # one modified file
    run_splash "$dir"
    [ "$status" -eq 0 ]
    grep -Fq "Branch:    main" <<<"$output"
    grep -Fq "Status:    1 modified files" <<<"$output"
}
