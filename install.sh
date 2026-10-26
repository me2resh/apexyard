#!/bin/sh
# Install the CLI. This script never creates a repository.
set -eu
VERSION="__VERSION__"
version=${APEXYARD_VERSION:-$VERSION}
prefix=${APEXYARD_PREFIX:-$HOME/.local}
base=${APEXYARD_RELEASE_BASE:-https://github.com/me2resh/apexyard/releases/download}
dry_run=0
fail() { echo "apexyard install: $*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--prefix)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 requires a value"
      case "$1" in --version) version=$2 ;; --prefix) prefix=$2 ;; esac
      shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) echo 'Usage: sh install.sh [--version X] [--prefix DIR] [--dry-run]'; echo '  --version accepts a framework version such as 5.11.0 or v5.11.0.'; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done
[ "$version" != "__VERSION""__" ] || fail 'Set APEXYARD_VERSION or use --version X.'
version=${version#v}
case "$version" in ''|*[!a-zA-Z0-9._-]*|.|..) fail 'invalid version' ;; esac
[ "$(id -u)" != 0 ] || fail 'Do not run this installer as root.'
case "$prefix" in /*) ;; *) prefix="$PWD/$prefix" ;; esac
tag="v$version"
name="apexyard-$tag"
url="${base%/}/$tag/$name.tar.gz"
dest="$prefix/share/apexyard/$tag"
printf 'Plan:\n  Version: %s\n  Download: %s\n  Checksum: %s.sha256\n' "$version" "$url" "$url"
printf '  Install directory: %s\n  Symlink: %s/bin/apexyard\n  no sudo is used\n' "$dest" "$prefix"
[ "$dry_run" -eq 0 ] || exit 0
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
curl -q -fsSL "$url" -o "$work/$name.tar.gz" || fail 'archive download failed'
curl -q -fsSL "$url.sha256" -o "$work/checksum" || fail 'checksum download failed'
expected=$(cat "$work/checksum")
# Accept exactly one checksum for the requested archive.
hash=${expected%% *}
[ "$expected" = "$hash  $name.tar.gz" ] || fail 'invalid checksum file'
[ "${#hash}" -eq 64 ] || fail 'invalid checksum length'
case "$hash" in *[!0-9a-fA-F]*) fail 'invalid checksum' ;; esac
if command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$work/$name.tar.gz")
else
  actual=$(sha256sum "$work/$name.tar.gz")
fi
[ "$hash" = "${actual%% *}" ] || fail 'checksum mismatch'
mkdir "$work/extracted"
tar -xzf "$work/$name.tar.gz" -C "$work/extracted"
[ -f "$work/extracted/$name/bin/apexyard" ] || fail 'CLI missing from archive'
[ ! -e "$dest" ] && [ ! -L "$dest" ] || fail "install directory exists: $dest"
[ ! -d "$prefix/bin/apexyard" ] || fail 'symlink path is a directory'
mkdir -p "$prefix/share/apexyard" "$prefix/bin"
mv "$work/extracted/$name" "$dest"
ln -sfn "$dest/bin/apexyard" "$prefix/bin/apexyard"
printf 'Installed apexyard %s.\n' "$version"
case ":$PATH:" in *":$prefix/bin:"*) ;; *) printf 'Add this directory to PATH: %s/bin\n' "$prefix" ;; esac
