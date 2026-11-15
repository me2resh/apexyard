#!/usr/bin/env bash
# Stamp packaging from the framework release tag and archive checksum.
set -euo pipefail
[ "$#" -eq 2 ] || { echo 'Usage: stamp-packaging.sh TAG OUTDIR' >&2; exit 2; }
tag=$1
case "$tag" in ''|*[!a-zA-Z0-9._-]*|.|..) echo 'Invalid tag' >&2; exit 2 ;; esac
version=${tag#v}
root=$(cd "$(dirname "$0")/.." && pwd)
out=$2
archive="$out/apexyard-$tag.tar.gz"
checksum="$archive.sha256"
[ -f "$checksum" ] || { echo "Missing checksum: $checksum" >&2; exit 1; }
[ -f "$archive" ] || { echo "Missing archive: $archive" >&2; exit 1; }
hash=$(awk 'NR == 1 {print $1}' "$checksum")
[ "${#hash}" -eq 64 ] || { echo 'Invalid checksum length' >&2; exit 1; }
case "$hash" in *[!0-9a-fA-F]*) echo 'Invalid checksum' >&2; exit 1 ;; esac
# The npm package embeds the archive, so the archive must match the checksum.
if command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$archive")
else
  actual=$(sha256sum "$archive")
fi
[ "$(printf '%s' "$hash" | tr '[:upper:]' '[:lower:]')" = "${actual%% *}" ] || { echo 'Archive checksum mismatch' >&2; exit 1; }
mkdir -p "$out/create-apexyard/bin"
sed "s/^VERSION=.*/VERSION=\"$version\"/" "$root/install.sh" > "$out/install.sh"
sed -e "s/__TAG__/$tag/g" -e "s/__VERSION__/$version/g" -e "s/__SHA256__/$hash/g" \
  "$root/packaging/homebrew/apexyard.rb" > "$out/apexyard.rb"
# The npm package pins the same tag and SHA-256 as the formula (AgDR-0300).
sed -e "s/__TAG__/$tag/g" -e "s/__VERSION__/$version/g" -e "s/__SHA256__/$hash/g" \
  "$root/packaging/npm/create-apexyard/package.json" > "$out/create-apexyard/package.json"
cp "$archive" "$out/create-apexyard/"
cp "$root/packaging/npm/create-apexyard/bin/create-apexyard.js" "$out/create-apexyard/bin/"
cp "$root/packaging/npm/create-apexyard/README.md" "$out/create-apexyard/"
chmod 755 "$out/install.sh" "$out/create-apexyard/bin/create-apexyard.js"
if grep -REn --exclude='*.tar.gz' '__[A-Z][A-Z0-9_]*__' "$out/install.sh" "$out/apexyard.rb" "$out/create-apexyard"; then
  echo 'Unresolved packaging placeholder' >&2
  exit 1
fi
