#!/usr/bin/env bats
# (l) the installer under the shells it claims to support.
#
# docs/install.sh is #!/bin/sh on purpose, but a test suite that just says
# `sh install.sh` only proves whatever /bin/sh happens to be ON THIS BOX — on
# Arch that is bash, which is the most forgiving dialect there is. So each test
# names its interpreter instead of inheriting one:
#
#   bash        the permissive case, always run
#   dash        strict POSIX, no bashisms; skipped only if dash is not installed
#   busybox ash the strictest common case, via an Alpine container (Alpine's
#               /bin/sh IS busybox ash). Skipped when docker is unavailable or
#               the image cannot be fetched, so the suite stays runnable offline.
#
# Every run installs for real into its own $HOME and asserts the bins landed.
# --file= keeps it offline: the installer then needs no curl (install.sh:273).

load helpers/setup

setup() {
    ns_setup
    ns_build_release 0.1.0
}

# Install $NS_TEST_TARBALL with interpreter $1 into a fresh $2, and check the
# result. Kept to one function so a dialect change cannot desync the assertions.
install_with() {
    local interp="$1" home="$2"
    shift 2
    mkdir -p "$home"
    run env HOME="$home" "$interp" "$NS_INSTALL" "$@"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"verified"* ]]
    [ -x "$home/.local/bin/niri-spaces" ]
    [ -x "$home/.local/bin/space-splash" ]
    [ -f "$home/.config/niri-spaces/spaces/main.space" ]
}

@test "install: runs under bash" {
    install_with bash "$BATS_TEST_TMPDIR/h-bash" \
        --file="$NS_TEST_TARBALL" --sha256="$NS_TEST_SHA"
}

@test "install: runs under dash (strict POSIX sh)" {
    command -v dash >/dev/null || skip "dash not installed"
    install_with dash "$BATS_TEST_TMPDIR/h-dash" \
        --file="$NS_TEST_TARBALL" --sha256="$NS_TEST_SHA"
}

@test "install: parses as POSIX sh under dash, bash and busybox ash" {
    # A syntax check is cheap and catches bashisms even where the full install
    # cannot run (no docker, no network). At least one strict shell must be
    # able to parse it, or the #!/bin/sh promise is decorative.
    local checked=0
    if command -v dash >/dev/null; then
        dash -n "$NS_INSTALL"; checked=1
    fi
    if command -v busybox >/dev/null; then
        busybox sh -n "$NS_INSTALL"; checked=1
    fi
    [ "$checked" -eq 1 ] || skip "no strict POSIX shell available to parse the installer"
}

@test "install: runs under busybox ash in Alpine" {
    command -v docker >/dev/null || skip "docker not installed"
    # One image, one mount: the installer, the artifact and the target HOME all
    # live under $BATS_TEST_TMPDIR/shell, so the bins the container writes are visible here.
    local w="$BATS_TEST_TMPDIR/shell"
    mkdir -p "$w/bin"
    cp "$NS_INSTALL" "$w/install.sh"
    cp "$NS_TEST_TARBALL" "$w/art.tar.gz"
    # The installer refuses to run without niri on PATH, and Alpine has no niri.
    # A stub is the honest way past that preflight: it is what the other tests'
    # fake niri does, and this test is about the shell dialect, not about niri.
    printf '#!/bin/sh\nexit 0\n' >"$w/bin/niri"
    chmod +x "$w/bin/niri"

    # Offline or docker-less boxes skip instead of failing: this test proves a
    # claim about busybox ash, and a red suite is not how we say "unverified".
    if ! docker image inspect alpine:3 >/dev/null 2>&1; then
        docker pull -q alpine:3 >/dev/null 2>&1 || skip "could not fetch alpine:3"
    fi

    # Pin HOME into the mount, or the bins land in the container's /root and
    # vanish when it exits — leaving a green run that installed nothing checkable.
    # The installer preflights jq, which Alpine's base image does not ship.
    # Install the real one — stubbing a hard dependency here would test the
    # stub, not the installer.
    # Pass the digest in as an env var rather than splicing it into the command
    # string — it is hex, but shell concatenation is how quoting bugs are born.
    # The chown matters: the container runs as root, and root-owned files in the
    # bats tmpdir survive teardown as litter the next run cannot delete.
    run docker run --rm -e HOME=/w/h -e NS_SHA="$NS_TEST_SHA" \
        -e NS_UID="$(id -u)" -e NS_GID="$(id -g)" \
        -e PATH=/w/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        -v "$w:/w" alpine:3 \
        sh -c 'apk add --no-cache jq >/dev/null 2>&1 || exit 77
               sh /w/install.sh --file=/w/art.tar.gz --sha256="$NS_SHA"; rc=$?
               chown -R "$NS_UID:$NS_GID" /w 2>/dev/null
               exit $rc'
    if [ "$status" -eq 77 ]; then skip "apk could not install jq in the container"; fi
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"verified"* ]]
    # Written by the container, checked from here through the same mount.
    [ -x "$w/h/.local/bin/niri-spaces" ] || \
        { echo "niri-spaces not installed under $w/h:"; find "$w"; false; }
    [ -x "$w/h/.local/bin/space-splash" ]
    [ -f "$w/h/.config/niri-spaces/spaces/main.space" ]
}
