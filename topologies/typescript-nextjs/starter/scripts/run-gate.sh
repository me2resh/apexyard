#!/usr/bin/env bash
set -euo pipefail
gate=${1:-}
case "$gate" in
  lint) npx --no-install eslint . ;;
  typecheck) npx --no-install tsc --noEmit ;;
  build) NEXT_TELEMETRY_DISABLED=1 npm run build ;;
  coverage)
    npm run test -- --coverage.reporter=json-summary
    bash scripts/coverage-gate.sh
    ;;
  audit)
    report=$(mktemp)
    trap 'rm -f "$report"' EXIT
    npm audit --omit=dev --json > "$report" || true
    bash scripts/audit-gate.sh "$report"
    ;;
  *)
    printf 'unknown gate\n' >&2
    exit 2
    ;;
esac
