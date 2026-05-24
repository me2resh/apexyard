#!/usr/bin/env bash
# _lib-mermaid-lint.sh
#
# Extract Mermaid code blocks from a markdown file and validate each via
# the Mermaid parser. The default tool is `@mermaid-js/mermaid-cli` (mmdc)
# via npx — it's the canonical parser. Graceful-degrades when Node / npx
# isn't available (exit 3, advisory) so the parent skill doesn't crash on
# adopters who haven't installed Node.
#
# Usage:
#   _lib-mermaid-lint.sh <file.md> [--skip-lint] [--max-blocks=N]
#
# Exit codes:
#   0 — all Mermaid blocks parsed cleanly, OR --skip-lint, OR file had no
#       Mermaid blocks (no-op)
#   1 — one or more blocks failed to parse (the offending blocks are
#       printed to stderr)
#   2 — bad input (file missing, unknown flag, blocks above --max-blocks)
#   3 — npx / mmdc not available (advisory message to stderr; caller decides
#       whether to treat this as soft-fail or hard-fail)
#
# Per-skill wrappers (`.claude/skills/{c4,dfd,tech-vision}/lint.sh`) call
# into this lib so the validation logic lives in one place — locality
# argument from /process (one lint.sh per skill) is preserved by the thin
# wrapper, while DRY is preserved by the shared lib.

set -uo pipefail

FILE=""
SKIP_LINT=0
MAX_BLOCKS=20

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-lint)
      SKIP_LINT=1
      shift
      ;;
    --max-blocks=*)
      MAX_BLOCKS="${1#--max-blocks=}"
      shift
      ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    -*)
      echo "_lib-mermaid-lint.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [ -z "$FILE" ]; then
        FILE="$1"
      else
        echo "_lib-mermaid-lint.sh: unexpected positional arg: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ "$SKIP_LINT" = "1" ]; then
  echo "_lib-mermaid-lint.sh: --skip-lint set, exit 0"
  exit 0
fi

if [ -z "$FILE" ]; then
  echo "_lib-mermaid-lint.sh: markdown file path is required" >&2
  exit 2
fi

if [ ! -f "$FILE" ]; then
  echo "_lib-mermaid-lint.sh: file not found: $FILE" >&2
  exit 2
fi

if ! command -v npx >/dev/null 2>&1; then
  cat >&2 <<MSG
_lib-mermaid-lint.sh: npx not found — Mermaid validator cannot run.

  Install Node + npm (https://nodejs.org), then re-run the parent skill.
  To bypass the lint gate, pass --skip-lint to the parent skill (the
  operator owns the consequences — a non-lint-clean Mermaid block may
  render broken on GitHub).
MSG
  exit 3
fi

WORK=$(mktemp -d -t mermaid-lint-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Extract fenced ```mermaid blocks into separate .mmd files. We accept the
# block opener with optional trailing whitespace (` ```mermaid `) and close
# on any line that is exactly ` ``` ` (with optional trailing whitespace).
awk -v outdir="$WORK" '
  BEGIN { in_block = 0; n = 0 }
  /^[[:space:]]*```[[:space:]]*mermaid[[:space:]]*$/ {
    in_block = 1
    n++
    out = sprintf("%s/block-%02d.mmd", outdir, n)
    next
  }
  /^[[:space:]]*```[[:space:]]*$/ {
    if (in_block) { in_block = 0; close(out) }
    next
  }
  in_block { print > out }
' "$FILE"

BLOCK_COUNT=$(find "$WORK" -maxdepth 1 -name 'block-*.mmd' 2>/dev/null | wc -l | tr -d ' ')

if [ "$BLOCK_COUNT" -eq 0 ]; then
  echo "_lib-mermaid-lint.sh: no Mermaid blocks in $FILE — nothing to lint"
  exit 0
fi

if [ "$BLOCK_COUNT" -gt "$MAX_BLOCKS" ]; then
  echo "_lib-mermaid-lint.sh: $BLOCK_COUNT block(s) exceeds --max-blocks=$MAX_BLOCKS — refusing" >&2
  exit 2
fi

FAILED=0
INVOKE_LOG="$WORK/invoke.log"

for block in "$WORK"/block-*.mmd; do
  name=$(basename "$block")
  # mmdc validates by attempting to render. We send the SVG to a temp path
  # we then discard. --quiet suppresses progress chatter; errors still go
  # to stderr. -y on npx skips the install-confirmation prompt.
  if npx -y @mermaid-js/mermaid-cli \
        -i "$block" \
        -o "$WORK/$name.svg" \
        --quiet \
        > "$INVOKE_LOG" 2>&1; then
    : # parsed clean
  else
    rc=$?
    # mmdc exits non-zero for both "package not installed" and "parse failed".
    # If the failure mode is install-class (no internet on first run), we
    # surface that to the caller as exit 3 — operator can rerun once online.
    if grep -qE 'ENOTFOUND|ETIMEDOUT|getaddrinfo|network|EAI_AGAIN' "$INVOKE_LOG"; then
      cat >&2 <<MSG
_lib-mermaid-lint.sh: mmdc install / network failure on first run.
  npx couldn't fetch @mermaid-js/mermaid-cli. Try again with network, or
  install once explicitly: \`npm install -g @mermaid-js/mermaid-cli\`.
  To bypass, pass --skip-lint to the parent skill.
MSG
      cat "$INVOKE_LOG" >&2
      exit 3
    fi
    echo "_lib-mermaid-lint.sh: parse error in $name (mmdc exit $rc):" >&2
    cat "$INVOKE_LOG" >&2
    echo "---" >&2
    FAILED=$((FAILED + 1))
  fi
done

if [ "$FAILED" -gt 0 ]; then
  echo "_lib-mermaid-lint.sh: $FAILED of $BLOCK_COUNT block(s) failed to parse" >&2
  echo "_lib-mermaid-lint.sh: fix the offending Mermaid blocks in $FILE and re-run" >&2
  exit 1
fi

echo "_lib-mermaid-lint.sh: all $BLOCK_COUNT Mermaid block(s) parsed cleanly"
exit 0
