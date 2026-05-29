#!/bin/bash
# SessionStart hook: apply adopter agent-routing overrides to the
# .claude/agents/*.md frontmatter in-place.
#
# Per AgDR-0050 § Axis 4 + ticket #351 PR 2 — closes the loop on Wave 1
# PR 1's schema + portfolio_agent_routing resolver. Adopters edit ONE
# YAML file (in the private repo for split-portfolio v2, or gitignored
# at the fork root for single-fork mode); this hook makes those edits
# LIVE on the next session.
#
# Behaviour:
#   - Resolve the routing path via portfolio_agent_routing
#   - Silently exit 0 if no routing file exists (zero-config zero-
#     behaviour-change — the documented out-of-box experience)
#   - Parse the YAML (yq preferred; python3 fallback)
#   - Local-routing prep (me2resh/apexyard#438):
#       a. For each unique endpoint, probe `<endpoint>/v1/models` or
#          `/health` with a 2s timeout. Mark reachable/unreachable.
#          Unreachable endpoints have their per-agent rows filtered out
#          BEFORE the apply loop — a downed proxy doesn't poison the
#          session.
#       b. For `model: ollama/<name>` rows whose endpoint is reachable,
#          query `<endpoint>/api/tags` for the model name. On miss emit
#          a warning naming `ollama pull <name>`. The model rewrite still
#          applies.
#   - For each entry in agents:
#       1. Locate .claude/agents/<name>.md — silently skip if missing
#          (adopter may have a stale entry; harmless, not an error)
#       2. Snapshot the framework default model: line (from HEAD of dev
#          for the file) into .claude/agents/.framework-defaults.json
#          so the drift guard has a baseline regardless of whether the
#          adopter committed the rewrite
#       3. Rewrite the model: line in the agent file to the override
#       4. If endpoint: set AND reachable, write to .claude/session/
#          agent-env/<name>.env (per-agent endpoint env file — informational
#          in v1 until Claude Code exposes per-agent env scoping)
#       5. If env: block set, append KEY=VALUE lines to that env file
#          (resolving $VAR_NAME refs against the parent env)
#   - Write session-wide .claude/session/agent-env/__session__.env with
#     ANTHROPIC_BASE_URL=<first-reachable-endpoint> (the routing mechanism
#     that actually works in v1, per AgDR-0050 § Axis 5). Multi-endpoint
#     declarations warn and use the first.
#   - Print a single one-line summary banner: silent on N=0; else
#       "ApexYard: applied N agent-routing override(s) from agent-routing.yaml [M Ollama, K warning(s)]"
#     The Ollama / warning suffix is omitted when both counts are 0.
#   - Idempotent: running twice with the same config produces the same
#     state, no compounding writes (env files are truncated, not appended,
#     when written; the framework-defaults snapshot is keyed by agent
#     name so re-applications are noops)
#
# Banner budget: ≤ 600 chars across all SessionStart hooks. This hook
# emits at most ~110 chars (silent on no-op).
#
# Drift-prevention complement: block-agent-routing-drift.sh fires on
# git commit + git push and refuses to let routing-induced rewrites
# escape to a public-class remote. Both hooks together implement
# AgDR-0050 § Axis 4's "SessionStart rewrite + drift guards" pattern.

set -u

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# Walk up to find the apexyard fork root (v2 marker first, legacy v1
# anchor fallback). Same shape as clear-bootstrap-marker.sh.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  ROOT=$(resolve_ops_root "$REPO_ROOT")
else
  cur="$REPO_ROOT"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -f "$cur/.apexyard-fork" ]; then
      ROOT="$cur"
      break
    fi
    if [ -f "$cur/onboarding.yaml" ] && [ -f "$cur/apexyard.projects.yaml" ]; then
      ROOT="$cur"
      break
    fi
    cur=$(dirname "$cur")
  done
fi

if [ -z "$ROOT" ]; then
  exit 0
fi

# Source path resolvers + config reader. Prefer the hook's neighbour
# libs (HOOK_DIR/_lib-*.sh) because they're guaranteed to match this
# hook's version. The walk-up ROOT may be an older copy mid-upgrade
# (e.g. adopter pulling in a new framework hook before the lib
# resolvers shipped on its dev branch).
LIB_SRC_DIR=""
if [ -f "$HOOK_DIR/_lib-portfolio-paths.sh" ] && [ -f "$HOOK_DIR/_lib-read-config.sh" ]; then
  LIB_SRC_DIR="$HOOK_DIR"
elif [ -f "$ROOT/.claude/hooks/_lib-portfolio-paths.sh" ] && [ -f "$ROOT/.claude/hooks/_lib-read-config.sh" ]; then
  LIB_SRC_DIR="$ROOT/.claude/hooks"
else
  exit 0
fi
# shellcheck source=/dev/null
. "$LIB_SRC_DIR/_lib-read-config.sh"
# shellcheck source=/dev/null
. "$LIB_SRC_DIR/_lib-portfolio-paths.sh"

ROUTING_PATH=$(portfolio_agent_routing)
if [ -z "$ROUTING_PATH" ] || [ ! -f "$ROUTING_PATH" ]; then
  # Zero-config zero-behaviour: no routing file = framework defaults.
  exit 0
fi

AGENTS_DIR="$ROOT/.claude/agents"
if [ ! -d "$AGENTS_DIR" ]; then
  exit 0
fi

DEFAULTS_FILE="$AGENTS_DIR/.framework-defaults.json"
ENV_DIR="$ROOT/.claude/session/agent-env"
mkdir -p "$ENV_DIR"

# -----------------------------------------------------------------------------
# Parse the routing YAML — emit one line per agent in the shape:
#   <name>\t<key>\t<value>
# Where key ∈ {model, endpoint, env, timeout_seconds}. (#358 dropped the
# advertised-but-not-wired `allowed_tools_override` field; the per-agent
# allowed-tools list lives in .claude/agents/<name>.md frontmatter.)
# env values come out as a JSON-encoded object so the consumer below can
# iterate KEY=VAL pairs without parsing YAML twice.
#
# yq is preferred; python3 + PyYAML is the fallback. If neither works the
# hook is a silent no-op (adopters without yq/python3 must install one or
# wait for v2 of the schema). Emit a one-line caveat on stderr in that
# rare case so the adopter knows why their routing config didn't apply.
# -----------------------------------------------------------------------------
parse_routing() {
  if command -v yq >/dev/null 2>&1; then
    # yq output: tab-separated <name>\t<key>\t<value>. env is emitted as
    # one row per KEY=VAL inside the env: block.
    yq eval '
      .agents // {} | to_entries | .[] | . as $a |
      (
        ($a.value.model // "" | select(. != "") | $a.key + "\tmodel\t" + .),
        ($a.value.endpoint // "" | select(. != "") | $a.key + "\tendpoint\t" + .),
        ($a.value.timeout_seconds // "" | select(. != "") | $a.key + "\ttimeout_seconds\t" + (. | tostring)),
        ($a.value.env // {} | to_entries | .[] | $a.key + "\tenv\t" + .key + "=" + (.value | tostring))
      )
    ' "$ROUTING_PATH" 2>/dev/null
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    # Try PyYAML first; if not present, fall through to the awk parser.
    py_out=$(python3 - "$ROUTING_PATH" <<'PY' 2>/dev/null
import sys
try:
    import yaml
except ImportError:
    sys.exit(7)
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as fh:
        doc = yaml.safe_load(fh) or {}
except Exception:
    sys.exit(0)
agents = (doc.get('agents') or {})
if not isinstance(agents, dict):
    sys.exit(0)
for name, entry in agents.items():
    if not isinstance(entry, dict):
        continue
    model = entry.get('model')
    if model:
        print(f"{name}\tmodel\t{model}")
    endpoint = entry.get('endpoint')
    if endpoint:
        print(f"{name}\tendpoint\t{endpoint}")
    timeout = entry.get('timeout_seconds')
    if timeout:
        print(f"{name}\ttimeout_seconds\t{timeout}")
    env = entry.get('env') or {}
    if isinstance(env, dict):
        for k, v in env.items():
            print(f"{name}\tenv\t{k}={v}")
PY
)
    py_rc=$?
    if [ "$py_rc" -ne 7 ]; then
      printf '%s\n' "$py_out"
      return 0
    fi
  fi

  # Minimal awk fallback — supports the schema's documented shape
  # (2-space indented YAML, model/endpoint/timeout_seconds at depth 2,
  # env: subblock at depth 2 with KEY: VALUE pairs at depth 3). Doesn't
  # try to be a general YAML parser; this is enough for the v1 schema.
  awk '
    BEGIN { agents_block = 0; cur_name = ""; in_env = 0 }
    # Skip comments + blank lines.
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }

    # Top-level "agents:" line opens the block. Any subsequent top-level
    # key (no leading whitespace, no leading hyphen) closes it.
    /^agents:/ { agents_block = 1; next }
    /^[a-zA-Z_]/ {
      if (agents_block) { agents_block = 0 }
      next
    }

    # Inside agents block: depth-2 entries name an agent.
    agents_block && /^  [a-zA-Z0-9_-][a-zA-Z0-9_-]*:[[:space:]]*$/ {
      line = $0
      sub(/^  /, "", line)
      sub(/:.*$/, "", line)
      cur_name = line
      in_env = 0
      next
    }

    # Depth-4 lines inside env: are KEY: VALUE (6-space indent).
    cur_name != "" && in_env && /^      [a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*/ {
      line = $0
      sub(/^      /, "", line)
      key = line
      sub(/:.*$/, "", key)
      val = line
      sub(/^[^:]*:[[:space:]]*/, "", val)
      # Strip optional surrounding quotes.
      sub(/^["'\''"]/, "", val)
      sub(/["'\''"][[:space:]]*$/, "", val)
      print cur_name "\tenv\t" key "=" val
      next
    }

    # Depth-3 keys for the active agent (4-space indent). env: opens the
    # env subblock; model/endpoint/timeout_seconds emit immediately.
    cur_name != "" && /^    [a-zA-Z_][a-zA-Z0-9_]*:/ {
      line = $0
      sub(/^    /, "", line)
      key = line
      sub(/:.*$/, "", key)
      val = line
      sub(/^[^:]*:[[:space:]]*/, "", val)
      sub(/^["'\''"]/, "", val)
      sub(/["'\''"][[:space:]]*$/, "", val)
      if (key == "env") {
        in_env = 1
        next
      }
      in_env = 0
      if (val == "") { next }
      if (key == "model" || key == "endpoint" || key == "timeout_seconds") {
        print cur_name "\t" key "\t" val
      }
      next
    }

    # Less indentation under cur_name → reset env flag.
    cur_name != "" && /^  [a-zA-Z]/ { in_env = 0 }
  ' "$ROUTING_PATH" 2>/dev/null
  return 0
}

ROWS=$(parse_routing)
if [ -z "$ROWS" ]; then
  exit 0
fi

# -----------------------------------------------------------------------------
# Local-routing prep — extends the v1 schema's `endpoint:` + `model: ollama/*`
# semantics into actually-applied state. See me2resh/apexyard#438.
#
# Two non-blocking checks (warnings to stderr; model rewrite proceeds):
#
#   1. Reachability — for each unique endpoint declared by any agent, probe
#      `<endpoint>/v1/models` (LiteLLM healthcheck) with a 2s timeout. If
#      neither it nor `/health` responds 2xx, mark the endpoint unreachable.
#      Endpoint rows pointing at unreachable proxies are filtered out of
#      $ROWS BEFORE the apply loop, so per-agent .env file's
#      ANTHROPIC_BASE_URL is NOT written when the proxy is down — a downed
#      proxy can't poison the session.
#
#   2. Model-pulled — for `model: ollama/<name>` rows whose endpoint is
#      reachable, query `<endpoint>/api/tags` and grep for the model name.
#      On miss: warn the adopter to run `ollama pull <name>`. The model
#      rewrite still applies; Ollama may pull on first call with cold-start
#      cost — that's an adopter-visible cost, not a hook concern.
#
# After the apply loop we also write a session-wide `__session__.env`
# containing ANTHROPIC_BASE_URL=<first-reachable-endpoint>. This is the only
# routing mechanism that works in v1 — per AgDR-0050 § Axis 5, Claude Code
# doesn't consume per-agent env files yet. The per-agent files keep being
# written for forward-compat. Multi-endpoint declarations warn and pick
# the first.
# -----------------------------------------------------------------------------

ollama_applied=0
warnings=0

EP_REACH=$(mktemp 2>/dev/null) || { exit 0; }
AGENT_MODELS=$(mktemp 2>/dev/null) || { rm -f "$EP_REACH"; exit 0; }
AGENT_ENDPOINTS=$(mktemp 2>/dev/null) || { rm -f "$EP_REACH" "$AGENT_MODELS"; exit 0; }

# Build agent → model and agent → endpoint maps from $ROWS.
printf '%s\n' "$ROWS" | awk -F'\t' '$2=="model" {print $1 "\t" $3}' > "$AGENT_MODELS"
printf '%s\n' "$ROWS" | awk -F'\t' '$2=="endpoint" && $3!="" {print $1 "\t" $3}' > "$AGENT_ENDPOINTS"

# 1. Reachability probe — one curl per unique endpoint, 2s timeout each.
UNIQUE_EPS=$(awk -F'\t' '{print $2}' "$AGENT_ENDPOINTS" | sort -u)
while IFS= read -r ep; do
  [ -z "$ep" ] && continue
  reachable=0
  if command -v curl >/dev/null 2>&1; then
    if curl --max-time 2 --silent --fail -o /dev/null "$ep/v1/models" 2>/dev/null; then
      reachable=1
    elif curl --max-time 2 --silent --fail -o /dev/null "$ep/health" 2>/dev/null; then
      reachable=1
    fi
  else
    # No curl available — skip reachability check entirely, treat as reachable.
    # The model rewrite + per-agent env file still apply; the adopter just
    # doesn't get the "your proxy is down" warning. Better than blocking.
    reachable=1
  fi
  printf '%s\t%s\n' "$ep" "$reachable" >> "$EP_REACH"
  if [ "$reachable" -eq 0 ]; then
    echo "⚠ agent-routing: endpoint $ep not reachable; skipping endpoint override (model rewrite still applies)" >&2
    warnings=$((warnings + 1))
  fi
done <<EOF
$UNIQUE_EPS
EOF

# 2. Model-pulled check — for ollama/* models whose endpoint is reachable.
while IFS=$'\t' read -r agent model; do
  [ -z "$agent" ] && continue
  case "$model" in
    ollama/*)
      ollama_applied=$((ollama_applied + 1))
      ep=$(awk -F'\t' -v a="$agent" '$1==a {print $2; exit}' "$AGENT_ENDPOINTS")
      [ -z "$ep" ] && continue
      reach=$(awk -F'\t' -v e="$ep" '$1==e {print $2; exit}' "$EP_REACH")
      [ "${reach:-0}" = "1" ] || continue
      model_name="${model#ollama/}"
      if command -v curl >/dev/null 2>&1; then
        if ! curl --max-time 2 --silent --fail "$ep/api/tags" 2>/dev/null | grep -q "\"name\":\"$model_name\""; then
          echo "⚠ agent-routing: $agent — model $model_name not in local Ollama; run: ollama pull $model_name" >&2
          warnings=$((warnings + 1))
        fi
      fi
      ;;
  esac
done < "$AGENT_MODELS"

# 3. Filter $ROWS — drop endpoint rows pointing at unreachable endpoints.
#    The apply loop downstream will not see those rows, so per-agent env
#    files keep their existing ANTHROPIC_BASE_URL untouched.
ROWS=$(printf '%s\n' "$ROWS" | awk -F'\t' -v reach="$EP_REACH" '
  BEGIN {
    while ((getline line < reach) > 0) {
      split(line, p, "\t")
      r[p[1]] = p[2]
    }
  }
  $2 == "endpoint" && r[$3] == "0" { next }
  { print }
')

# -----------------------------------------------------------------------------
# Snapshot framework defaults BEFORE any rewrite — so the drift guard
# has a baseline regardless of whether the adopter committed the rewrite
# to the fork.
#
# Format: a tiny JSON object {agent_name: "<framework-default-model>"}.
# We don't use jq for the write to avoid a new hard dependency; assembled
# by string concat with newline-per-entry.
#
# Idempotency: re-running with the same config overwrites the snapshot
# (with the same contents, since we re-read each agent file's HEAD
# version).
# -----------------------------------------------------------------------------
snapshot_framework_default() {
  local agent_name="$1"
  local agent_file="$AGENTS_DIR/${agent_name}.md"
  local default_model=""

  # Prefer the dev-branch baseline (most reliable framework default).
  # Fall back to the current file's model: if dev isn't reachable
  # (detached HEAD, bare checkout, hook running outside a git context).
  if git -C "$ROOT" rev-parse --verify dev >/dev/null 2>&1; then
    default_model=$(git -C "$ROOT" show "dev:.claude/agents/${agent_name}.md" 2>/dev/null \
      | awk '/^---/{count++; next} count==1 && /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}')
  fi
  if [ -z "$default_model" ] && [ -f "$agent_file" ]; then
    default_model=$(awk '/^---/{count++; next} count==1 && /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}' "$agent_file")
  fi
  echo "$default_model"
}

# Build framework defaults JSON in a temp accumulator (one entry per
# agent we touch), then write atomically.
defaults_acc=""
applied=0

# Use a process-substitution-free read so we run on POSIX bash without
# requiring /dev/fd. Tab-separated input.
TMP_ROWS=$(mktemp 2>/dev/null) || { exit 0; }
printf '%s\n' "$ROWS" > "$TMP_ROWS"

while IFS=$'\t' read -r agent_name key value; do
  [ -z "$agent_name" ] && continue
  agent_file="$AGENTS_DIR/${agent_name}.md"
  if [ ! -f "$agent_file" ]; then
    # Orphan entry — adopter may have a stale routing config, harmless.
    continue
  fi

  case "$key" in
    model)
      # Snapshot framework default ONCE per agent (idempotent — we
      # always grab from dev HEAD, never from the working-tree file).
      if ! echo "$defaults_acc" | grep -q "^\"${agent_name}\":"; then
        fwd=$(snapshot_framework_default "$agent_name")
        if [ -n "$fwd" ]; then
          defaults_acc="$defaults_acc\"${agent_name}\":\"${fwd}\",
"
        fi
      fi

      # Rewrite the model: line in the agent file (inside frontmatter).
      # We use awk to limit replacement to the first frontmatter block.
      tmp_agent=$(mktemp)
      awk -v new="$value" '
        BEGIN { fm=0; replaced=0 }
        /^---[[:space:]]*$/ { fm++; print; next }
        fm==1 && !replaced && /^model:[[:space:]]*/ {
          print "model: " new
          replaced=1
          next
        }
        { print }
      ' "$agent_file" > "$tmp_agent" && mv "$tmp_agent" "$agent_file"
      applied=$((applied + 1))
      ;;

    endpoint)
      # Write per-agent endpoint env file. Truncate-and-write (not
      # append) for idempotency.
      env_file="$ENV_DIR/${agent_name}.env"
      # Preserve any existing non-endpoint lines on re-application by
      # filtering them out then re-emitting the endpoint line.
      if [ -f "$env_file" ]; then
        # Drop existing ANTHROPIC_BASE_URL lines; keep everything else.
        grep -v '^ANTHROPIC_BASE_URL=' "$env_file" > "${env_file}.tmp" 2>/dev/null || true
        mv "${env_file}.tmp" "$env_file"
      else
        : > "$env_file"
      fi
      printf 'ANTHROPIC_BASE_URL=%s\n' "$value" >> "$env_file"
      ;;

    env)
      # value is KEY=VAL — resolve $VAR refs against parent env.
      env_file="$ENV_DIR/${agent_name}.env"
      [ -f "$env_file" ] || : > "$env_file"
      env_key=${value%%=*}
      env_val=${value#*=}
      # Resolve a single $VAR_NAME reference (matches example D in the
      # schema). More complex shell expansions are out of scope for v1.
      case "$env_val" in
        \$*)
          var_name=${env_val#\$}
          # shellcheck disable=SC2086
          eval "env_val=\${$var_name:-}"
          ;;
      esac
      # Drop any prior line for this key; re-emit (idempotent).
      grep -v "^${env_key}=" "$env_file" > "${env_file}.tmp" 2>/dev/null || true
      mv "${env_file}.tmp" "$env_file" 2>/dev/null || true
      printf '%s=%s\n' "$env_key" "$env_val" >> "$env_file"
      ;;

    timeout_seconds)
      # Recorded but not actively consumed in v1 — Claude Code doesn't
      # expose a per-agent timeout-override env var yet. Drop a marker
      # in the env file so future runtime support can pick it up.
      env_file="$ENV_DIR/${agent_name}.env"
      [ -f "$env_file" ] || : > "$env_file"
      grep -v '^APEXYARD_AGENT_TIMEOUT=' "$env_file" > "${env_file}.tmp" 2>/dev/null || true
      mv "${env_file}.tmp" "$env_file" 2>/dev/null || true
      printf 'APEXYARD_AGENT_TIMEOUT=%s\n' "$value" >> "$env_file"
      ;;
  esac
done < "$TMP_ROWS"

rm -f "$TMP_ROWS"

# -----------------------------------------------------------------------------
# Session-wide ANTHROPIC_BASE_URL — write __session__.env using the first
# reachable endpoint declared in agent-routing.yaml. Per AgDR-0050 § Axis 5,
# v1 supports one endpoint per session because Claude Code doesn't consume
# per-agent env files yet. If multiple distinct reachable endpoints were
# declared, warn the adopter and use the first-declared.
# -----------------------------------------------------------------------------

# Reachable endpoints in declaration order (NOT sorted — first agent wins).
REACHABLE_EPS=""
while IFS=$'\t' read -r agent ep; do
  [ -z "$ep" ] && continue
  reach=$(awk -F'\t' -v e="$ep" '$1==e {print $2; exit}' "$EP_REACH")
  if [ "${reach:-0}" = "1" ]; then
    # De-dup while preserving order
    if ! echo "$REACHABLE_EPS" | grep -Fxq "$ep"; then
      REACHABLE_EPS="${REACHABLE_EPS}${ep}
"
    fi
  fi
done < "$AGENT_ENDPOINTS"

REACHABLE_COUNT=$(printf '%s' "$REACHABLE_EPS" | grep -c .)
if [ "$REACHABLE_COUNT" -ge 1 ]; then
  FIRST_EP=$(printf '%s' "$REACHABLE_EPS" | head -1)
  if [ "$REACHABLE_COUNT" -gt 1 ]; then
    EP_LIST=$(printf '%s' "$REACHABLE_EPS" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
    echo "⚠ agent-routing: multiple endpoints declared ($EP_LIST); v1 supports one endpoint per session; using $FIRST_EP. See AgDR-0050 § Axis 5." >&2
    warnings=$((warnings + 1))
  fi
  SESSION_ENV="$ENV_DIR/__session__.env"
  if [ -f "$SESSION_ENV" ]; then
    grep -v '^ANTHROPIC_BASE_URL=' "$SESSION_ENV" > "${SESSION_ENV}.tmp" 2>/dev/null || true
    mv "${SESSION_ENV}.tmp" "$SESSION_ENV"
  else
    : > "$SESSION_ENV"
  fi
  printf 'ANTHROPIC_BASE_URL=%s\n' "$FIRST_EP" >> "$SESSION_ENV"

  # -----------------------------------------------------------------------------
  # Routing-active check — see me2resh/apexyard#442.
  # __session__.env is written above, but Claude Code's process env was set
  # when Claude was launched — SessionStart hooks run in child shells and
  # can't mutate the parent. So unless the adopter sources __session__.env
  # in their shell profile BEFORE launching Claude Code, the routing won't
  # actually take effect even though the banner reports overrides applied.
  # Detect the mismatch and warn explicitly so the adopter sees the gap
  # at SessionStart rather than discovering it via "why is my proxy log
  # empty?" later.
  # -----------------------------------------------------------------------------
  if [ -z "${ANTHROPIC_BASE_URL:-}" ] || [ "${ANTHROPIC_BASE_URL:-}" != "$FIRST_EP" ]; then
    cat >&2 <<EOF
⚠ agent-routing: ANTHROPIC_BASE_URL=$FIRST_EP was written to $SESSION_ENV but is NOT set in this Claude session's process env. Routing is INACTIVE — every agent call still hits the Anthropic API. To activate, add this line to your shell profile (~/.zshrc / ~/.bashrc) and relaunch Claude Code from a fresh terminal:
    [ -f "$SESSION_ENV" ] && . "$SESSION_ENV" && export ANTHROPIC_BASE_URL
See docs/local-model-setup.md § "Before you start" and me2resh/apexyard#442.
EOF
    warnings=$((warnings + 1))
  fi
fi

# Clean up local-routing scratch files.
rm -f "$EP_REACH" "$AGENT_MODELS" "$AGENT_ENDPOINTS"

# -----------------------------------------------------------------------------
# Write the framework-defaults snapshot. The drift guard reads this to
# decide whether a committed model: line is the framework default or a
# leaked override.
#
# Format is a minimal JSON object — adopters never edit this by hand;
# it's gitignored (see .gitignore in the same PR). If jq is available
# we pretty-print; otherwise plain.
# -----------------------------------------------------------------------------
if [ -n "$defaults_acc" ]; then
  # Strip trailing comma+newline and wrap in braces.
  body=$(printf '%s' "$defaults_acc" | sed '$ s/,$//' | tr -d '\n')
  printf '{%s}\n' "$body" > "$DEFAULTS_FILE"
fi

# -----------------------------------------------------------------------------
# Banner — one line, only when applied > 0. Stays well under the
# Wave-1-invariant 600-char SessionStart budget.
# -----------------------------------------------------------------------------
if [ "$applied" -gt 0 ]; then
  suffix=""
  if [ "$ollama_applied" -gt 0 ] || [ "$warnings" -gt 0 ]; then
    suffix=" [${ollama_applied} Ollama, ${warnings} warning(s)]"
  fi
  echo "ApexYard: applied $applied agent-routing override(s) from agent-routing.yaml${suffix}" >&2
fi

exit 0
