#!/usr/bin/env bash
# Warn only. Use the local pin without fetching or writing repository files.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 0
# A clone of the framework source itself (origin is the framework repo) has
# no pin. It is not a team's copy, so it gets no notice; contributors would
# see it every session. A team's ops fork without a pin still gets the warning.
if [ ! -f "$root/.claude/framework-version" ]; then
  origin=$(git -C "$root" remote get-url origin 2>/dev/null || true)
  case "$origin" in
    *[:/]me2resh/apexyard|*[:/]me2resh/apexyard.git) exit 0 ;;
  esac
fi
if ! bash "$root/bin/update-files.sh" --drift --repo "$root" >/dev/null 2>&1; then
  echo 'WARN: framework drift or unavailable pin; run apexyard doctor --drift.'
fi
exit 0
