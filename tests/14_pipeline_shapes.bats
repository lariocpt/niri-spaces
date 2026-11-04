#!/usr/bin/env bats
# (g) the shape of a check, not only its verdict. A gate that fails at random teaches
# everyone to re-run it, which quietly deletes whatever it was meant to prove, so the
# commands in the release pipelines are part of the contract alongside their results.
#
# The failure this pins is real and was paid for on a deploy: the pages gate ran
#     tar -tzf dist/niri-spaces-0.0.0.tar.gz | grep -qx 'niri-spaces-0.0.0/install.sh'
# under `set -euo pipefail`. grep -q exits the instant it matches, tar's next write
# lands on a closed pipe, tar prints "tar: stdout: write error" and exits 2, and
# pipefail turns a member that IS present into a failed deploy. Whether it happens at
# all depends on how much output still fits in the pipe buffer, so the identical line
# reads green on a laptop and red on a runner — which is why no amount of re-running
# it would have been a fix. What follows tests the replacement shape, and the lint
# that keeps the old one out.

load helpers/setup

setup() { ns_setup; }

@test "no pipeline hands its output to grep -q, anywhere a release step runs" {
    local hits
    hits=$(grep -rnE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' \
        "$NS_REPO_ROOT/.github/workflows" \
        "$NS_REPO_ROOT/scripts" \
        "$NS_REPO_ROOT/tools" \
        "$NS_REPO_ROOT/tests" \
        "$NS_REPO_ROOT/docs/install.sh" \
        "$NS_REPO_ROOT/niri-spaces" \
        "$NS_REPO_ROOT/space-splash" 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
    if [ -n "$hits" ]; then
        printf 'a producer piped into grep -q can be cut off mid-write:\n'
        printf '%s\n' "$hits"
        return 1
    fi
}

@test "the artifact member check works under the runner's own shell options" {
    local d="$BATS_TEST_TMPDIR/dist"
    run bash "$NS_REPO_ROOT/scripts/package.sh" v0.0.0 --out "$d"
    [ "$status" -eq 0 ]

    # Kept in a file rather than nested quotes: this is the body the pages gate runs,
    # and it has to stay readable enough to compare against the workflow.
    local check="$BATS_TEST_TMPDIR/member-check.sh"
    cat > "$check" <<'EOS'
set -euo pipefail
members=$(tar -tzf "$1/niri-spaces-0.0.0.tar.gz")
for member in niri-spaces-0.0.0/install.sh niri-spaces-0.0.0/autostart; do
    case $'\n'"$members"$'\n' in
        *$'\n'"$member"$'\n'*) ;;
        *) echo "the artifact has no $member" >&2; exit 1 ;;
    esac
done
EOS
    run bash "$check" "$d"
    [ "$status" -eq 0 ]

    # A check that cannot fail is not a check: the same shape must reject a member
    # that is not in the artifact.
    sed 's|niri-spaces-0.0.0/autostart|niri-spaces-0.0.0/not-shipped|' "$check" > "$check.neg"
    run bash "$check.neg" "$d"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not-shipped"* ]]
}
