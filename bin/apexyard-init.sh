#!/usr/bin/env bash
# Create an ops repository with the full framework history.
set -euo pipefail
usage() {
  echo 'Usage: apexyard init [--org X] [--name ops] [--private|--public] [--dir PATH] [--ref REF] [--agent NAME] [--dry-run]'
}
fail() { echo "apexyard init: $*" >&2; exit 2; }
org='' name=ops visibility=--private target='' dry_run=0 agent=claude
ref=${APEXYARD_FRAMEWORK_REF:-main}
framework=${APEXYARD_FRAMEWORK_URL:-https://github.com/me2resh/apexyard.git}
gh_cmd=${APEXYARD_GH:-gh}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --org|--name|--dir|--ref|--agent)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 requires a value"
      case "$1" in
        --org) org=$2 ;; --name) name=$2 ;; --dir) target=$2 ;; --ref) ref=$2 ;; --agent) agent=$2 ;;
      esac
      shift 2 ;;
    --private|--public) visibility=$1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done
case "$agent" in
  claude|codex|cursor|opencode|pi|other) ;;
  *) fail "invalid agent: $agent" ;;
esac
for tool in git jq "$gh_cmd"; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done
[ -n "$org" ] || org=$("$gh_cmd" api user --jq .login)
# GitHub names cannot contain shell or YAML punctuation.
case "$org" in ''|*[!a-zA-Z0-9_-]*) fail 'invalid organisation name' ;; esac
case "$name" in ''|.|..|*[!a-zA-Z0-9_.-]*) fail 'invalid repository name' ;; esac
[ -n "$target" ] || target=$name
case "$target" in /*) ;; *) target="$PWD/$target" ;; esac
if [ -e "$target" ] || [ -L "$target" ]; then
  [ -d "$target" ] || fail "target is not a directory: $target"
  [ -z "$(ls -A "$target")" ] || fail "target directory is not empty: $target"
fi
printf 'Plan:\n  Clone %s at %s into %s with full history.\n' "$framework" "$ref" "$target"
printf '  Rename origin to upstream and create branch main.\n  Record the framework version.\n'
printf '  Create %s/%s %s and push main.\n  Create local setup files.\n' "$org" "$name" "$visibility"
[ "$dry_run" -eq 0 ] || exit 0
git clone --branch "$ref" -- "$framework" "$target"
git -C "$target" remote rename origin upstream
# Reset the cloned branch name without removing its history.
git -C "$target" checkout -B main
version=$(git -C "$target" describe --tags --exact-match "$ref" 2>/dev/null || git -C "$target" describe --tags --always)
mkdir -p "$target/.claude"
printf '%s\n' "$version" > "$target/.claude/framework-version"
git -C "$target" add -- .claude/framework-version
if ! git -C "$target" diff --cached --quiet; then
  git -C "$target" -c user.name='ApexYard' -c user.email='apexyard@users.noreply.github.com' commit -m 'chore: record framework version'
fi
(cd "$target" && "$gh_cmd" repo create "$org/$name" "$visibility" --source=. --remote=origin --push)
for pair in 'onboarding.example.yaml onboarding.yaml' 'apexyard.projects.yaml.example apexyard.projects.yaml'; do
  read -r example local_file <<< "$pair"
  if [ ! -e "$target/$local_file" ]; then
    cp "$target/$example" "$target/$local_file"
  fi
done
sed "s/name: \"Your Company Name\"/name: \"$org\"/" "$target/onboarding.yaml" > "$target/onboarding.yaml.tmp"
mv "$target/onboarding.yaml.tmp" "$target/onboarding.yaml"
printf 'Open %s in your agent tool. Run /setup to complete setup.\n' "$target"

# Telemetry must not prevent repository creation.
# shellcheck source=bin/_lib-telemetry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib-telemetry.sh"
telemetry_notice_once || true
telemetry_send "$agent" || true
