#!/usr/bin/env bash
# Test suite for _lib-structurizr-lint.sh and its per-skill wrapper
# (c4/lint-dsl.sh).
#
# Coverage:
#   - Clean workspace.dsl                      → exit 0
#   - Unbalanced braces (stray closing brace)   → exit 1
#   - Unbalanced braces (unclosed block)        → exit 1
#   - Missing `model { }` block                 → exit 1
#   - Missing `views { }` block                 → exit 1
#   - Missing top-level `workspace` block       → exit 1
#   - Duplicate identifier assignment           → exit 1
#   - Braces inside a `//` comment don't count  → exit 0
#   - --skip-lint                               → exit 0 (no-op)
#   - Missing file                              → exit 2
#   - Empty file                                → exit 1
#   - Unknown flag                               → exit 2
#   - c4/lint-dsl.sh dispatches to the shared lib (clean case)
#   - The shipped template (templates/architecture/c4-structurizr.dsl)
#     itself lints clean — regression guard against template drift
#
# No external tool is required — this lib is dependency-free by design
# (structural check only; structurizr-cli is optional and auto-detected).
#
# Usage:  bash .claude/skills/_lib-structurizr-lint.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/_lib-structurizr-lint.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

assert_exit() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "  PASS: $label  (exit $got)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label  (want exit $want, got $got)"
    FAIL=$((FAIL + 1))
  fi
}

FIXTURES=$(mktemp -d -t structurizr-lint-test-XXXXXX)
trap 'rm -rf "$FIXTURES"' EXIT

# --- Fixtures ------------------------------------------------------------

cat > "$FIXTURES/clean.dsl" <<'DSL'
workspace "Test" "A clean fixture" {
    model {
        user = person "User" "A user"
        main = softwareSystem "Test" "The system" {
            web = container "Web" "React" "UI"
        }
        user -> main "Uses" "HTTPS"
    }
    views {
        systemContext main "L1" {
            include *
            autoLayout
        }
    }
}
DSL

cat > "$FIXTURES/stray-close.dsl" <<'DSL'
workspace "Test" "Stray closing brace" {
    model {
        user = person "User" "A user"
    }
    }
    views {
        systemContext main "L1" { include * }
    }
}
DSL

cat > "$FIXTURES/unclosed.dsl" <<'DSL'
workspace "Test" "Unclosed block" {
    model {
        user = person "User" "A user"
    views {
        systemContext main "L1" { include * }
    }
}
DSL

cat > "$FIXTURES/no-model.dsl" <<'DSL'
workspace "Test" "Missing model block" {
    views {
        systemContext main "L1" { include * }
    }
}
DSL

cat > "$FIXTURES/no-views.dsl" <<'DSL'
workspace "Test" "Missing views block" {
    model {
        user = person "User" "A user"
    }
}
DSL

cat > "$FIXTURES/no-workspace.dsl" <<'DSL'
model {
    user = person "User" "A user"
}
views {
    systemContext main "L1" { include * }
}
DSL

cat > "$FIXTURES/dupes.dsl" <<'DSL'
workspace "Test" "Duplicate identifiers" {
    model {
        api = softwareSystem "API" "First declaration"
        api = softwareSystem "API" "Accidental redeclaration"
    }
    views {
        systemContext api "L1" { include * }
    }
}
DSL

cat > "$FIXTURES/comment-braces.dsl" <<'DSL'
workspace "Test" "Braces only inside comments" {
    model {
        // this comment has an unmatched { brace on purpose
        user = person "User" "A user"
        // and this one has an unmatched } brace
    }
    views {
        systemContext main "L1" { include * }
    }
}
DSL

# --- Tests ---------------------------------------------------------------

echo ""
echo "1) Input validation"

set +e
bash "$LIB" 2>/dev/null
assert_exit "missing file path → exit 2" 2 $?

bash "$LIB" "$FIXTURES/does-not-exist.dsl" 2>/dev/null
assert_exit "non-existent file → exit 2" 2 $?

bash "$LIB" "$FIXTURES/clean.dsl" --no-such-flag 2>/dev/null
assert_exit "unknown flag → exit 2" 2 $?

: > "$FIXTURES/empty.dsl"
bash "$LIB" "$FIXTURES/empty.dsl" 2>/dev/null
assert_exit "empty file → exit 1" 1 $?
set -e

echo ""
echo "2) --skip-lint short-circuit"

bash "$LIB" "$FIXTURES/stray-close.dsl" --skip-lint > /dev/null 2>&1
assert_exit "--skip-lint with broken fixture → exit 0 (no-op)" 0 $?

echo ""
echo "3) Structural validation"

set +e
bash "$LIB" "$FIXTURES/clean.dsl" > /dev/null 2>&1
assert_exit "clean fixture → exit 0" 0 $?

bash "$LIB" "$FIXTURES/stray-close.dsl" > /dev/null 2>&1
assert_exit "stray closing brace → exit 1" 1 $?

bash "$LIB" "$FIXTURES/unclosed.dsl" > /dev/null 2>&1
assert_exit "unclosed block → exit 1" 1 $?

bash "$LIB" "$FIXTURES/no-model.dsl" > /dev/null 2>&1
assert_exit "missing model block → exit 1" 1 $?

bash "$LIB" "$FIXTURES/no-views.dsl" > /dev/null 2>&1
assert_exit "missing views block → exit 1" 1 $?

bash "$LIB" "$FIXTURES/no-workspace.dsl" > /dev/null 2>&1
assert_exit "missing workspace block → exit 1" 1 $?

bash "$LIB" "$FIXTURES/dupes.dsl" > /dev/null 2>&1
assert_exit "duplicate identifier → exit 1" 1 $?

bash "$LIB" "$FIXTURES/comment-braces.dsl" > /dev/null 2>&1
assert_exit "braces inside comments ignored → exit 0" 0 $?
set -e

echo ""
echo "4) Per-skill wrapper dispatches to the lib"

WRAPPER="$SCRIPT_DIR/c4/lint-dsl.sh"
if [ ! -x "$WRAPPER" ]; then
  echo "  FAIL: c4/lint-dsl.sh not executable"
  FAIL=$((FAIL + 1))
else
  set +e
  bash "$WRAPPER" "$FIXTURES/clean.dsl" > /dev/null 2>&1
  assert_exit "c4/lint-dsl.sh on clean fixture → exit 0" 0 $?
  set -e
fi

echo ""
echo "5) Shipped template stays lint-clean (regression guard)"

TEMPLATE="$REPO_ROOT/templates/architecture/c4-structurizr.dsl"
if [ -f "$TEMPLATE" ]; then
  set +e
  bash "$LIB" "$TEMPLATE" > /dev/null 2>&1
  assert_exit "templates/architecture/c4-structurizr.dsl → exit 0" 0 $?
  set -e
else
  echo "  FAIL: templates/architecture/c4-structurizr.dsl not found at $TEMPLATE"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "----------------------------------------"
echo "Total: $((PASS + FAIL))   Passed: $PASS   Failed: $FAIL"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo ""
echo "OK: _lib-structurizr-lint test suite passed."
exit 0
