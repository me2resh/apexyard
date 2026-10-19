#!/bin/bash
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/_test-protected-state.sh"
# shellcheck source=/dev/null
. "$ROOT/_lib-command-scrub.sh"
for verb in checkout restore apply am checkout-index read-tree; do
  text="git $verb example"
  check 0 "$verb remains raw" test "$(scrub_bash_command "$text")" = "$text"
done
text='patch -p0 < example.patch'
check 0 'patch remains raw' test "$(scrub_bash_command "$text")" = "$text"
finish
