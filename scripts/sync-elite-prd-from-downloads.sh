#!/usr/bin/env bash
# Copy Elite Telegram PRD from macOS Downloads into the ops repo.
# Run on your Mac from the apexyard repo root:
#   ./scripts/sync-elite-prd-from-downloads.sh

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEST="$ROOT/projects/elite-telegram/Elite_Telegram_PRD.md"
mkdir -p "$(dirname "$DEST")"

MD="${HOME}/Downloads/Elite_Telegram_PRD.md"
DOCX="${HOME}/Downloads/Elite_Telegram_PRD.docx"

if [ -f "$MD" ]; then
  cp -p "$MD" "$DEST"
  echo "Copied: $MD -> $DEST"
  exit 0
fi

if [ -f "$DOCX" ]; then
  if command -v pandoc >/dev/null 2>&1; then
    pandoc "$DOCX" -t gfm -o "$DEST"
    echo "Converted: $DOCX -> $DEST (pandoc)"
    exit 0
  fi
  echo "Found $DOCX but pandoc is not installed." >&2
  echo "Install: brew install pandoc   OR export Elite_Telegram_PRD.md to Downloads and re-run." >&2
  exit 1
fi

echo "No source found. Expected one of:" >&2
echo "  $MD" >&2
echo "  $DOCX" >&2
exit 1
