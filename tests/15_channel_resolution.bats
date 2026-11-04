#!/usr/bin/env bats
# (h) which repository the channel gate probes, and what it needs in order to know.
#
# The failure this pins happened on a runner, on the first run after the release:
# the weekly channel gate went red with
#
#     error: run this inside the repository with gh authenticated (or set the repo context)
#
# while every channel it existed to probe — the Pages route, the installer, the
# release artifact — was answering fine. The script had asked a signed-in CLI who
# it was, so the gate's verdict depended on a token and a repo context that have
# nothing to do with whether a stranger can install this release. It also meant a
# draft or a private repo could be called healthy, which is the opposite of what
# an install-channel check is for.
#
# These tests use no network and no credentials: `curl` is stubbed to fail, so the
# script must reach its verdict about the repository from the environment alone,
# and the URLs it prints are the evidence of what it decided.

load helpers/setup

setup() { ns_setup; }

# A PATH with a curl that always fails and a gh that always fails, so a probe can
# only go right by resolving the repository rather than by being authenticated.
ns_offline_path() {
    local stub="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$stub"
    printf '#!/bin/sh\nexit 22\n' >"$stub/curl"
    printf '#!/bin/sh\necho "gh: needs a token" >&2\nexit 1\n' >"$stub/gh"
    chmod +x "$stub/curl" "$stub/gh"
    printf '%s' "$stub:$PATH"
}

@test "GITHUB_REPOSITORY decides the channels probed, with no credentials in sight" {
    local path; path=$(ns_offline_path)
    run env -u NIRI_SPACES_DIR "GITHUB_REPOSITORY=envowner/a-fork-of-niri-spaces" \
        PATH="$path" bash "$NS_REPO_ROOT/tools/check-channels.sh"
    # It got as far as probing (and failing the probes), not as far as giving up.
    [ "$status" -eq 1 ]
    [[ "$output" == *"checking the install channels of envowner/a-fork-of-niri-spaces"* ]]
    # The Pages slug follows the repository name, so a fork probes its own route
    # instead of being told a site it does not own is down.
    [[ "$output" == *"https://envowner.github.io/a-fork-of-niri-spaces/ did not answer"* ]]
    [[ "$output" == *"https://envowner.github.io/a-fork-of-niri-spaces/install.sh did not answer"* ]]
    # And it did not fall back to whatever this checkout's remote says.
    [[ "$output" != *"lariocpt"* ]]
}

@test "with no GITHUB_REPOSITORY, the checkout's own origin answers — https form" {
    local path stub
    path=$(ns_offline_path); stub="${path%%:*}"
    printf '#!/bin/sh\necho "https://github.com/remoteowner/niri-spaces.git"\n' >"$stub/git"
    chmod +x "$stub/git"
    run env -u GITHUB_REPOSITORY -u NIRI_SPACES_DIR PATH="$path" \
        bash "$NS_REPO_ROOT/tools/check-channels.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"checking the install channels of remoteowner/niri-spaces"* ]]
}

@test "an ssh-style remote URL resolves too, including a host alias with a port-like colon" {
    local path stub
    path=$(ns_offline_path); stub="${path%%:*}"
    printf '#!/bin/sh\necho "git@github.com-personal:sshowner/niri-spaces.git"\n' >"$stub/git"
    chmod +x "$stub/git"
    run env -u GITHUB_REPOSITORY -u NIRI_SPACES_DIR PATH="$path" \
        bash "$NS_REPO_ROOT/tools/check-channels.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"checking the install channels of sshowner/niri-spaces"* ]]
}

@test "nothing to go on is a hard stop that says what to set, not a silent pass" {
    local path stub
    path=$(ns_offline_path); stub="${path%%:*}"
    printf '#!/bin/sh\nexit 1\n' >"$stub/git"
    chmod +x "$stub/git"
    run env -u GITHUB_REPOSITORY -u NIRI_SPACES_DIR PATH="$path" \
        bash "$NS_REPO_ROOT/tools/check-channels.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"GITHUB_REPOSITORY"* ]]
}

@test "the gate never resolves a release through an authenticated API" {
    # 'latest' means what the /releases/latest redirect hands a visitor, which is
    # also what hides a draft that was never flipped to public. gh release view
    # would answer about a release a stranger cannot install. Comments are prose
    # about the shape we refuse, so they are not the shape; strip them the way the
    # pipeline-shape lint does, or this test fails on its own explanation.
    local hits
    hits=$(grep -n 'gh release\|gh api\|GITHUB_TOKEN\|GH_TOKEN' \
        "$NS_REPO_ROOT/tools/check-channels.sh" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    if [ -n "$hits" ]; then
        printf 'the channel gate must ask anonymously, the way a visitor does:\n'
        printf '%s\n' "$hits"
        return 1
    fi
    grep -qE 'releases/latest' "$NS_REPO_ROOT/tools/check-channels.sh"
}

@test "the release the installer follows and the one the gate checks are the same redirect" {
    # Both halves resolve 'latest' off the same URL shape; if either drifts, the
    # gate is checking a channel nobody installs through.
    grep -qE 'https://github\.com/[^"]*/releases/latest' "$NS_REPO_ROOT/docs/install.sh"
    grep -qE 'https://github\.com/[^"]*/releases/latest' "$NS_REPO_ROOT/tools/check-channels.sh"
}
