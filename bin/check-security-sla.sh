#!/usr/bin/env bash
# Usage: check-security-sla.sh <owner/repo> <owner-login>
set -euo pipefail
[ "$#" = 2 ] || { echo 'Usage: check-security-sla.sh <owner/repo> <owner-login>' >&2; exit 2; }
# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")/../.claude/hooks" && pwd)/_lib-sla.sh"
sla_release_check "$1" "$2"
