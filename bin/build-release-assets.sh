#!/usr/bin/env bash
# Build the CLI archive without network access.
set -euo pipefail
[ "$#" -eq 2 ] || { echo 'Usage: build-release-assets.sh VERSION OUTDIR' >&2; exit 2; }
version=$1
case "$version" in ''|*[!a-zA-Z0-9._-]*|.|..) echo 'Invalid version' >&2; exit 2 ;; esac
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$2"
out=$(cd "$2" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
name="apexyard-$version"
mkdir -p "$work/$name/bin"
for file in apexyard apexyard-init.sh apexyard-update.sh _lib-telemetry.sh _lib-ownership.sh; do
  if [ "$file" = _lib-ownership.sh ] && [ ! -f "$root/bin/$file" ]; then continue; fi
  cp "$root/bin/$file" "$work/$name/bin/$file"
done
sed "s/^APEXYARD_CLI_VERSION=.*/APEXYARD_CLI_VERSION=\"${version#v}\"/" "$root/bin/apexyard" > "$work/$name/bin/apexyard"
chmod 755 "$work/$name/bin/"*
printf '%s\n' "$version" > "$work/$name/VERSION"
# Stable input order and timestamps also work with BSD tar.
(cd "$work" && find "$name" -exec env TZ=UTC touch -t 200001010000 {} +)
(cd "$work" && LC_ALL=C find "$name" -type f | LC_ALL=C sort > "$work/files")
(cd "$work" && tar -cf - -T "$work/files") | gzip -n > "$out/$name.tar.gz"
cd "$out"
if command -v shasum >/dev/null 2>&1; then
  hash=$(shasum -a 256 "$name.tar.gz")
else
  hash=$(sha256sum "$name.tar.gz")
fi
printf '%s  %s\n' "${hash%% *}" "$name.tar.gz" > "$name.tar.gz.sha256"
