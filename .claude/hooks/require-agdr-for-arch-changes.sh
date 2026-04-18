#!/bin/bash
# PreToolUse hook on `git commit`: when the staged diff touches architecture
# files, require either:
#   (a) an AgDR reference in the commit message (AgDR-NNNN / docs/agdr/AgDR-…), OR
#   (b) a new AgDR file in the staged changes (docs/agdr/AgDR-NNNN-*.md)
#
# Enforces .claude/rules/agdr-decisions.md § "Pre-commit hook warns if
# architecture files changed without an AgDR reference" — which was prose-only
# until this hook shipped.
#
# What counts as "architecture":
#   - infrastructure/**              (terraform, pulumi, cdk, cfn)
#   - *.tf, *.tfvars                 (terraform)
#   - docker-compose*.yml, Dockerfile* (container orchestration)
#   - .github/workflows/**           (CI/CD pipeline changes)
#
# Deliberately NARROW. Dependency bumps (package.json, go.mod, etc.) and API
# schema changes are NOT included — too noisy, not all changes need an AgDR.
# Projects that want a broader list can override via
# .claude/project-config.json `.architecture_paths` (a JSON array of globs).
#
# Multi-line -m messages are handled the same way as verify-commit-refs.sh:
# flatten newlines before sed parsing.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

if ! echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# Get staged files. If nothing is staged, let git commit fail on its own terms.
STAGED=$(git diff --cached --name-only 2>/dev/null)
if [ -z "$STAGED" ]; then
  exit 0
fi

# Default architecture path patterns. Projects can override via project-config.
#
# All patterns are designed to match both root-level files AND monorepo
# subdirectory files. Rex flagged the original anchors in the review of #13 /
# PR #17: ^Dockerfile / ^docker-compose missed backend/Dockerfile etc., which
# is the common layout for real monorepos.
#
# (^|/) = "start of string OR preceded by a slash". This matches:
#   Dockerfile                   ← root
#   backend/Dockerfile           ← monorepo subdir
#   services/api/Dockerfile.prod ← nested subdir
# but NOT:
#   notes-about-Dockerfile.md    ← no slash or start boundary
#
# Why no `infrastructure/` or `terraform/` directory pattern: testing showed
# those match `docs/infrastructure/notes.md` and `src/types/infrastructure/foo.ts`
# as false positives (the word "infrastructure" is ambiguous as a directory
# name — IaC vs library code). Terraform files are caught via `\.tf$` at any
# depth, which is unambiguous. CDK / Pulumi projects that use plain .ts / .py
# files inside an `infrastructure/` directory need to override via
# .architecture_paths in project-config.json.
ARCH_GLOBS='\.tf$
\.tfvars$
(^|/)docker-compose.*\.ya?ml$
(^|/)Dockerfile
^\.github/workflows/'

# Allow project-config to override
if [ -f "${REPO_ROOT}/.claude/project-config.json" ]; then
  CUSTOM=$(jq -r '.architecture_paths // [] | join("|")' "${REPO_ROOT}/.claude/project-config.json" 2>/dev/null)
  if [ -n "$CUSTOM" ] && [ "$CUSTOM" != "null" ]; then
    ARCH_GLOBS="$CUSTOM"
  fi
fi

# Find any staged file that matches an architecture pattern
TOUCHED_ARCH=""
while IFS= read -r FILE; do
  [ -z "$FILE" ] && continue
  while IFS= read -r PATTERN; do
    [ -z "$PATTERN" ] && continue
    if echo "$FILE" | grep -qE "$PATTERN"; then
      TOUCHED_ARCH="${TOUCHED_ARCH}${FILE} "
      break
    fi
  done <<< "$ARCH_GLOBS"
done <<< "$STAGED"

if [ -z "$TOUCHED_ARCH" ]; then
  # No arch files in this commit — nothing to enforce
  exit 0
fi

# An AgDR is required. Check two paths:
#   (1) The staged files include a new AgDR at docs/agdr/AgDR-*.md
#   (2) The commit message references an existing AgDR

# (1) New AgDR file in staged changes?
if echo "$STAGED" | grep -qE '^docs/agdr/AgDR-[0-9]+-.*\.md$'; then
  exit 0
fi

# (2) AgDR reference in commit message?
# Extract the message using the multi-line-safe pattern (flatten first).
COMMAND_FLAT=$(echo "$COMMAND" | tr '\n' ' ')
MSG=""
MSG=$(echo "$COMMAND_FLAT" | sed -nE "s/.*-m[[:space:]]+'([^']*)'.*/\1/p" | head -1)
if [ -z "$MSG" ]; then
  MSG=$(echo "$COMMAND_FLAT" | sed -nE 's/.*-m[[:space:]]+"([^"]*)".*/\1/p' | head -1)
fi
if [ -z "$MSG" ]; then
  MSG_FILE=$(echo "$COMMAND_FLAT" | sed -nE 's/.*(-F|--file)[[:space:]]+([^[:space:]]+).*/\2/p' | head -1)
  if [ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ]; then
    MSG=$(cat "$MSG_FILE")
  fi
fi

if [ -z "$MSG" ]; then
  # Interactive commit — skip (matches verify-commit-refs.sh policy)
  exit 0
fi

if echo "$MSG" | grep -qE 'AgDR-[0-9]+|docs/agdr/AgDR-'; then
  exit 0
fi

# No AgDR reference and no new AgDR file — block
cat >&2 <<MSG_END
BLOCKED: Commit touches architecture files but has no AgDR reference.

Architecture files in this commit:
$(echo "$TOUCHED_ARCH" | tr ' ' '\n' | sed 's/^/  /' | grep -v '^  $')

ApexYard requires an Agent Decision Record (AgDR) for architectural
changes — see .claude/rules/agdr-decisions.md § Enforcement. Every
decision that has trade-offs (infrastructure layout, CI/CD design,
deployment strategy, container topology) must be recorded so future
maintainers can understand why this was chosen over alternatives.

To unblock:

  1. Run the /decide skill to walk through the decision and generate
     an AgDR file at docs/agdr/AgDR-NNNN-{slug}.md
  2. Either:
       - Stage the new AgDR file alongside this commit: git add docs/agdr/AgDR-NNNN-*.md
       OR
       - Reference an existing AgDR in the commit message:
           "... decided by AgDR-0042"
  3. Retry the commit

If the change is TRULY trivial (cosmetic rename, comment fix, whitespace),
amend the commit message to cite the parent ticket explicitly and add
"no AgDR needed: trivial refactor" — and the hook will still block, but
that's the signal to create a minimal AgDR rather than bypass the rule.

Customize which paths count as "architecture" via
.claude/project-config.json \`.architecture_paths\` (JSON array of regex patterns).
MSG_END
exit 2
