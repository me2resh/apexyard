#!/bin/bash
# Tests for the external-contribution exemption in validate-pr-create.sh
# (me2resh/apexyard#1448).
#
# A repository listed in `.external_contributions` is one the adopter
# contributes to but does not govern, so this framework's PR-title convention
# is not applied to a PR aimed at it.
#
# The cases that matter are the ones where the exemption must NOT apply. This
# relaxes a gate, so the failure that costs something is an exemption firing
# too widely, not one firing too narrowly.
#
# Coverage:
#   - listed repo, foreign title       → allowed, and says why
#   - unlisted repo, foreign title     → blocked (regression guard)
#   - empty list (the default)         → blocked (ships inert)
#   - listed repo that is ALSO in the registry → blocked (registry wins)
#   - case-insensitive slug match      → allowed
#   - no --repo flag at all            → blocked (exemption needs a target)

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/validate-pr-create.sh"
if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0

SRC_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)

# A title that is correct for an upstream project and wrong for this framework:
# no ticket in parentheses, which is exactly what the convention requires.
FOREIGN_TITLE="feat: merge tuple_file contents into store validation"
BODY=$'## Summary\nx\n\n## Testing\ny\n\n## Glossary\n| t | d |'

make_sandbox() {
  local external_json="$1" registry_repo="${2:-}" registry_shape="${3:-scalar}"
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git remote add origin git@github.com:fork-org/apexyard.git
    git checkout -q -B "feat/GH-1448-external-test"
    touch onboarding.yaml apexyard.projects.yaml
    git add -A >/dev/null 2>&1
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks"
  # _lib-multi-repo-trace.sh carries the registry parser the registry-wins rail
  # depends on. Without it the hook fails closed and every exemption case
  # blocks, which is correct behaviour and a broken fixture.
  for lib in validate-pr-create.sh _lib-read-config.sh _lib-tracker.sh \
             _lib-ops-root.sh _lib-portfolio-paths.sh _lib-extract-pr.sh \
             _lib-multi-repo-trace.sh; do
    [ -f "$SRC_ROOT/.claude/hooks/$lib" ] && cp "$SRC_ROOT/.claude/hooks/$lib" "$sb/.claude/hooks/$lib"
  done
  chmod +x "$sb/.claude/hooks/validate-pr-create.sh"
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"

  # Adopter override carrying the external list under test.
  printf '{ "external_contributions": %s }\n' "$external_json" > "$sb/.claude/project-config.json"

  # Registry: empty unless a repo is meant to be governed. Every shape the
  # framework supports is exercised, because the first version of the
  # registry-wins rail matched only two of them (#1451 B2).
  if [ -n "$registry_repo" ]; then
    case "$registry_shape" in
      scalar)
        printf 'version: 1\nprojects:\n  - name: governed\n    repo: %s\n' "$registry_repo" ;;
      comment)
        printf 'version: 1\nprojects:\n  - name: governed\n    repo: %s  # main app\n' "$registry_repo" ;;
      inline)
        printf 'version: 1\nprojects:\n  - name: governed\n    repos: [%s, fork-org/other]\n' "$registry_repo" ;;
      block)
        printf 'version: 1\nprojects:\n  - name: governed\n    repos:\n      - %s\n      - fork-org/other\n' "$registry_repo" ;;
    esac > "$sb/apexyard.projects.yaml"
  else
    printf 'version: 1\nprojects: []\n' > "$sb/apexyard.projects.yaml"
  fi
  echo "$sb"
}

run_case() {
  local label="$1" external_json="$2" target_repo="$3" want_rc="$4" want_regex="${5:-}" \
        registry_repo="${6:-}" registry_shape="${7:-scalar}" raw_cmd="${8:-}" branch="${9:-}"
  local sb; sb=$(make_sandbox "$external_json" "$registry_repo" "$registry_shape")
  local body_file="$sb/body.md"
  printf '%s' "$BODY" > "$body_file"
  if [ -n "$branch" ]; then
    git -C "$sb" checkout -q -B "$branch" 2>/dev/null
  fi

  local cmd
  if [ -n "$raw_cmd" ]; then
    # A caller-supplied command shape, for the ambiguous-target probes. BODY_FILE
    # is substituted so the body check is not what trips the validator.
    cmd=${raw_cmd//BODY_FILE/$body_file}
  elif [ -n "$target_repo" ]; then
    cmd=$(printf 'gh pr create --repo %s --title "%s" --body-file %s' "$target_repo" "$FOREIGN_TITLE" "$body_file")
  else
    cmd=$(printf 'gh pr create --title "%s" --body-file %s' "$FOREIGN_TITLE" "$body_file")
  fi

  local input got_stderr got_rc
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  # Clear the live session's ops-root pin. `resolve_ops_root` prefers
  # $APEXYARD_OPS_PIN_DIR/ops-root-$CLAUDE_CODE_SESSION_ID over a walk-up, so
  # a test running inside a real ApexYard session would otherwise read the
  # SESSION's project-config and registry instead of the sandbox's — every
  # case would silently exercise the developer's own configuration.
  got_stderr=$(cd "$sb" && echo "$input" \
    | env -u CLAUDE_CODE_SESSION_ID -u APEXYARD_OPS_PIN_DIR \
        bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:400})" >&2
    FAIL=$((FAIL+1)); return
  fi
  if [ -n "$want_regex" ] && ! echo "$got_stderr" | grep -qE "$want_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_regex/" >&2
    echo "    stderr: ${got_stderr:0:400}" >&2
    FAIL=$((FAIL+1)); return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# 1. The feature: a listed repo accepts its own project's title convention,
#    and the operator is told the framework convention was not applied.
run_case "listed repo is exempt" \
  '["openfga/vscode-ext"]' "openfga/vscode-ext" 0 "external_contributions"

# 2. Regression guard: an unlisted repo is still validated.
run_case "unlisted repo still blocked" \
  '["openfga/vscode-ext"]' "some-org/other-repo" 2 "doesn't match format"

# 3. Ships inert: the shipped default is an empty list, so nothing changes
#    for an adopter who never opts in.
run_case "empty list blocks (default)" \
  '[]' "openfga/vscode-ext" 2 "doesn't match format"

# 4. The safety rail: a repo in BOTH the list and the registry is governed,
#    so the exemption must not apply. Without this, adding a managed project
#    to the list would quietly disable title validation for governed work.
run_case "registry wins over the list" \
  '["fork-org/governed-app"]' "fork-org/governed-app" 2 "doesn't match format" "fork-org/governed-app"

# 5. Slugs are compared case-insensitively, as elsewhere in this hook.
run_case "case-insensitive slug match" \
  '["OpenFGA/VSCode-Ext"]' "openfga/vscode-ext" 0 "external_contributions"

# 6. The exemption is keyed on an explicit target. With no --repo there is no
#    external target to match, so normal validation applies.
run_case "no --repo means no exemption" \
  '["openfga/vscode-ext"]' "" 2 "doesn't match format"

# --- #1451 B2: every registry shape must win over the list ----------------
# The first version matched `repo: x` and a block `repos:` list only, so an
# inline list or a trailing comment silently lost the rail.
run_case "registry wins — trailing comment" \
  '["fork-org/governed-app"]' "fork-org/governed-app" 2 "doesn't match format" \
  "fork-org/governed-app" "comment"
run_case "registry wins — inline repos list" \
  '["fork-org/governed-app"]' "fork-org/governed-app" 2 "doesn't match format" \
  "fork-org/governed-app" "inline"
run_case "registry wins — block repos list" \
  '["fork-org/governed-app"]' "fork-org/governed-app" 2 "doesn't match format" \
  "fork-org/governed-app" "block"

# --- #1451 B1: an ambiguous target must fail closed -----------------------
# CMD_REPO comes from a quote-blind parser, so a listed slug inside the title
# or body can be read as the target. The real destination would then be the
# governed cwd repo, with the title check removed. Fail closed instead.
run_case "listed slug in the title, no --repo flag" \
  '["openfga/vscode-ext"]' "" 2 "doesn't match format" "" "scalar" \
  'gh pr create --title "fix: port --repo openfga/vscode-ext flag" --body-file BODY_FILE'
run_case "two --repo tokens is ambiguous" \
  '["openfga/vscode-ext"]' "" 2 "doesn't match format" "" "scalar" \
  'gh pr create --repo fork-org/governed-app --title "t" --body-file BODY_FILE --repo openfga/vscode-ext'
# The mirror of the case above: once quoted spans are blanked, a slug that is
# merely MENTIONED in the title cannot be mistaken for the target, and a real
# --repo flag still grants the exemption. Asserting this keeps the B1 fix from
# being over-tightened into refusing legitimate commands.
run_case "slug mentioned in the title does not defeat a real flag" \
  '["openfga/vscode-ext"]' "" 0 "external_contributions" "" "scalar" \
  'gh pr create --repo openfga/vscode-ext --title "sync openfga/vscode-ext docs" --body-file BODY_FILE'

# --- #1451 B3: a plain upstream branch name must be accepted --------------
# The branch ticket-ID check refused a listed target until it was gated too.
# The original test passed only because its fixture branch happened to carry a
# framework ticket ID.
run_case "plain branch name on a listed target" \
  '["openfga/vscode-ext"]' "openfga/vscode-ext" 0 "external_contributions" \
  "" "scalar" "" "fix-tuple-merge"
run_case "plain branch name still blocked when unlisted" \
  '[]' "openfga/vscode-ext" 2 "missing ticket ID" \
  "" "scalar" "" "fix-tuple-merge"

echo
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
