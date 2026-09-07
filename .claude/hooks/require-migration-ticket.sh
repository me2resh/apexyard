#!/bin/bash
# PreToolUse hook on Write/Edit/MultiEdit: when the target path looks like a
# database migration file, enforce the migration-ticket-first rule.
#
# Enforces `.claude/rules/workflow-gates.md` gate 4a (migration) —
# "any edit to migration paths requires a labelled migration ticket +
# linked migration AgDR". Backs up the `/migration` skill: skill creates
# the ticket + AgDR; this hook refuses to let writes happen without them.
#
# Three gates in order:
#
#   G1. Active ticket marker exists (same resolution as
#       require-active-ticket.sh — per-project first, then fallback).
#   G2. The referenced tracker issue is OPEN and carries the migration
#       label (default "migration", overridable per project).
#   G3. The issue body references an AgDR at
#       `docs/agdr/AgDR-\d+-.*migration.*\.md`.
#
# If any gate fails, block with a message pointing at `/migration`.
#
# Pass-through (exit 0) paths:
#   - FILE_PATH doesn't match any migration-path pattern
#   - FILE_PATH is under .claude/, docs/, projects/*/docs/, any *.md
#     (meta / docs edits don't need a migration ticket even on paths
#     that look migration-ish)
#   - Any *.example file (migration templates in golden-paths/ etc.)
#
# Path patterns are overridable per project via
# `.claude/project-config.json`:
#
#   {
#     "migration_paths": ["src/db/**", "db/migrations/**"],
#     "migration_label": "database"
#   }
#
# The config is read from `<ops_root>/.claude/project-config.json` if
# present, otherwise defaults below apply.
#
# Pass 1 examines ALL write targets for unresolvability, not just the first
# (apexyard#886, order-independence restored on PR #1180). Pass 2's SELECTION
# is first-match, exactly as dev -- judging every target against its own
# governing ticket is me2resh/apexyard#1182, not this change. A Bash
# command can name more than one write target (`echo x > /tmp/scratch.sql
# && echo y > db/migrations/002_add.sql`). Judging only the first target
# let a command whose first target wasn't migration-shaped slip a later,
# genuinely migration-shaped target past this gate entirely. See the
# target-resolution loop below (after is_migration_path is defined) for
# how every extracted target gets checked.

# Exempt meta / docs / example files — these never need a migration
# ticket regardless of path. Applied PER TARGET (not just once against
# the first extracted target) so a meta-exempt target can't shadow a
# genuinely migration-shaped target named later in the same command.
_rmt_is_meta_exempt() {
  case "$1" in
    */.claude/*|*/.claude|*/docs/*|*/docs) return 0 ;;
    *.md|*.example) return 0 ;;
  esac
  # Note: `*/projects/*/docs/*` is subsumed by `*/docs/*` above (shell case
  # `*` crosses `/`), so no separate arm is needed.
  return 1
}

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
# NOTE: the harness-supplied `.cwd` is deliberately NOT read. Rounds 3-8 joined
# relative write targets to it, validated as absolute-and-existing. Security
# review found the fail-open in round 9: `.cwd` is fixed when the tool call is
# FORMED, so it cannot see a `cd` inside the command.
#
#   cd <ws>/workspace/other && cat > ./migrations/1.sql   with .cwd = <ws>/workspace/example
#   -> dev BLOCKS (other's ticket governs and fails)
#   -> joined:  ALLOWED against EXAMPLE's ticket, silently
#
# The identical write named absolutely was still blocked, so the verdict
# depended on how the path was spelled and the permissive spelling is the
# ordinary one. That is Failure 1's own signature in a spelling this change
# introduced. Validating that `.cwd` is a real directory does not establish it
# is the directory the write happens in.
#
# Teaching the join about `cd`/`pushd`/`git -C` was rejected: it means deciding
# a gate by pattern-matching shell command text, which AgDR-0104 rules cannot be
# made sound. A relative target is therefore left un-normalised and behaves
# exactly as on `dev`. The question moves to me2resh/apexyard#1182 with the
# shared resolver.
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

# Bash-tool path: if the command writes, collect ALL extractable targets so
# every one can be checked against the migration-path matcher below — not
# just the first (#886). If extraction finds nothing at all (e.g.
# `python -c '…write_text("file"…)…'`), the migration gate is path-specific
# by design and falls outside its scope, same as before this change.
# See me2resh/apexyard#151 + _lib-detect-bash-write.sh for the detector.
BASH_TARGETS=""
if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -z "$COMMAND" ] && exit 0

  HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [ -f "$HOOK_DIR/_lib-detect-bash-write.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOOK_DIR/_lib-detect-bash-write.sh"
    if ! bash_command_appears_to_write "$COMMAND"; then
      exit 0
    fi
    BASH_TARGETS=$(bash_extract_write_targets "$COMMAND")
  else
    # Library missing — fall back to no-op rather than bricking the hook.
    exit 0
  fi

  if [ -z "$BASH_TARGETS" ]; then
    exit 0
  fi
  # Resolved to the gate-worthy target further down, once is_migration_path
  # is defined — see the resolution loop after that function.
  FILE_PATH=""
fi

if [ "$TOOL_NAME" != "Bash" ]; then
  if [ -z "$FILE_PATH" ]; then
    exit 0
  fi
  if _rmt_is_meta_exempt "$FILE_PATH"; then
    exit 0
  fi
fi

# --------- Discover ops root ---------
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

# _resolve_real_path (#1181): shared realpath -m helper, composed after the
# lexical collapse in _rmt_normalise_target below, and used again to
# canonicalise the WORKSPACE_DIR/OPS_ROOT anchors further down. Sourced from
# the single shared definition (Rex finding on PR #1087) rather than a
# private copy -- require-active-ticket.sh already sources the same file.
if [ -f "$HOOK_DIR/_lib-path-resolve.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-path-resolve.sh"
else
  # Deliberate degrade, mirroring require-active-ticket.sh's own handling of
  # the same missing-lib case: this should not happen in a normal clone,
  # since the file is tracked right next to this one. Returning empty here
  # is read by TWO callers, each with its own fallback: the composed
  # _rmt_normalise_target falls back to its lexical-only result, and the
  # OPS_ROOT_REAL/WORKSPACE_DIR_REAL anchor block further down falls back to
  # the raw, uncanonicalised OPS_ROOT/WORKSPACE_DIR (its own `|| ANCHOR="$RAW"`
  # line, not this one). Both degrades land on exactly this gate's pre-#1181
  # behaviour, rather than crashing the hook or exempting a write it should
  # still gate.
  _resolve_real_path() { return 0; }
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
OPS_ROOT=""
if [ -n "$REPO_ROOT" ]; then
  if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOOK_DIR/_lib-ops-root.sh"
    OPS_ROOT=$(resolve_ops_root "$REPO_ROOT")
  else
    r="$REPO_ROOT"
    while [ -n "$r" ] && [ "$r" != "/" ]; do
      if [ -f "$r/.apexyard-fork" ]; then
        OPS_ROOT="$r"
        break
      fi
      if [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; then
        OPS_ROOT="$r"
        break
      fi
      parent=$(dirname "$r"); [ "$parent" = "$r" ] && break; r="$parent"
    done
  fi
fi
MARKER_HOME="${OPS_ROOT:-$REPO_ROOT}"
MARKER_HOME="${MARKER_HOME:-.}"

# Resolve the workspace dir (defaults to $OPS_ROOT/workspace; v2
# split-portfolio adopters point at the private sibling repo).
WORKSPACE_DIR="$OPS_ROOT/workspace"

# Which managed project governs this path? Empty means "none" -- the ops-level
# marker answers. Extracted from Gate 1 in round 6 so pass 2 can ask it of EVERY
# matching target rather than only the one it picked first (see the loop below).
#
# Compares against the CANONICALISED anchors (#1181) -- WORKSPACE_DIR_REAL /
# OPS_ROOT_REAL, computed once above, not the raw WORKSPACE_DIR / OPS_ROOT --
# so `p` needs to already be a real, symlink-resolved path for this match to
# be meaningful. The Bash-target caller gets that from _rmt_normalise_target;
# an Edit/Write `file_path` is compared as received (see that function's own
# docstring for why the two tool paths are scoped differently).
_rmt_project_for_path() {
  local p="$1" proj="" tail
  if [ -n "$WORKSPACE_DIR_REAL" ]; then
    case "$p" in
      "$WORKSPACE_DIR_REAL"/*)
        tail="${p#"$WORKSPACE_DIR_REAL"/}"
        proj="${tail%%/*}"
        ;;
    esac
  fi
  if [ -z "$proj" ] && [ -n "$OPS_ROOT_REAL" ]; then
    case "$p" in
      "$OPS_ROOT_REAL"/workspace/*)
        tail="${p#"$OPS_ROOT_REAL"/workspace/}"
        proj="${tail%%/*}"
        ;;
    esac
  fi
  printf '%s' "$proj"
}

# Which active-ticket marker governs this path? Mirrors the three-tier lookup in
# require-active-ticket.sh (#41 + #513): tier 0 per-worktree, tier 1
# per-project, tier 2 ops fallback. Extracted in round 7 so pass 2 can ask the
# question that actually decides the gate -- WHICH MARKER governs -- of every
# matching target, instead of asking which project and hoping the two agree.
# Defined here, below the roots it reads, rather than above them.
_rmt_marker_for_path() {
  local p="$1" proj marker="" wt safe _fdir _gd _gcd
  proj=$(_rmt_project_for_path "$p")

  if [ -n "$proj" ]; then
    # Tier 0 worktree detection -- identical to require-active-ticket.sh: env
    # var, else LINKED-worktree check via absolute git-dir vs common-dir.
    wt="${CLAUDE_WORKTREE_BRANCH:-}"
    if [ -z "$wt" ]; then
      _fdir=$(dirname "$p")
      _gd=$(git -C "$_fdir" rev-parse --absolute-git-dir 2>/dev/null)
      _gcd=$(git -C "$_fdir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
      if [ -n "$_gd" ] && [ "$_gd" != "$_gcd" ]; then
        wt=$(git -C "$_fdir" branch --show-current 2>/dev/null)
      fi
    fi
    if [ -n "$wt" ]; then
      safe="${wt//\//__}"
      if [ -f "$MARKER_HOME/.claude/session/tickets/$proj/$safe" ]; then
        marker="$MARKER_HOME/.claude/session/tickets/$proj/$safe"
      fi
    fi
  fi

  if [ -z "$marker" ] && [ -n "$proj" ] && [ -f "$MARKER_HOME/.claude/session/tickets/$proj" ]; then
    marker="$MARKER_HOME/.claude/session/tickets/$proj"
  elif [ -z "$marker" ] && [ -f "$MARKER_HOME/.claude/session/current-ticket" ]; then
    marker="$MARKER_HOME/.claude/session/current-ticket"
  fi

  printf '%s' "$marker"
}

if [ -n "$OPS_ROOT" ] && [ -f "$HOOK_DIR/_lib-portfolio-paths.sh" ] && [ -f "$HOOK_DIR/_lib-read-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-read-config.sh"
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-portfolio-paths.sh"
  resolved_ws=$(portfolio_workspace_dir 2>/dev/null)
  if [ -n "$resolved_ws" ]; then
    WORKSPACE_DIR="$resolved_ws"
  fi
fi

# Canonicalise the boundary anchors with pwd -P (#1181), mirroring
# require-active-ticket.sh's own anchor canonicalisation (#883). Every
# containment check in _rmt_project_for_path below compares a resolved
# target against these two -- a non-canonical anchor can miss a real match:
# on macOS /tmp is itself a symlink to /private/tmp, so the same migration
# file addressed through either spelling must land on the same marker.
# Computed once, here, after WORKSPACE_DIR is final, rather than inside
# _rmt_project_for_path on every call.
#
# Uses _resolve_real_path -- NOT a `[ -d "$X" ]` existence guard -- and MUST
# keep doing so. An earlier version of this block only canonicalised when
# the directory already existed on disk, and left the anchor EMPTY
# otherwise. `_rmt_project_for_path`'s first branch is skipped on an empty
# anchor, so the moment `$WORKSPACE_DIR` had not been created yet -- the
# ordinary shape for a fresh split-portfolio v2 sibling repo, or any
# `.portfolio.workspace_dir` override, and equally for a dangling symlink,
# since `[ -d ]` follows symlinks and reports false for a broken one -- the
# gate silently stopped identifying the governing project and fell through
# to the tier-2 ops-level marker instead. That is #1137's cross-repo
# authorisation hole on a new path: a write into project `alpha` gets
# judged against the ops fallback ticket instead of alpha's own, and an
# ops ticket that happens to be a valid open migration ticket approves it
# with no warning. `_resolve_real_path` has `realpath -m` semantics -- it
# canonicalises an absent path by walking to the nearest EXISTING ancestor
# and re-appending the missing tail, so it never needs the target to exist
# -- which is exactly why `_rmt_normalise_target` below already uses it
# instead of an existence check. The anchors must use the same helper for
# the same reason: a migration write into a not-yet-created project
# workspace is the common case, not the edge case, and the gate must not
# go permissive on it. The `|| ANCHOR="$RAW"` fallback below only fires
# when `_resolve_real_path` itself is unavailable (see the missing-library
# degrade above) or cannot stat even "/" -- it still prefers the raw,
# uncanonicalised anchor over an empty one, for the same reason.
OPS_ROOT_REAL=""
if [ -n "$OPS_ROOT" ]; then
  OPS_ROOT_REAL="$(_resolve_real_path "$OPS_ROOT")"
  [ -n "$OPS_ROOT_REAL" ] || OPS_ROOT_REAL="$OPS_ROOT"
fi
WORKSPACE_DIR_REAL=""
if [ -n "$WORKSPACE_DIR" ]; then
  WORKSPACE_DIR_REAL="$(_resolve_real_path "$WORKSPACE_DIR")"
  [ -n "$WORKSPACE_DIR_REAL" ] || WORKSPACE_DIR_REAL="$WORKSPACE_DIR"
fi

# --------- Load project-config overrides ---------
MIGRATION_LABEL="migration"
CUSTOM_PATHS=""
PCONFIG="$MARKER_HOME/.claude/project-config.json"
if [ -f "$PCONFIG" ] && command -v jq >/dev/null 2>&1; then
  label=$(jq -r '.migration_label // empty' "$PCONFIG" 2>/dev/null)
  [ -n "$label" ] && MIGRATION_LABEL="$label"
  CUSTOM_PATHS=$(jq -r '.migration_paths // [] | join("\n")' "$PCONFIG" 2>/dev/null)
fi

# --------- Does this path look like a migration? ---------
#
# Defaults cover the common tool / convention set. Patterns use shell
# glob semantics (`*` crosses `/` inside case). Add to this list sparingly
# — false positives on non-migration files block productive edits.
is_migration_path() {
  local path="$1"

  # Project-configured patterns take precedence if any
  if [ -n "$CUSTOM_PATHS" ]; then
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      # SC2254: unquoted expansion is intentional — the project-configured
      # pattern should be interpreted as a glob, not compared literally.
      # shellcheck disable=SC2254
      case "$path" in
        $pat) return 0 ;;
      esac
    done <<< "$CUSTOM_PATHS"
    # When custom patterns are set, don't fall through to defaults —
    # projects that override are saying "only these paths"
    return 1
  fi

  # Default patterns.
  # Note: shell case `*` crosses `/`, so `*/migrations/*.sql` already covers
  # nested paths like `*/migrations/<sub>/file.sql` — no separate arm needed.
  case "$path" in
    # SQL migrations anywhere under a `migrations/` directory
    */migrations/*.sql) return 0 ;;
    # `migrate-*.ts` / `.js` / `.py` / `.sql` anywhere
    */migrate-*.ts|*/migrate-*.js|*/migrate-*.py|*/migrate-*.sql) return 0 ;;
    # Prisma
    */prisma/schema.prisma|*/prisma/migrations/*) return 0 ;;
    # TypeORM (typical convention)
    */src/migrations/*.ts|*/src/migrations/*.js) return 0 ;;
    # Alembic
    */alembic/versions/*.py) return 0 ;;
    # Rails / ActiveRecord
    */db/migrate/*.rb) return 0 ;;
    # Generic — any file immediately under a `migrations/` directory, any extension
    */migrations/*) return 0 ;;
  esac
  return 1
}

# --------- Resolve which target (if any) is migration-shaped ---------
# #886: for a Bash command, check EVERY extracted target — not just the
# first — skipping any that are meta-exempt, and gate on the first one
# that matches a migration-path pattern. For a non-Bash tool call there is
# only ever the one FILE_PATH (already meta-exemption-checked above).

# _rmt_is_unresolvable TARGET (#1159)
# True when the target carries a shell construct the hook cannot expand
# without executing the command: a variable (`$V`, `${V}`), a command
# substitution (`$(…)`), or a backtick. These are the shapes whose real path
# is unknowable here. `~` and relative paths are deliberately NOT listed —
# those ARE resolvable, and _rmt_normalise_target below resolves them.
_rmt_is_unresolvable() {
  case "$1" in
    *'$'*|*'`'*) return 0 ;;
  esac
  # A relative target with no usable cwd is NOT refused here, deliberately.
  # Refusing it would newly block writes that every prior version allowed —
  # the bypass pressure this gate can least afford. Such a target is simply
  # left un-normalised below, so it behaves exactly as it did before this
  # change: it reaches marker resolution unresolved. That is a real remaining
  # gap -- a live instance of Failure 1, the wrong-marker fallthrough this
  # ticket is about. It is recorded in AgDR-0131's known-gap list and owned by
  # me2resh/apexyard#1182, which fixes it through the shared resolver. It is
  # NOT fixed here: the round-3..8 attempt to fix it (joining the harness
  # `.cwd`) was removed in round 9 after security review found it approved a
  # write in one project against another project's ticket.
  return 1
}

# _rmt_normalise_target TARGET
# Absolutise and canonicalise a resolvable target so the migration matcher and
# the project-prefix check see the real path. Composes TWO passes (#1181):
# lexical collapse (`//`, `/./`, `/x/../`), then `_resolve_real_path` from
# `_lib-path-resolve.sh` (realpath -m semantics -- walks to the first
# existing ancestor, `pwd -P`s it, re-appends the absent tail verbatim).
# Lexical MUST run first: `_resolve_real_path` re-appends its absent tail
# VERBATIM, so a dot-segment inside a still-absent tail would survive
# uncollapsed if resolution ran on the raw string. Without both passes,
# `~/…`, a relative `workspace/<p>/…`, `/./` `//` `/../` spellings, AND a
# target reached through a symlinked ancestor all fail the workspace prefix
# test and silently fall through to the tier-2 ops marker — the same
# Failure-1 signature this ticket is about, in a different spelling.
#
# Scoped to the Bash-target path only. On Edit/Write, `file_path` is the
# literal string the tool reported and is never normalised at all -- that
# scope boundary is unchanged by #1181 and is pinned in AgDR-0131.
#
# Relative targets are NOT absolutised. Rounds 3-8 joined them to the
# harness-supplied `.cwd`; round 9 removed that (see the note near the top of
# this file) because `.cwd` is fixed when the tool call is formed and cannot
# see a `cd` inside the command. A relative target is therefore left untouched
# and resolves exactly as on `dev`.
_rmt_normalise_target() {
  local t="$1" lexical resolved
  # SC2088: the quoted `~` here is a case PATTERN matching the literal two
  # characters the extractor returned — we are detecting an unexpanded tilde
  # in someone else's command text, not writing one we want the shell to
  # expand. Expansion is what the branch body does, explicitly, via $HOME.
  # shellcheck disable=SC2088
  case "$t" in
    '~')    t="$HOME" ;;
    '~/'*)  t="$HOME/${t#\~/}" ;;
    # ~user, ~+, ~- and every other ~-prefixed form fall through to the
    # catch-all below, which leaves them untouched. They had their own arm
    # while a cwd join existed (round 4) -- what they expand to depends on the
    # passwd database or the CALLER shell's $PWD/$OLDPWD, none of which this
    # process can read, so joining them yielded a path bash never writes to.
    # With the join gone in round 9 that arm became identical to the
    # catch-all, and a distinction no behaviour can observe is worth deleting
    # rather than testing.
    /*)     ;;
    # Relative: left untouched. There is no trustworthy base to join against.
    # The hook process's cwd is not the Bash tool's cwd, and the harness `.cwd`
    # cannot see a `cd` inside the command (see the note near the top of this
    # file). Either join fabricates a path that looks real and can resolve into
    # an unrelated project — the exact wrong-marker failure this gate exists to
    # stop. Un-normalised, the target behaves exactly as on `dev`.
    *)      ;;
  esac

  # If it is STILL relative, there was no trustworthy base. Return it exactly
  # as received. The canonicaliser below emits a leading "/" unconditionally,
  # so running it here would turn `migrations/001.sql` into
  # `/migrations/001.sql` — inventing an absolute path that never existed and
  # that can match a workspace prefix. That is the same fabrication the join
  # was removed to avoid, just relocated; leaving early is what actually makes
  # the un-normalised path behave as it did before this change.
  case "$t" in
    /*) ;;
    *)  printf '%s' "$t"; return 0 ;;
  esac
  # Pass 1 -- canonicalise lexically: collapse `//`, drop `/./`, resolve
  # `/x/../`. Pure string manipulation; cannot see a symlink.
  #
  # An earlier version of this comment said "lexical (not realpath) so a
  # not-yet-created migration file still resolves". That reason is FALSE and
  # was withdrawn in AgDR-0131: `_resolve_real_path` has `realpath -m`
  # semantics -- it walks up to the first existing ancestor, `pwd -P`s it,
  # and re-appends the absent tail, so it resolves an absent file on its own.
  # The real reason lexical runs first is composition order, not necessity:
  # `_resolve_real_path` re-appends its absent tail VERBATIM, so a
  # dot-segment inside a still-absent tail needs collapsing before that
  # function ever sees it, or it survives uncollapsed in the output.
  # (Tariq, round 5 on PR #1180; composed in #1181.)
  lexical=$(printf '%s' "$t" | awk -F/ '{
    n = 0
    for (i = 1; i <= NF; i++) {
      if ($i == "" || $i == ".") continue
      if ($i == "..") { if (n > 0) n--; continue }
      out[++n] = $i
    }
    s = ""
    for (i = 1; i <= n; i++) s = s "/" out[i]
    print (s == "" ? "/" : s)
  }')

  # Pass 2 (#1181) -- resolve what pass 1 cannot: a symlink anywhere in an
  # EXISTING ancestor. `_resolve_real_path` walks to the first existing
  # ancestor, `pwd -P`s it (following any symlink along the way), and
  # re-appends whatever tail does not exist yet -- so a not-yet-created
  # migration file still resolves, and a target reached through a symlinked
  # ancestor lands on the SAME marker the kernel's write is actually
  # governed by, instead of whichever project the lexical spelling happens
  # to name.
  resolved=$(_resolve_real_path "$lexical")
  if [ -z "$resolved" ]; then
    # _resolve_real_path returns empty only when even "/" can't be stat'd
    # (its own header comment: "should not happen for a well-formed absolute
    # path"), or when the shared lib failed to load (see the degrade near
    # the top of this file). Fail toward the lexical form rather than an
    # empty RESOLVED_TARGET: the caller reads empty as "no migration-shaped
    # target" and would let the write through UNGATED.
    printf '%s' "$lexical"
    return 0
  fi

  # A wholly absent root -- none of the target's ancestors exist all the way
  # up to "/" -- makes _resolve_real_path emit a doubled leading slash: it
  # walks to dir="/", `pwd -P`s that to "/", then appends the absent tail
  # with its own separator ("/" + "/" + tail). Squash that one specific
  # artifact so the result still compares cleanly against a real anchor.
  case "$resolved" in
    //*) resolved="/${resolved#//}" ;;
  esac
  printf '%s' "$resolved"
}

if [ "$TOOL_NAME" = "Bash" ]; then
  # Pass 1 (#1159, Hakim's ordering finding on PR #1180): examine EVERY target
  # for unresolvability BEFORE picking one to gate on. The migration-shaped
  # check below `break`s on its first match, so a compliant literal target
  # placed first would otherwise smuggle a later unresolvable one straight
  # past this gate. Refusal must not depend on argument order.
  #
  # Scoped to targets whose literal text is still migration-shaped: the
  # `migrations/` segment survives an unexpanded prefix (`$WD/app/migrations/x`),
  # so this refuses the writes this gate governs without refusing every command
  # that merely happens to redirect into some unrelated `$LOG`.
  while IFS= read -r _tgt; do
    [ -z "$_tgt" ] && continue
    _rmt_is_meta_exempt "$_tgt" && continue
    # Selection asks the RAW spelling, here and in pass 2 -- one question, one
    # spelling, everywhere. Normalisation serves RESOLUTION only.
    #
    # Rounds 5-8 each moved selection further into territory dev never runs,
    # and three of the four produced a defect. Normalisation-in-selection was
    # never part of fixing #1159: it arrived as a side effect, widened the set
    # of writes this gate governs beyond the ticket, and generated two of the
    # eight defects. (b1+, architecture review round 8.)
    #
    # The property this buys is checkable rather than enumerable: THE SET OF
    # WRITES THIS GATE GOVERNS IS IDENTICAL TO DEV'S; WHAT CHANGED IS WHICH
    # TICKET ANSWERS. It is established by measuring `dev` against this HEAD
    # over the same command corpus, and pinned by enumerated cases, each
    # mutation-checked.
    #
    # An earlier version of this comment cited a differential test as enforcing
    # it. That test was removed in round 9: it compared `is_migration_path`
    # extracted from two blobs that are byte-identical, so it compared a
    # predicate to itself and never invoked a selection pass -- and it never ran
    # in CI at all (shallow checkout, silent skip). The claim was the reverse of
    # what was measured. Enforcing the property properly is carried into
    # me2resh/apexyard#1182; the CI half is me2resh/apexyard#1183.
    if _rmt_is_unresolvable "$_tgt" && is_migration_path "$_tgt"; then
      cat >&2 <<MSG
BLOCKED: This migration write target could not be resolved.

  target: $_tgt

The path contains a shell variable, command substitution, or backtick that
the gate cannot expand without running the command. It therefore cannot tell
which project — and so which ticket — governs the write, and it will not
guess. Guessing here means evaluating against whichever ticket happens to be
set elsewhere, which is how the wrong ticket silently approves a migration.

Use a literal ABSOLUTE path for migration writes. A \`~/\` path is fine — those
are expanded. Only unexpandable shell constructs are refused here.

A relative path is not refused either, but be aware it is not resolved: this
gate cannot tell which project a relative target lands in, so it falls back to
the ops-level ticket. That is a known gap (me2resh/apexyard#1182), not a
recommendation — an absolute path is governed by the ticket that actually owns
the write.

See me2resh/apexyard#1159 and .claude/rules/workflow-gates.md section
"Migration Gate (3a)".
MSG
      exit 2
    fi
  done <<< "$BASH_TARGETS"

  # Pass 2: select on the RAW spelling exactly as dev does, then normalise the
  # target that was selected. Selection set identical to dev's by construction;
  # resolution is what this change fixes.
  #
  # The multi-target accumulator and its refusal are GONE, deliberately. Rounds
  # 6, 7 and 8 each produced a defect there, every one an adjacent case escaping
  # the same single-representative election, and round 8 tripped the stopping
  # rule this record adopted. That work moves to me2resh/apexyard#1182, which
  # dissolves the election rather than improving it. The consequence is stated
  # plainly in AgDR-0131: the two-project order-dependent fail-open REMAINS,
  # inherited unchanged from dev, and #1159 stays open for it.
  RESOLVED_TARGET=""
  while IFS= read -r _tgt; do
    [ -z "$_tgt" ] && continue
    _rmt_is_meta_exempt "$_tgt" && continue
    if is_migration_path "$_tgt"; then
      RESOLVED_TARGET=$(_rmt_normalise_target "$_tgt")
      break
    fi
  done <<< "$BASH_TARGETS"

  if [ -z "$RESOLVED_TARGET" ]; then
    # No target in this command matches a migration path — other hooks
    # handle the standard ticket check.
    exit 0
  fi
  FILE_PATH="$RESOLVED_TARGET"
elif ! is_migration_path "$FILE_PATH"; then
  # Not a migration file — other hooks handle the standard ticket check.
  exit 0
fi

# --------- Gate 1: active ticket marker ---------
# Reuse the #41 resolution: per-project marker if FILE_PATH is under the
# resolved workspace dir, otherwise the ops-level fallback. The resolved
# workspace dir may live in the private sibling repo for v2 adopters.
PROJECT=$(_rmt_project_for_path "$FILE_PATH")

# Three-tier marker lookup, shared with pass 2 so the two cannot diverge.
MARKER=$(_rmt_marker_for_path "$FILE_PATH")

if [ -z "$MARKER" ]; then
  cat >&2 <<MSG
BLOCKED: No active ticket set — and this file looks like a database migration.

Migrations need a dedicated labelled ticket + AgDR, not just any ticket.
Run /migration to create both in one guided flow:

  /migration${PROJECT:+ $PROJECT}

Then /start-ticket <owner/repo>#<number> to activate the new ticket for
this session, and retry the edit.

Path matched migration pattern: $FILE_PATH
MSG
  exit 2
fi

# --------- Parse marker for repo + issue number ---------
TICKET_REPO=$(grep -E '^repo=' "$MARKER" | head -1 | cut -d= -f2-)
TICKET_NUM=$(grep -E '^number=' "$MARKER" | head -1 | cut -d= -f2-)

if [ -z "$TICKET_REPO" ] || [ -z "$TICKET_NUM" ]; then
  cat >&2 <<MSG
BLOCKED: Active ticket marker at $MARKER is missing \`repo=\` or
\`number=\` — can't verify migration discipline without those fields.

Re-run /start-ticket to rewrite the marker cleanly, or /migration to
create a fresh migration ticket.
MSG
  exit 2
fi

# --------- Shape-guard marker-derived values before the tracker call ---------
# TICKET_NUM / TICKET_REPO come from the session-local active-ticket marker via
# `cut -d= -f2-`, which keeps everything after the first `=` — so a marker line
# like `number=42; touch X` yields TICKET_NUM='42; touch X'. Gate 2 below feeds
# both values into `tracker_view`, which builds its command by string-substituting
# {id}/{owner_repo} into a template and running `eval` (_lib-tracker.sh). Without a
# shape check that is a command-injection sink: the base (pre-#755) hook used direct
# argv (`gh issue view "$TICKET_NUM" --repo "$TICKET_REPO"`), which was
# injection-immune; routing through the tracker abstraction reintroduces the eval.
# The sibling caller `validate-pr-create.sh` reaches the same eval only AFTER its
# ticket number passed a shape check — this hook must not skip the equivalent guard.
# Whitelist a conservative charset (no shell metacharacters): ticket IDs like 42,
# #42, GH-42, ABC-123; owner/repo slugs (incl. GitLab nested groups) of letters,
# digits, `.`, `_`, `-`, `/`. Anything else fails closed. (#755 security review;
# defence-in-depth alongside the printf %q quoting _tracker_substitute now applies.)
if ! printf '%s' "$TICKET_NUM" | grep -qE '^#?[A-Za-z0-9_-]+$'; then
  cat >&2 <<MSG
BLOCKED: Active ticket marker at $MARKER has a malformed \`number=\` value.
Only ticket IDs like 42, #42, GH-42, or ABC-123 are allowed (no shell
metacharacters). Re-run /start-ticket to rewrite the marker cleanly.
MSG
  exit 2
fi
if ! printf '%s' "$TICKET_REPO" | grep -qE '^[A-Za-z0-9._/-]+$'; then
  cat >&2 <<MSG
BLOCKED: Active ticket marker at $MARKER has a malformed \`repo=\` value.
Only owner/repo slugs (letters, digits, \`.\`, \`_\`, \`-\`, \`/\`) are
allowed (no shell metacharacters). Re-run /start-ticket to rewrite the
marker cleanly.
MSG
  exit 2
fi

# --------- Gate 2: issue is open + has migration label ---------
# Resolve the ticket through the tracker abstraction (_lib-tracker.sh) so this
# gate works for every configured tracker — GitHub (gh), GitLab (glab), Linear,
# Jira, Asana, custom — not just GitHub. Before #755 this hardcoded
# `gh issue view`, which returned empty for GitLab-tracked projects and
# false-blocked every migration edit even when the GitLab ticket was valid.
# tracker_view emits the normalised {state,title,url,labels,body} shape
# regardless of tracker; labels come back as a flat string array and body is
# populated for gh/glab/jira/linear/asana — every built-in kind the migration
# gate reads (#761 widened body beyond the original gh/glab of #755).
if [ -f "$HOOK_DIR/_lib-tracker.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-tracker.sh"
fi

# Resolve the tracker kind for the TICKET's repo (per-project registry override
# wins over the global config; see #670). tracker.kind=none has no queryable
# tracker, so existence / label / AgDR can't be verified online — per the #755
# Expected behaviour, skip the online gates (Gate 1 already proved an active
# ticket marker exists) and allow the edit, operator-trusted. The skip is
# printed to stderr so it is auditable, never silent.
TICKET_KIND="gh"
if command -v tracker_kind >/dev/null 2>&1; then
  TICKET_KIND=$(tracker_kind "$TICKET_REPO" 2>/dev/null)
  [ -n "$TICKET_KIND" ] || TICKET_KIND="gh"
fi
if [ "$TICKET_KIND" = "none" ]; then
  echo "note: tracker.kind=none for ${TICKET_REPO} — skipping migration label/AgDR verification (operator-trusted; #755)." >&2
  exit 0
fi

if command -v tracker_view >/dev/null 2>&1; then
  ISSUE_JSON=$(tracker_view "$TICKET_NUM" "$TICKET_REPO" 2>/dev/null)
else
  # Library missing (should not happen in a real fork) — fall back to gh so the
  # gate still functions on a GitHub tracker rather than bricking, normalising
  # to the same shape tracker_view emits (labels as a flat string array).
  ISSUE_JSON=$(gh issue view "$TICKET_NUM" --repo "$TICKET_REPO" --json state,title,url,labels,body 2>/dev/null \
    | jq -c '{state,title,url,labels:((.labels // []) | map(.name)),body}' 2>/dev/null)
fi

if [ -z "$ISSUE_JSON" ]; then
  cat >&2 <<MSG
BLOCKED: Could not fetch ${TICKET_REPO}#${TICKET_NUM} from the configured
tracker (kind: ${TICKET_KIND}). Network / auth problem? Or the issue
doesn't exist?

The migration gate is fail-closed by design — a high-blast-radius change is
not allowed against a ticket the framework cannot verify. (This is stricter
than the PR-create / commit-ref existence checks, which fall back to
shape-only when a non-gh CLI is unreachable, per #501 — a migration edit
warrants a hard stop.) If your tracker is untracked, set tracker.kind=none.

Check your tracker auth (e.g. gh auth status / glab auth status), or run
/migration to create a new ticket.
MSG
  exit 2
fi

STATE=$(echo "$ISSUE_JSON" | jq -r '.state // empty')
# Normalised labels are a flat string array, so a direct membership test.
HAS_LABEL=$(echo "$ISSUE_JSON" | jq -r --arg L "$MIGRATION_LABEL" '.labels | index($L) != null')
BODY=$(echo "$ISSUE_JSON" | jq -r '.body // empty')

# Closed-state recognition is tracker-agnostic — same vocabulary as
# validate-pr-create.sh / verify-commit-refs.sh: gh/glab "CLOSED", Linear
# "Done", Jira "Resolved", Asana "Closed", etc.
STATE_LC=$(echo "$STATE" | tr '[:upper:]' '[:lower:]')
case "$STATE_LC" in
  closed|done|cancelled|canceled|resolved|completed)
    cat >&2 <<MSG
BLOCKED: Active ticket ${TICKET_REPO}#${TICKET_NUM} is "$STATE", not open.
Migration files require an OPEN labelled ticket. Run /migration to create
a fresh one, or /start-ticket on a different OPEN migration ticket.
MSG
    exit 2 ;;
esac

if [ "$HAS_LABEL" != "true" ]; then
  cat >&2 <<MSG
BLOCKED: Active ticket ${TICKET_REPO}#${TICKET_NUM} does not have the
\`$MIGRATION_LABEL\` label.

Migrations need a dedicated labelled ticket — the label is the signal
that a reviewer should scrutinise rollback plan, downtime, and
cross-service impact before approval.

Two options:
  1. Add the label to the existing ticket if it genuinely is a migration:
       gh issue edit $TICKET_NUM --repo $TICKET_REPO --add-label "$MIGRATION_LABEL"
     Then edit the body to include the migration-shape fields and link an
     AgDR (see /migration output for the body template).
  2. Create a fresh migration ticket + AgDR:
       /migration${PROJECT:+ $PROJECT}
     Then /start-ticket the new ticket and retry.
MSG
  exit 2
fi

# --------- Gate 3: body references a migration AgDR ---------
# The issue body is populated by tracker_view for the gh, glab, jira, linear, and
# asana adapters (see _lib-tracker.sh — #761 widened it beyond the original
# gh/glab of #755). Only the `custom` adapter can leave body empty (unless the
# operator's normalise_jq emits one), so this gate cannot see an AgDR link there
# even when one exists — surface that in the failure message rather than blaming
# the ticket. Adopters on custom can set tracker.kind=none to skip online
# migration verification.
if ! echo "$BODY" | grep -qE 'docs/agdr/AgDR-[0-9]+-[^[:space:]]*migration[^[:space:]]*\.md'; then
  KIND_NOTE=""
  case "$TICKET_KIND" in
    gh|glab|jira|linear|asana) ;;
    *) KIND_NOTE="

NOTE: tracker.kind=${TICKET_KIND} — this gate reads the issue body via
tracker_view, which only populates body for the gh, glab, jira, linear, and
asana adapters. For ${TICKET_KIND} the body may not be fetched, so this check
cannot see an AgDR link even if the ticket has one. Emit body from your
custom normalise_jq, track migrations on a built-in tracker, or set
tracker.kind=none to skip online migration verification." ;;
  esac
  cat >&2 <<MSG
BLOCKED: Active ticket ${TICKET_REPO}#${TICKET_NUM} has the
\`$MIGRATION_LABEL\` label but its body does not reference a migration
AgDR matching \`docs/agdr/AgDR-\\d+-.*migration.*\\.md\`.

A migration-class change needs a paired Agent Decision Record capturing
rollback plan, downtime, cross-service consumers, and observability.

Create one with /migration, or if the AgDR already exists, edit the
ticket body to include a reference to it:

  gh issue edit $TICKET_NUM --repo $TICKET_REPO --body-file <path>

The regex the hook checks is permissive — any occurrence of the AgDR
relative path in the body satisfies gate 3.${KIND_NOTE}
MSG
  exit 2
fi

# All gates passed — allow the edit.
exit 0
