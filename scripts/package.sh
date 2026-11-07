#!/usr/bin/env bash
#
# package.sh — build the release artifact the installer is written to consume.
#
#   ./scripts/package.sh v0.1.0 [--out dist]
#
# Produces `<out>/niri-spaces-<ver>.tar.gz` plus `<out>/niri-spaces-<ver>.tar.gz.sha256`
# in the exact shape docs/install.sh expects:
#
#   - one top-level directory `niri-spaces-<ver>/` holding every payload file,
#     and that directory is what the installer moves into ~/.local/share/niri-spaces;
#   - `install.sh` inside the archive is docs/install.sh itself, so the copy the
#     user runs after extraction is the same script the site served them;
#   - the checksum file is `<hex>  <filename>` with a trailing newline — what
#     `sha256sum -c` parses — and names the tarball by its basename only, so the
#     check passes in whatever directory the installer downloaded it to.
#
# The archive is reproducible: entries sorted, fixed mtime, uid/gid 0, no gzip
# timestamp. Two runs on the same commit produce identical bytes, which is what
# lets CI compare a rebuild against what it published instead of trusting tar.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "usage: ./scripts/package.sh vX.Y.Z [--out DIR]"
tag="$1"; shift
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag '$tag' is not vX.Y.Z"
version="${tag#v}"

out="dist"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) [[ $# -ge 2 ]] || die "--out needs a directory"; out="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

[[ -f niri-spaces && -f space-splash && -f docs/install.sh ]] \
  || die "run this from the repository root (niri-spaces, space-splash and docs/install.sh must exist)"

name="niri-spaces-${version}"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# Stage the payload under its own directory so extraction can never drop files
# straight into the caller's working directory.
mkdir -p "$stage/$name/spaces"
install -m 0755 niri-spaces            "$stage/$name/niri-spaces"
install -m 0755 niri-terminal-pairs    "$stage/$name/niri-terminal-pairs"
install -m 0755 niri-workspace-colors  "$stage/$name/niri-workspace-colors"
install -m 0644 settings.json          "$stage/$name/settings.json"
install -m 0755 space-splash           "$stage/$name/space-splash"
install -m 0644 autostart              "$stage/$name/autostart"
install -m 0644 spaces/*.space         "$stage/$name/spaces/"
install -m 0755 docs/install.sh        "$stage/$name/install.sh"
install -m 0644 LICENSE                "$stage/$name/LICENSE"
install -m 0644 README.md              "$stage/$name/README.md"
install -m 0644 CHANGELOG.md           "$stage/$name/CHANGELOG.md"

# docs/install.sh refuses an archive missing any of these, so a gap here is a
# packaging bug that would only surface on someone else's machine.
for f in niri-spaces space-splash autostart spaces LICENSE README.md; do
  [[ -e "$stage/$name/$f" ]] || die "archive would be missing $f"
done
[[ -n "$(printf '%s' "$stage/$name"/spaces/*.space)" ]] || die "archive would carry no *.space layouts"

mkdir -p "$out"
tarball="$out/$name.tar.gz"

# -h follows symlinks so the archive holds real files; the sort/mtime/owner flags
# are what make the output byte-reproducible.
tar -czf "$tarball" \
  --format=gnu \
  --sort=name \
  --mtime='UTC 2020-01-01' \
  --owner=0 --group=0 --numeric-owner \
  -C "$stage" "$name"

# gzip embeds no timestamp with -n; re-pack through it to strip what tar wrote.
# (tar -z uses gzip's default, which records mtime — repack deterministically.)
gzip -9n -c <(tar -cf - \
  --format=gnu \
  --sort=name \
  --mtime='UTC 2020-01-01' \
  --owner=0 --group=0 --numeric-owner \
  -C "$stage" "$name") > "$tarball"

# Basename only: `sha256sum -c` is run from the download directory.
( cd "$out" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256" )

echo "built $tarball"
echo "built $out/$name.tar.gz.sha256"
