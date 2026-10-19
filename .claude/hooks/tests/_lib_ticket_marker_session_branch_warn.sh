#!/bin/bash
# Shared helpers for #1533 AC tests (session/branch marker warning).
# Sourced by test_ticket_marker_session_branch_warn_ac*.sh.

TM_HOOKS_TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TM_SRC_ROOT="$(cd "$TM_HOOKS_TESTS/../../.." && pwd)"

tm_src_root() {
  printf '%s\n' "$TM_SRC_ROOT"
}

# Pre-#1533 / #1794 lib for AC fail-before. Pin a literal SHA (rule 10a): after
# merge, upstream/dev holds the fix. Override with APEXYARD_AC_BEFORE_SHA.
tm_upstream_lib() {
  local root sha
  root=$(tm_src_root)
  sha="${APEXYARD_AC_BEFORE_SHA:-d970c194b0ff5e14aac71d486c32dd3aa976d78a}"
  if git -C "$root" show "$sha:.claude/hooks/_lib-active-ticket.sh" \
    >/tmp/apexyard-1533-before-lib.sh 2>/dev/null; then
    printf '%s\n' /tmp/apexyard-1533-before-lib.sh
    return 0
  fi
  return 1
}

tm_make_ops() {
  local root ops f
  root=$(tm_src_root)
  ops=$(mktemp -d)
  ops=$(cd -P "$ops" && pwd)
  git init -q "$ops"
  git -C "$ops" config user.email t@example.com
  git -C "$ops" config user.name t
  : > "$ops/onboarding.yaml"
  : > "$ops/.apexyard-fork"
  printf 'projects:\n  - name: p1\n    repo: org/p1\n' > "$ops/apexyard.projects.yaml"
  git -C "$ops" add onboarding.yaml apexyard.projects.yaml .apexyard-fork
  git -C "$ops" commit -q -m init
  mkdir -p "$ops/.claude/hooks" "$ops/.claude/session" "$ops/workspace/p1/src"
  for f in \
    require-active-ticket.sh require-migration-ticket.sh \
    _lib-active-ticket.sh _lib-path-resolve.sh _lib-read-config.sh \
    _lib-ops-root.sh _lib-portfolio-paths.sh _lib-resolution-cache.sh \
    _lib-ticket-path-exemptions.sh _lib-detect-bash-write.sh \
    _lib-awk-fallback.sh _lib-mask-quoted.sh _lib-session-markers.sh \
    _lib-fail-closed-json.sh
  do
    [ -f "$root/.claude/hooks/$f" ] && cp "$root/.claude/hooks/$f" "$ops/.claude/hooks/"
  done
  cp "$root/.claude/project-config.defaults.json" "$ops/.claude/"
  chmod +x "$ops/.claude/hooks/"*.sh
  git init -q "$ops/workspace/p1"
  git -C "$ops/workspace/p1" config user.email t@example.com
  git -C "$ops/workspace/p1" config user.name t
  printf 'x\n' > "$ops/workspace/p1/src/app.ts"
  git -C "$ops/workspace/p1" add src/app.ts
  git -C "$ops/workspace/p1" commit -q -m init
  printf '%s\n' "$ops"
}

tm_write_marker() {
  # $1 tree $2 repo $3 num $4 title $5 session_id $6 branch
  local tree="$1" gd
  gd=$(git -C "$tree" rev-parse --absolute-git-dir)
  {
    printf 'repo=%s\n' "$2"
    printf 'number=%s\n' "$3"
    printf 'title=%s\n' "$4"
    printf 'url=https://example.test/%s\n' "$3"
    printf 'suggested_branch=feature/x\n'
    printf 'session_id=%s\n' "$5"
    printf 'branch=%s\n' "$6"
    printf 'started_at=2026-01-01T00:00:00Z\n'
  } > "$gd/apexyard-ticket"
}

tm_run_gate() {
  # $1 ops $2 file_path $3 session_id → prints stderr, sets nothing; echo rc via $?
  local ops="$1" path="$2" sid="$3" payload
  payload=$(jq -nc --arg p "$path" '{tool_name:"Edit",tool_input:{file_path:$p}}')
  (cd "$ops" && {
      printf '%s' "$payload" \
        | CLAUDE_CODE_SESSION_ID="$sid" APEXYARD_OPS_DISABLE_PIN=1 \
          bash "$ops/.claude/hooks/require-active-ticket.sh" >/dev/null
    } 2>&1)
}

# Run require-migration-ticket.sh with a mocked gh that always returns an
# OPEN labelled migration issue. Prints stderr. Exit status is the gate's.
tm_run_migration_gate() {
  # $1 ops $2 file_path $3 session_id
  local ops="$1" path="$2" sid="$3" payload bin out rc
  bin=$(mktemp -d)
  cat > "$bin/gh" <<'G'
#!/bin/bash
echo '{"state":"OPEN","title":"T","url":"https://gh/42","labels":[{"name":"migration"}],"body":"refs docs/agdr/AgDR-0001-db-migration.md"}'
G
  chmod +x "$bin/gh"
  payload=$(jq -nc --arg p "$path" '{tool_name:"Write",tool_input:{file_path:$p,content:"x"}}')
  out=$(cd "$ops" && {
      printf '%s' "$payload" \
        | PATH="$bin:$PATH" CLAUDE_CODE_SESSION_ID="$sid" APEXYARD_OPS_DISABLE_PIN=1 \
          bash "$ops/.claude/hooks/require-migration-ticket.sh" >/dev/null
    } 2>&1)
  rc=$?
  rm -rf "$bin"
  printf '%s' "$out"
  return "$rc"
}

# Install pre-fix (Rex-finding) hooks from a known ancestor into <ops>.
# Default: 121136b3 — the commit kept under this fix. Override with
# APEXYARD_REX_BEFORE_SHA or APEXYARD_REX_BEFORE_DIR (dir with both files).
tm_install_rex_before_hooks() {
  local ops="$1" root sha dir
  root=$(tm_src_root)
  dir="${APEXYARD_REX_BEFORE_DIR:-}"
  sha="${APEXYARD_REX_BEFORE_SHA:-121136b32182f907afaf34cd6e9182742a0bad86}"
  if [ -n "$dir" ] && [ -f "$dir/_lib-active-ticket.sh" ] \
    && [ -f "$dir/require-migration-ticket.sh" ]; then
    cp "$dir/_lib-active-ticket.sh" "$ops/.claude/hooks/"
    cp "$dir/require-migration-ticket.sh" "$ops/.claude/hooks/"
    return 0
  fi
  if git -C "$root" show "$sha:.claude/hooks/_lib-active-ticket.sh" \
    > "$ops/.claude/hooks/_lib-active-ticket.sh" 2>/dev/null \
    && git -C "$root" show "$sha:.claude/hooks/require-migration-ticket.sh" \
    > "$ops/.claude/hooks/require-migration-ticket.sh" 2>/dev/null; then
    return 0
  fi
  return 1
}
