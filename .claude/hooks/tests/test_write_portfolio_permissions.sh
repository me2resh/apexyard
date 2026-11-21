#!/usr/bin/env bash
# Run portfolio permission regressions through the shell test runner.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
python3 "$TEST_DIR/test_write_portfolio_permissions.py"
