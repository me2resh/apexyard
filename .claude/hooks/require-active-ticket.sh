#!/bin/bash
# Blocks Edit/Write/MultiEdit on code paths when no active ticket is set.
# Enforces the ticket-first rule mechanically instead of relying on prose
# in CLAUDE.md, workflows/sdlc.md, or .claude/rules/workflow-gates.md.
#
# Active tickets are declared by the /start-ticket skill. The marker
# layout is three-tier (apexyard#41 + #513):
#
#   ops_root/.claude/session/tickets/<project>/<branch>  ← per-worktree (#513)
#   ops_root/.claude/session/tickets/<project>           ← per-project (#41)
#   ops_root/.claude/session/current-ticket              ← ops-repo / fallback
#
# Resolution order for a given FILE_PATH under ops_root/workspace/<project>/:
#   0. If the file's repo is on a git worktree branch (or CLAUDE_WORKTREE_BRANCH
#      is set), look up tickets/<project>/<safe-branch>. If present → exempt.
#      (Lets parallel agents on the SAME project hold independent tickets.)
#   1. Look up tickets/<project> (a FILE). If present → exempt.
#   2. Fall back to current-ticket. If present → exempt.
#   3. Otherwise, block with instructions.
#
# tickets/<project> is a FILE in single-agent mode, a DIRECTORY in worktree
# mode; the `-f` tests keep tiers 0 and 1 from conflicting.
#
# Ops root is the apexyard fork root (has both onboarding.yaml and
# apexyard.projects.yaml at the top level). It's discovered by walking
# up from the nearest git toplevel; this handles the case where an agent
# worktree or a cloned managed project lives inside the ops tree and
# would otherwise report a nested git root.
#
# Exempt paths (meta / framework / docs — no ticket required):
#   - anything under .claude/
#   - any *.md file (READMEs, CLAUDE.md, rule docs, AgDRs)
#   - anything under docs/
#   - anything under projects/*/docs/ (per-project apexyard docs)
#
# Everything else (source code, config, infra) requires a ticket marker.
#
# Out-of-governance exemption (apexyard#883): a write TARGET entirely
# outside every governed tree (the ops fork AND every registered
# workspace/<project> clone) AND not inside ANY git repository at all is
# outside this gate's jurisdiction — home dotfiles (~/.zshrc), /etc-style
# machine config, /tmp scratch files. See the "Out-of-governance
# exemption" block below for the fail-closed resolution rules (symlinks
# resolved before judging; unresolvable/ambiguous targets stay gated).
#
# ALL write targets are judged, not just the first (apexyard#886): a Bash
# command can name more than one write target (`echo a > /tmp/x; echo b >
# src/app.ts`, `tee /tmp/a src/b.ts`). The gate pipeline below is wrapped
# in a function and invoked ONCE PER EXTRACTED TARGET (see the dispatch
# section at the bottom); the command as a whole only passes if EVERY
# target independently clears the gate. Judging only the first target
# let a command that also names an out-of-governance target FIRST slip an
# in-repo target past a gate that stopped looking after target #1.

# Resolve PATH to its canonical, symlink-free absolute form. Walks up to
# the nearest EXISTING ancestor, physically resolves it (`pwd -P`, which
# follows symlinks), then re-appends any not-yet-created tail literally —
# a tail that doesn't exist yet cannot itself be a symlink. This mirrors
# `realpath -m` without depending on GNU coreutils (not guaranteed present
# on macOS/BSD). Echoes the resolved path, or nothing if even "/" can't be
# stat'd (should not happen for a well-formed absolute path).
#
# Why this matters (#883): without resolving symlinks first, a symlink
# living under $HOME that POINTS INTO a governed tree (e.g.
# ~/link-into-repo → the ops fork) would compare as "outside" the repo
# under a naive string-prefix check, silently bypassing the gate.
_resolve_real_path() {
  local p="$1" dir tail=""
  [ -n "$p" ] || return 0
  dir="$p"
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ ! -e "$dir" ]; do
    if [ -z "$tail" ]; then
      tail="$(basename "$dir")"
    else
      tail="$(basename "$dir")/$tail"
    fi
    dir="$(dirname "$dir")"
  done
  if [ ! -e "$dir" ]; then
    # Nothing on the path exists at all — cannot resolve. Should not
    # happen for an absolute path since "/" always exists.
    return 0
  fi
  if [ -d "$dir" ]; then
    dir="$(cd "$dir" 2>/dev/null && pwd -P)"
  else
    # $dir resolved to an existing FILE (not a directory) partway through
    # the walk — canonicalize its parent and re-append its own basename.
    local parent
    parent="$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P)"
    if [ -n "$parent" ]; then
      dir="$parent/$(basename "$dir")"
    else
      dir=""
    fi
  fi
  [ -n "$dir" ] || return 0
  if [ -n "$tail" ]; then
    printf '%s/%s' "$dir" "$tail"
  else
    printf '%s' "$dir"
  fi
}

# ------------------------------------------------------------------------------
# _ratc_evaluate_target FILE_PATH TOOL_NAME
#
# Runs the full ticket-gate pipeline for ONE candidate write target:
# variable-target exemptions, REPO_ROOT/REL_PATH normalisation, path-prefix
# exemptions, ops-root discovery, the out-of-governance exemption
# (#883/#885), the bootstrap-skill exemption, and marker resolution
# (tier 0 per-worktree / tier 1 per-project / tier 2 ops fallback).
#
# Returns 0 if this target is exempt OR a matching ticket marker is found.
# Returns 2 (and prints a BLOCKED message to stderr) if this target
# requires an active ticket that isn't set.
#
# #886: called ONCE PER EXTRACTED BASH WRITE TARGET by the dispatch section
# below — not just the first. All local state (REPO_ROOT, OPS_ROOT,
# PROJECT, the markers, ...) is scoped to this function so each call is
# independent; nothing leaks between targets.
# ------------------------------------------------------------------------------
_ratc_evaluate_target() {
  local FILE_PATH="$1"
  local TOOL_NAME="$2"

  # Variable target (e.g. `cat > "$VAR"`): the extractor returns the literal
  # shell-variable token. Exempt a temp-dir var, and a BARE whole-target variable
  # (`$CEO`, `${marker}` — unresolvable, in practice a .claude/ scratch path). A
  # variable WITH a concatenated path tail (`$PWD/src/app.ts`, `$D/app.ts`,
  # `$HOME/work/src/x.ts`) is NOT exempt — that path could be tracked source, and
  # the old blanket `$*` exemption let such a write dodge the ticket gate (#582
  # review: fail-open on a security gate). A var+tail target isn't bare and isn't
  # absolute, so it falls through to the ticket gate below and blocks — which is
  # the safe direction. (We deliberately do NOT expand $PWD/$HOME here: that adds
  # nothing for blocking and tripped a /var↔/private/var symlink mismatch.)
  case "$FILE_PATH" in
    '$TMPDIR'/*|'${TMPDIR}'/*|'$TMP'/*|'${TMP}'/*) return 0 ;;  # temp dir → outside the repo
  esac
  # Bare whole-target variable only (no path/extension tail) → exempt.
  if printf '%s' "$FILE_PATH" | grep -qE '^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$'; then
    return 0
  fi

  if [ -z "$FILE_PATH" ] && [ "$TOOL_NAME" != "Bash" ]; then
    return 0
  fi

  # Normalise to repo-relative path when possible.
  #
  # BUG #744 FIX: derive REPO_ROOT from the FILE_PATH's directory, NOT the
  # hook's CWD. The harness can fire with any CWD (e.g. /tmp, the ops root,
  # a totally unrelated directory). Using `git rev-parse --show-toplevel`
  # from the hook process's CWD returns the WRONG root whenever the CWD
  # differs from the file's actual git repo — which breaks the OPS_ROOT
  # walk-up and causes the per-project marker to be missed, blocking edits
  # even when /start-ticket set a valid marker (#744, #745).
  #
  # Resolution order:
  #   1. FILE_PATH is set and absolute: run git in the file's nearest existing
  #      ancestor directory.  Works for new files (dirname of a not-yet-created
  #      path still points at the parent dir).
  #   2. FILE_PATH is set but relative (Bash write-target extracted from the
  #      command): relative paths are relative to the process CWD, so fall
  #      back to the legacy CWD-based git rev-parse — same behaviour as before.
  #   3. FILE_PATH is empty (Bash command, no extractable target): CWD-based
  #      fallback as before.
  local REPO_ROOT="" _fp_dir _wt_gd _wt_gcd _main_root REL_PATH
  if [ -n "$FILE_PATH" ]; then
    case "$FILE_PATH" in
      /*)
        # Absolute path — find the nearest existing ancestor directory.
        # dirname works on non-existent files; the while loop handles the
        # case where the new file's parent dir doesn't exist yet.
        _fp_dir="$(dirname "$FILE_PATH")"
        while [ -n "$_fp_dir" ] && [ "$_fp_dir" != "/" ] && [ ! -d "$_fp_dir" ]; do
          _fp_dir="$(dirname "$_fp_dir")"
        done
        if [ -d "$_fp_dir" ]; then
          REPO_ROOT=$(git -C "$_fp_dir" rev-parse --show-toplevel 2>/dev/null)
          # When the file's repo is a LINKED git worktree the worktree dir
          # inherits the main branch's files — including anchor files like
          # onboarding.yaml / apexyard.projects.yaml.  The OPS_ROOT walk-up
          # below would then stop at the worktree instead of the real ops
          # fork.  Detect a linked worktree (absolute git-dir ≠ common-dir)
          # and replace REPO_ROOT with the main-checkout root (dirname of
          # the common-dir, i.e. parent of the main .git dir).  This keeps
          # the walk-up anchored to the actual ops fork while leaving the
          # later per-worktree branch detection (which re-reads git from
          # _fdir) unaffected.
          if [ -n "$REPO_ROOT" ]; then
            _wt_gd=$(git -C "$_fp_dir" rev-parse --absolute-git-dir 2>/dev/null)
            _wt_gcd=$(git -C "$_fp_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
            if [ -n "$_wt_gd" ] && [ -n "$_wt_gcd" ] && [ "$_wt_gd" != "$_wt_gcd" ]; then
              _main_root=$(dirname "$_wt_gcd")
              [ -d "$_main_root" ] && REPO_ROOT="$_main_root"
            fi
          fi
        fi
        ;;
      *)
        # Relative path (Bash write-target): resolve against CWD.
        REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
        ;;
    esac
  fi
  # Fallback: FILE_PATH empty (Bash command, no extractable target).
  if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  fi
  REL_PATH="$FILE_PATH"
  if [ -n "$REPO_ROOT" ] && [ -n "$FILE_PATH" ]; then
    case "$FILE_PATH" in
      "$REPO_ROOT"/*) REL_PATH="${FILE_PATH#$REPO_ROOT/}" ;;
    esac
  fi

  # NOTE: the narrow "Bash absolute path outside REPO_ROOT" exemption that
  # used to live here (#569) has been superseded by the out-of-governance
  # exemption below (apexyard#883), which covers BOTH Bash and Edit/Write/
  # MultiEdit, resolves symlinks before judging, and checks the actual
  # governance boundaries (ops root + registered workspaces) rather than
  # just "outside the nearest git repo". See that block for the full design.

  # Exempt paths.
  #
  # Each path-prefix exemption is matched in both REL_PATH (repo-relative)
  # and absolute (*/path/*) forms. Absolute-path fallthrough happens when
  # FILE_PATH points outside REPO_ROOT (e.g. agent worktrees whose
  # git-toplevel differs from the outer apexyard tree); in that case the
  # strip above is a no-op and REL_PATH stays absolute. The existing
  # `*.md` pattern already crosses `/`, so absolute-match via a `*/…`
  # prefix is a known-good shape — #56 extends the same trick to the
  # path-prefix exemptions.
  #
  # Skipped entirely when FILE_PATH is empty (Bash command writes to an
  # unextractable target — e.g. `python -c '...write...'`). Those fall
  # through to the ticket gate; the bootstrap-skill exemption below covers
  # the legitimate use case (/setup writing to fork-root files via Bash).
  if [ -n "$REL_PATH" ]; then
    case "$REL_PATH" in
      .claude/*|.claude|*/.claude/*|*/.claude) return 0 ;;
      docs/*|docs|*/docs/*|*/docs) return 0 ;;
      TODO.md|README.md|MEMORY.md|CLAUDE.md) return 0 ;;
    esac
    # Note: `projects/*/docs/*` is subsumed by `*/docs/*` above (shell case `*`
    # crosses `/`), so no separate arm needed. Per-project apexyard docs are
    # matched by the generic docs-in-any-subtree pattern.
    case "$REL_PATH" in
      *.md) return 0 ;;
    esac
  fi

  # Discover the ops root. Walk up from REPO_ROOT looking for either the
  # v2 `.apexyard-fork` marker (split-portfolio v2 layout) OR the legacy
  # v1 anchor (onboarding.yaml + apexyard.projects.yaml). Stop at /. If
  # not found, OPS_ROOT stays empty and we treat the REPO_ROOT itself as
  # the marker home (pre-#41 behaviour).
  #
  # Guard change (#744/#745): the lib-based resolver is always invoked when
  # the lib is available — even when REPO_ROOT is empty. This matters for
  # split-portfolio v2 where the workspace is a sibling repo with no git
  # history: REPO_ROOT is empty (no git in the sibling dir) but the
  # session-pin resolver in _lib-ops-root.sh can still locate the ops fork
  # from the pin written at session-start, regardless of start dir.
  local HOOK_DIR OPS_ROOT="" r parent
  HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOOK_DIR/_lib-ops-root.sh"
    # Pass REPO_ROOT as the walk-up start dir when available; the pin
    # resolver ignores the start dir and uses the session pin directly.
    OPS_ROOT=$(resolve_ops_root "${REPO_ROOT:-}")
  elif [ -n "$REPO_ROOT" ]; then
    # Inline walk-up fallback when the lib is absent (e.g. minimal test
    # sandboxes that only copy the core libs).
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

  local MARKER_HOME="${OPS_ROOT:-$REPO_ROOT}"
  MARKER_HOME="${MARKER_HOME:-.}"

  # Resolve the workspace dir for the per-project marker resolution below.
  # Defaults to $OPS_ROOT/workspace; split-portfolio v2 adopters override
  # via portfolio.workspace_dir to point at their private sibling repo.
  local WORKSPACE_DIR="$OPS_ROOT/workspace" resolved_ws
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

  # --- Out-of-governance exemption (apexyard#883) -------------------------
  #
  # A write TARGET that is outside every governed tree — the ops fork
  # itself AND every registered workspace/<project> clone — AND not inside
  # ANY git repository at all is outside this gate's jurisdiction. Applies
  # to BOTH Bash-detected writes and Edit/Write/MultiEdit tool calls (the
  # earlier #569 exemption was Bash-only, which left Edit-tool writes to
  # e.g. ~/.zshrc gated with no legitimate way to satisfy the gate on forks
  # with GitHub Issues disabled — the exact bug reported in #883).
  #
  # Fail-closed directions (deliberate):
  #   - An unresolvable FILE_PATH (empty — a Bash target the extractor
  #     couldn't identify) is NEVER exempted here; it falls through to the
  #     ticket gate below, unchanged from before this change.
  #   - Relative paths (a Bash write-target like `src/app.ts`) resolve
  #     against the hook's CWD before judging.
  #   - Symlinks are resolved to their real path before judging (via
  #     _resolve_real_path above), so a symlink living under $HOME that
  #     POINTS INTO a governed tree does not slip through as "outside" it.
  #   - Being inside SOME git repository that is neither the ops fork nor a
  #     registered workspace project does NOT exempt the write on its own —
  #     the ops-root/workspace boundaries are checked EXPLICITLY (not
  #     merely inferred from "is this a git repo"), because a
  #     split-portfolio workspace project is governed even when its clone
  #     isn't itself a git repository (e.g. a docs-only project, or a test
  #     fixture that never ran `git init`).
  #   - RAW-AND-RESOLVED containment (security review finding on #885,
  #     apexyard PR #885 — Hakim/security-reviewer): checking ops-root and
  #     workspace containment ONLY on the symlink-resolved target has a
  #     mirror-image hole to the one `_resolve_real_path` fixes. If a
  #     REGISTERED workspace/<project> entry is ITSELF a symlink whose real
  #     target lives OUTSIDE workspace/ in a non-git directory
  #     (`workspace/proj -> /some/nongit/dir`), resolving the target
  #     "escapes" the workspace boundary the same way the fix escapes a
  #     symlink-into-repo attack — the RESOLVED path no longer sits under
  #     WORKSPACE_DIR, so the naive single-check reads it as ungoverned and
  #     wrongly exempts it. The fix: evaluate ops-root/workspace
  #     containment against BOTH the RAW (pre-resolution) absolute target
  #     AND the fully resolved target, using the SAME canonicalized
  #     boundary anchors for both comparisons (only the anchors are
  #     canonicalized once; the raw target itself is deliberately left
  #     symlink-unresolved so a governed raw path can't be laundered away
  #     by a symlink further down it). A path counts as governed — and
  #     therefore NOT exempt — if EITHER the raw or the resolved check
  #     lands inside ops-root or workspace. Exemption requires ALL FOUR
  #     containment checks below (raw-ops, raw-ws, resolved-ops,
  #     resolved-ws) to say "outside", plus the git-repo probe to say "not
  #     in a repo".
  if [ -n "$FILE_PATH" ]; then
    local _og_abs_target _og_real_target
    case "$FILE_PATH" in
      /*) _og_abs_target="$FILE_PATH" ;;
      *)  _og_abs_target="$PWD/$FILE_PATH" ;;
    esac
    _og_real_target="$(_resolve_real_path "$_og_abs_target")"
    if [ -n "$_og_real_target" ]; then
      local _og_in_ops_raw=0
      local _og_in_ws_raw=0
      local _og_in_ops_res=0
      local _og_in_ws_res=0
      local _og_in_git=0
      local _og_real_ops="" _og_real_ws="" _og_probe

      # Canonicalize the boundary anchors ONCE — used as the comparison
      # basis for both the raw-target check and the resolved-target check.
      # This keeps the two checks internally consistent even when OPS_ROOT
      # was resolved via a non-canonical path (e.g. a CWD-based walk-up
      # that never ran through `pwd -P`).
      if [ -n "$OPS_ROOT" ]; then
        _og_real_ops="$(cd "$OPS_ROOT" 2>/dev/null && pwd -P)"
      fi
      if [ -n "$WORKSPACE_DIR" ] && [ -d "$WORKSPACE_DIR" ]; then
        _og_real_ws="$(cd "$WORKSPACE_DIR" 2>/dev/null && pwd -P)"
      fi

      # RAW check — the pre-resolution absolute target against the
      # canonical boundary. Catches a registered workspace/<project> that
      # is itself a symlink pointing OUTSIDE workspace/: the raw path
      # still literally names the governed workspace/<project> location,
      # even though resolving it lands elsewhere.
      if [ -n "$_og_real_ops" ]; then
        case "$_og_abs_target" in
          "$_og_real_ops") _og_in_ops_raw=1 ;;
          "$_og_real_ops"/*) _og_in_ops_raw=1 ;;
        esac
      fi
      if [ -n "$_og_real_ws" ]; then
        case "$_og_abs_target" in
          "$_og_real_ws") _og_in_ws_raw=1 ;;
          "$_og_real_ws"/*) _og_in_ws_raw=1 ;;
        esac
      fi

      # RESOLVED check — the symlink-resolved target against the same
      # canonical boundary. Catches a symlink OUTSIDE any governed tree
      # that POINTS INTO one (the original #883 defense).
      if [ -n "$_og_real_ops" ]; then
        case "$_og_real_target" in
          "$_og_real_ops") _og_in_ops_res=1 ;;
          "$_og_real_ops"/*) _og_in_ops_res=1 ;;
        esac
      fi
      if [ -n "$_og_real_ws" ]; then
        case "$_og_real_target" in
          "$_og_real_ws") _og_in_ws_res=1 ;;
          "$_og_real_ws"/*) _og_in_ws_res=1 ;;
        esac
      fi

      # Nearest-existing-ancestor git-repo probe on the REAL (symlink-
      # resolved) target — catches any git repo, governed or not. A single
      # probe suffices for both raw and resolved forms: directory
      # traversal (`-d`, `git -C`) transparently follows symlinks at the
      # OS level regardless of which path string reaches the location, so
      # raw-path traversal and resolved-path traversal of the SAME logical
      # target always land on the same physical directory.
      _og_probe="$_og_real_target"
      while [ -n "$_og_probe" ] && [ "$_og_probe" != "/" ] && [ ! -d "$_og_probe" ]; do
        _og_probe="$(dirname "$_og_probe")"
      done
      if [ -n "$_og_probe" ] && [ -d "$_og_probe" ] \
         && git -C "$_og_probe" rev-parse --show-toplevel >/dev/null 2>&1; then
        _og_in_git=1
      fi

      if [ "$_og_in_ops_raw" = 0 ] && [ "$_og_in_ws_raw" = 0 ] \
         && [ "$_og_in_ops_res" = 0 ] && [ "$_og_in_ws_res" = 0 ] \
         && [ "$_og_in_git" = 0 ]; then
        return 0
      fi
    fi
  fi

  # Bootstrap-skill exemption (apexyard#150): skills like /setup,
  # /handover, /update, /split-portfolio run BEFORE any ticket can exist
  # (no portfolio configured yet, no projects registered). They write a
  # marker at .claude/session/active-bootstrap with the skill name on
  # entry; this hook reads the marker, looks up the configured
  # bootstrap_skills list, and exits 0 if the active skill is on the list.
  #
  # The marker is cleared at SessionStart by clear-bootstrap-marker.sh so
  # a stale marker from an interrupted session can't carry over.
  local BOOTSTRAP_MARKER active_bootstrap
  BOOTSTRAP_MARKER="$MARKER_HOME/.claude/session/active-bootstrap"
  if [ -f "$BOOTSTRAP_MARKER" ]; then
    active_bootstrap=$(tr -d '[:space:]' < "$BOOTSTRAP_MARKER" 2>/dev/null)
    if [ -n "$active_bootstrap" ]; then
      # Source the config reader and look up bootstrap_skills.
      if [ -f "$MARKER_HOME/.claude/hooks/_lib-read-config.sh" ]; then
        # shellcheck source=/dev/null
        . "$MARKER_HOME/.claude/hooks/_lib-read-config.sh"
        if command -v config_get >/dev/null 2>&1; then
          # `config_get '.ticket.bootstrap_skills[]'` outputs one skill per
          # line. Use grep -wF for whole-word, fixed-string match.
          if config_get '.ticket.bootstrap_skills[]' 2>/dev/null | grep -qwF "$active_bootstrap"; then
            return 0
          fi
        fi
      fi
    fi
  fi

  # Per-project resolution (apexyard#41): if FILE_PATH points under the
  # resolved workspace dir, we look for a per-project marker at
  # .claude/session/tickets/<project>. This keeps per-project session state
  # keyed by the managed-project name and localised in the ops fork
  # (gitignored), instead of the pre-#41 scheme that relied on a
  # .claude/session/ inside each managed-project clone.
  #
  # Split-portfolio v2 (#242): WORKSPACE_DIR may resolve to a sibling
  # private repo path (e.g. ../<fork>-portfolio/workspace) instead of the
  # default $OPS_ROOT/workspace; both shapes are handled here.
  local PROJECT="" tail
  if [ -n "$WORKSPACE_DIR" ]; then
    case "$FILE_PATH" in
      "$WORKSPACE_DIR"/*)
        tail="${FILE_PATH#$WORKSPACE_DIR/}"
        PROJECT="${tail%%/*}"
        ;;
    esac
  fi
  # Belt-and-suspenders: also recognise the literal $OPS_ROOT/workspace/
  # shape, in case workspace_dir is overridden but a tool produced an
  # absolute path under the in-fork legacy location.
  if [ -z "$PROJECT" ] && [ -n "$OPS_ROOT" ]; then
    case "$FILE_PATH" in
      "$OPS_ROOT"/workspace/*)
        tail="${FILE_PATH#$OPS_ROOT/workspace/}"
        PROJECT="${tail%%/*}"
        ;;
    esac
  fi

  # Tier 0 — per-worktree marker (#513): when two agents are fanned out on the
  # SAME managed project in parallel git worktrees, each must declare its ticket
  # independently or they collide on the shared per-project file (last-writer-wins,
  # silent wrong-ticket pass). A branch-scoped marker at
  # tickets/<project>/<safe-branch> is resolved BEFORE the per-project tier.
  # Single-agent / non-worktree flows have no such marker and fall straight
  # through to the per-project tier — no behaviour change. Note: tickets/<project>
  # is a FILE in single-agent mode and a DIRECTORY in worktree mode; the `-f`
  # tests below distinguish them, so the two tiers never conflict.
  local PER_WORKTREE_MARKER="" WT_BRANCH SAFE_BRANCH _fdir _gd _gcd
  if [ -n "$PROJECT" ]; then
    # Branch: prefer the harness-set env var (populated at worktree spawn). Else
    # only treat the file's repo as worktree-scoped when it's a LINKED worktree,
    # detected by comparing the ABSOLUTE git-dir against the ABSOLUTE common-dir
    # (they differ only in a linked worktree). This matches /start-ticket's
    # write-side detection exactly — no read/write asymmetry — and the absolute
    # forms avoid the false positive where, in the main checkout from a subdir,
    # `--git-dir` is absolute but `--git-common-dir` is relative.
    WT_BRANCH="${CLAUDE_WORKTREE_BRANCH:-}"
    if [ -z "$WT_BRANCH" ]; then
      _fdir=$(dirname "$FILE_PATH")
      _gd=$(git -C "$_fdir" rev-parse --absolute-git-dir 2>/dev/null)
      _gcd=$(git -C "$_fdir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
      if [ -n "$_gd" ] && [ "$_gd" != "$_gcd" ]; then
        WT_BRANCH=$(git -C "$_fdir" branch --show-current 2>/dev/null)
      fi
    fi
    if [ -n "$WT_BRANCH" ]; then
      SAFE_BRANCH="${WT_BRANCH//\//__}"   # '/' → '__' for a filesystem-safe segment
      PER_WORKTREE_MARKER="$MARKER_HOME/.claude/session/tickets/$PROJECT/$SAFE_BRANCH"
      if [ -f "$PER_WORKTREE_MARKER" ]; then
        return 0
      fi
    fi
  fi

  local PER_PROJECT_MARKER=""
  if [ -n "$PROJECT" ]; then
    PER_PROJECT_MARKER="$MARKER_HOME/.claude/session/tickets/$PROJECT"
    if [ -f "$PER_PROJECT_MARKER" ]; then
      return 0
    fi
  fi

  # Fallback: the ops-level current-ticket marker. This is the pre-#41
  # location and still honoured for ops-repo framework edits, and as a
  # safety net for any file we couldn't map to a specific project.
  local FALLBACK_MARKER="$MARKER_HOME/.claude/session/current-ticket"
  if [ -f "$FALLBACK_MARKER" ]; then
    return 0
  fi

  # Nothing found — emit a guide that names both possibilities.
  cat >&2 <<MSG
BLOCKED: No active ticket set for this session.

ApexYard requires a ticket BEFORE any code changes (workflow-gates rule #3,
pre-build gate, "one ticket at a time").

To unblock:

  1. Create or find the ticket (GitHub Issue in the project's own repo):
       gh issue create --repo <owner/repo> --title "..."
  2. Declare it for this session — run the /start-ticket skill with the
     issue number (or pass owner/repo#number to pin it). The skill writes
     a per-project marker if the ticket's repo matches a registered
     managed project, otherwise falls back to the ops-level marker.
  3. Retry the edit

Markers looked up for this path (in order):
$([ -n "$PER_WORKTREE_MARKER" ] && echo "  per-worktree: $PER_WORKTREE_MARKER")
$([ -n "$PER_PROJECT_MARKER" ] && echo "  per-project:  $PER_PROJECT_MARKER")
  ops fallback: $FALLBACK_MARKER

Target: ${FILE_PATH:-<unextractable Bash write target>}

Exempt paths (no ticket required): .claude/, docs/, projects/*/docs/, *.md
MSG
  return 2
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

# Bash-tool path: extract the target file(s) from the command if it appears
# to be a write. Closes the bypass surface where Bash file-writes
# (`echo > file`, `tee file`, `sed -i ... file`, `python -c
# 'pathlib.Path(...).write_text(...)'`, etc.) routed around the
# Edit/Write/MultiEdit-only gate. See me2resh/apexyard#151 + the
# _lib-detect-bash-write helper for the matcher details and design
# choice (false-negatives preferred over false-positives).
if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  if [ -z "$COMMAND" ]; then
    exit 0
  fi

  # Source the bash-write detector. Library lives next to this hook.
  HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [ ! -f "$HOOK_DIR/_lib-detect-bash-write.sh" ]; then
    # Library missing — fall back to non-Bash behavior to avoid bricking
    # the hook entirely.
    exit 0
  fi
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-detect-bash-write.sh"

  if ! bash_command_appears_to_write "$COMMAND"; then
    # Read-only command — no gate.
    exit 0
  fi

  # Deletion-only (rm without any content-writing sibling) does not add repo
  # content, so it should not require a ticket (#569).
  if bash_command_is_deletion_only "$COMMAND"; then
    exit 0
  fi

  # Extract ALL write targets (#886) — not just the first. A command can
  # name more than one (`echo a > /tmp/x; echo b > src/app.ts`, `tee a b
  # c`); judging only the first let the rest slip past the gate whenever
  # the first happened to be exempt.
  ALL_TARGETS=$(bash_extract_write_targets "$COMMAND")

  if [ -z "$ALL_TARGETS" ]; then
    # No target extractable at all — categorical fail-closed gate, same
    # as the pre-#886 empty-FILE_PATH behaviour (single call, FILE_PATH="").
    _ratc_evaluate_target "" "Bash"
    exit $?
  fi

  # AND semantics: the command as a whole passes only if EVERY extracted
  # target independently clears the gate. Stop at (and report) the first
  # target that doesn't — the overall verdict is already "block" at that
  # point, so there's nothing to gain from evaluating the rest.
  while IFS= read -r _tgt; do
    [ -z "$_tgt" ] && continue
    if ! _ratc_evaluate_target "$_tgt" "Bash"; then
      exit 2
    fi
  done <<< "$ALL_TARGETS"

  exit 0
fi

# Non-Bash tool call (Edit/Write/MultiEdit): a single, explicit file_path —
# no multi-target concern, one evaluation.
_ratc_evaluate_target "$FILE_PATH" "$TOOL_NAME"
exit $?
