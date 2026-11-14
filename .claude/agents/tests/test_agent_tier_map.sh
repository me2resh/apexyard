#!/bin/bash
# Tests for the tier map (.claude/harness-models.json, schema 2) and
# bin/sync-agent-tiers.sh. me2resh/apexyard#2033, AgDR-0294.
#
# Cases:
#   1. The real map is valid, and the real agent and skill files match it.
#   2. The map covers every tracked agent file and every tracked skill that
#      declares effort. Every mapped file exists.
#   3. Schema: three tiers, a claude and a codex column on each tier, and
#      invalid maps exit 2.
#   4. Reviewers sit on a stronger tier than builders. QA is on the build
#      tier. Each receiver of head-level work declares an effort.
#   5. Sandbox: --check finds drift, the write fixes it, a second write
#      changes nothing, and a one-line tier change moves every agent of
#      that tier.
#   6. Routing: apply-agent-routing.sh still rewrites a model on top of the
#      synced files. --check accepts the override. A write keeps it. A
#      removed override restores the map model.
#   7. Codex adapter: a schema 2 map gives the codex model and
#      model_reasoning_effort. A routing override model passes through.
#
# Usage: bash .claude/agents/tests/test_agent_tier_map.sh

set -u

# Isolate from a live Claude Code session pin and cache (#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../hooks/tests" && pwd)/_test-session-isolation.sh"
export APEXYARD_OPS_DISABLE_PIN=1

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SYNC="$ROOT/bin/sync-agent-tiers.sh"
CODEX_SYNC="$ROOT/bin/sync-codex-adapter.sh"
MAP="$ROOT/.claude/harness-models.json"
ROUTING_HOOK="$ROOT/.claude/hooks/apply-agent-routing.sh"

PASS=0
FAIL=0
FAILED=""

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
mark_pass() { green "  ok   $1"; PASS=$((PASS + 1)); }
mark_fail() {
  red "  FAIL $1: $2" >&2
  FAIL=$((FAIL + 1))
  FAILED="$FAILED
  - $1"
}

for f in "$SYNC" "$CODEX_SYNC" "$MAP" "$ROUTING_HOOK"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

TMP_ROOT=$(mktemp -d)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT

fm() {
  awk -v key="$2" '
    /^---[[:space:]]*$/ { n++; if (n == 2) exit; next }
    n == 1 && index($0, key ":") == 1 { v = substr($0, length(key) + 2); sub(/^[[:space:]]+/, "", v); print v; exit }
  ' "$1"
}

# ---------------------------------------------------------------------------
echo "== 1. Real map and real files"
if bash "$SYNC" --list >/dev/null 2>"$TMP_ROOT/list.err"; then
  mark_pass "real map is valid"
else
  mark_fail "real map is valid" "$(cat "$TMP_ROOT/list.err")"
fi
if bash "$SYNC" --check 2>"$TMP_ROOT/check.err"; then
  mark_pass "real agent and skill files match the tier map"
else
  mark_fail "real files match the tier map" "$(grep -v '^note:' "$TMP_ROOT/check.err")"
fi

# ---------------------------------------------------------------------------
echo "== 2. Coverage"
missing=""
for f in $(git -C "$ROOT" ls-files '.claude/agents/*.md'); do
  n=$(basename "$f" .md)
  jq -e --arg n "$n" '.agents | has($n)' "$MAP" >/dev/null || missing="$missing $n"
done
[ -z "$missing" ] && mark_pass "every tracked agent file is in the map" \
  || mark_fail "every tracked agent file is in the map" "missing:$missing"

missing=""
for f in $(git -C "$ROOT" ls-files '.claude/skills/*/SKILL.md'); do
  [ -n "$(fm "$ROOT/$f" effort)" ] || continue
  [ -n "$(fm "$ROOT/$f" model)" ] && missing="$missing $f(model)"
  n=$(basename "$(dirname "$f")")
  jq -e --arg n "$n" '.skills | has($n)' "$MAP" >/dev/null || missing="$missing $n"
done
[ -z "$missing" ] && mark_pass "every tracked skill that declares effort is in the map" \
  || mark_fail "every tracked skill that declares effort is in the map" "missing:$missing"

absent=""
for n in $(jq -r '.agents | keys[]' "$MAP"); do
  [ -f "$ROOT/.claude/agents/$n.md" ] || absent="$absent $n"
done
for n in $(jq -r '.skills | keys[]' "$MAP"); do
  [ -f "$ROOT/.claude/skills/$n/SKILL.md" ] || absent="$absent $n"
done
[ -z "$absent" ] && mark_pass "every mapped file exists" || mark_fail "every mapped file exists" "absent:$absent"

# ---------------------------------------------------------------------------
echo "== 3. Schema"
if jq -e '
  .schema == 2
  and (.tiers | keys) == ["build", "light", "reason"]
  and ([.tiers[] | (.claude.model | type) == "string" and (.codex.model | type) == "string"] | all)
  and ([.tiers[] | (.claude.effort | IN("low","medium","high","xhigh","max"))] | all)
  and ([.tiers[] | (.codex.effort | IN("minimal","low","medium","high","xhigh"))] | all)
  and .tiers.reason.rank > .tiers.build.rank and .tiers.build.rank > .tiers.light.rank
' "$MAP" >/dev/null; then
  mark_pass "three ranked tiers, each with a claude and a codex model and effort"
else
  mark_fail "tier schema" "$(jq -c '.tiers' "$MAP")"
fi

# A map change is one line: one model per tier per harness, no copy elsewhere.
count=$(grep -o '"model"' "$MAP" | wc -l | tr -d ' ')
[ "$count" -eq 6 ] && mark_pass "each tier model appears once (3 tiers x 2 harnesses)" \
  || mark_fail "each tier model appears once" "found $count model keys"

bad_map() {
  local label="$1" filter="$2" expect="$3" sb="$TMP_ROOT/bad-$4"
  mkdir -p "$sb/.claude/agents"
  jq "$filter" "$MAP" > "$sb/.claude/harness-models.json"
  out=$(bash "$SYNC" --root "$sb" --check 2>&1)
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- "$expect"; then
    mark_pass "invalid map exits 2: $label"
  else
    mark_fail "invalid map exits 2: $label" "rc=$rc out=$out"
  fi
}
bad_map "unknown tier" '.agents["qa-engineer"].tier = "huge"' "agent qa-engineer: tier must name a tier" 1
bad_map "bad agent effort" '.agents["qa-engineer"].effort = "extreme"' "agent qa-engineer: effort must be one of" 2
bad_map "bad claude effort" '.tiers.build.claude.effort = "inherit"' "tier build: claude.effort" 3
bad_map "bad codex effort" '.tiers.build.codex.effort = "max"' "tier build: codex.effort" 4
bad_map "missing model" 'del(.tiers.light.claude.model)' "tier light: claude.model" 5
bad_map "wrong schema" '.schema = 1' "schema must be 2" 6
bad_map "unknown stage" '.skills.debug = "deploy"' "skill debug: stage must name a stage" 7
bad_map "duplicate rank" '.tiers.light.rank = 2' "tier ranks must be unique" 8
bad_map "unsafe agent name" '.agents["../x"] = {"tier": "build"}' "agent ../x: name must match" 9

# ---------------------------------------------------------------------------
echo "== 4. Policy"
rank_of() { jq -r --arg a "$1" '.tiers[.agents[$a].tier].rank' "$MAP"; }
weak=""
for r in code-reviewer security-reviewer solution-architect; do
  for b in backend-engineer frontend-engineer platform-engineer data-engineer qa-engineer; do
    [ "$(rank_of "$r")" -gt "$(rank_of "$b")" ] || weak="$weak $r<=$b"
  done
done
[ -z "$weak" ] && mark_pass "reviewers sit on a stronger tier than builders" \
  || mark_fail "reviewers sit on a stronger tier than builders" "$weak"

[ "$(jq -r '.agents["qa-engineer"].tier' "$MAP")" = build ] \
  && mark_pass "QA is on the build tier" || mark_fail "QA is on the build tier" "$(jq -c '.agents["qa-engineer"]' "$MAP")"

# AgDR-0301: the five receivers of the former head agents keep an effort.
no_effort=""
for h in tech-lead product-manager ui-designer security-reviewer data-engineer; do
  e=$(fm "$ROOT/.claude/agents/$h.md" effort)
  case "$e" in low|medium|high|xhigh|max) ;; *) no_effort="$no_effort $h" ;; esac
done
[ -z "$no_effort" ] && mark_pass "each receiver of head-level work declares an effort" \
  || mark_fail "each receiver of head-level work declares an effort" "$no_effort"

# ---------------------------------------------------------------------------
echo "== 5. Sandbox write and --check"
SB="$TMP_ROOT/sync"
mkdir -p "$SB/.claude/agents" "$SB/.claude/skills/debug" "$SB/.claude/skills/plain"
cat > "$SB/.claude/harness-models.json" <<'JSON'
{
  "schema": 2,
  "tiers": {
    "reason": { "rank": 3, "claude": { "model": "opus",   "effort": "high"   }, "codex": { "model": "gpt-5.5", "effort": "high" } },
    "build":  { "rank": 2, "claude": { "model": "sonnet", "effort": "medium" }, "codex": { "model": "gpt-5.4", "effort": "medium" } },
    "light":  { "rank": 1, "claude": { "model": "haiku",  "effort": "low"    }, "codex": { "model": "gpt-5.4-mini", "effort": "low" } }
  },
  "agents": {
    "code-reviewer": { "tier": "reason" },
    "qa-engineer":   { "tier": "build" },
    "light-helper":  { "tier": "light", "effort": "inherit" },
    "tech-lead":     { "tier": "reason", "effort": "medium" }
  },
  "stages": { "build": "medium" },
  "skills": { "debug": "build" }
}
JSON
cat > "$SB/.claude/agents/code-reviewer.md" <<'MD'
---
name: code-reviewer
model: opus
effort: high
---

# Rex

---

model: body text stays
MD
cat > "$SB/.claude/agents/qa-engineer.md" <<'MD'
---
name: qa-engineer
model: haiku
tools: Bash
---

# Salim
MD
cat > "$SB/.claude/agents/light-helper.md" <<'MD'
---
name: light-helper
model: haiku
effort: low
---

# Light helper
MD
cat > "$SB/.claude/agents/tech-lead.md" <<'MD'
---
name: tech-lead
tools: Bash
---

# Hisham
MD
cat > "$SB/.claude/agents/custom.md" <<'MD'
---
name: custom
model: haiku
---
MD
cat > "$SB/.claude/skills/debug/SKILL.md" <<'MD'
---
name: debug
effort: high
---

# Debug
MD
cat > "$SB/.claude/skills/plain/SKILL.md" <<'MD'
---
name: plain
---
MD
cp "$SB/.claude/agents/code-reviewer.md" "$TMP_ROOT/rex.before"
cp "$SB/.claude/agents/custom.md" "$TMP_ROOT/custom.before"
cp "$SB/.claude/skills/plain/SKILL.md" "$TMP_ROOT/plain.before"

out=$(bash "$SYNC" --root "$SB" --check 2>&1); rc=$?
if [ "$rc" -eq 1 ] \
  && printf '%s' "$out" | grep -q "qa-engineer.md model: haiku (map: sonnet)" \
  && printf '%s' "$out" | grep -q "qa-engineer.md effort: (none) (map: medium)" \
  && printf '%s' "$out" | grep -q "light-helper.md effort: low (map: (none))" \
  && printf '%s' "$out" | grep -q "tech-lead.md model: (none) (map: opus)" \
  && printf '%s' "$out" | grep -q "debug/SKILL.md effort: high (map: medium)" \
  && printf '%s' "$out" | grep -q "custom.md is not in the tier map"; then
  mark_pass "--check exits 1 and names each drift"
else
  mark_fail "--check exits 1 and names each drift" "rc=$rc out=$out"
fi
[ "$(fm "$SB/.claude/agents/qa-engineer.md" model)" = haiku ] \
  && mark_pass "--check writes nothing" || mark_fail "--check writes nothing" "qa model changed"

out=$(bash "$SYNC" --root "$SB" 2>&1); rc=$?
if [ "$rc" -eq 0 ] \
  && [ "$(fm "$SB/.claude/agents/qa-engineer.md" model)" = sonnet ] \
  && [ "$(fm "$SB/.claude/agents/qa-engineer.md" effort)" = medium ] \
  && [ -z "$(fm "$SB/.claude/agents/light-helper.md" effort)" ] \
  && [ "$(fm "$SB/.claude/agents/tech-lead.md" model)" = opus ] \
  && [ "$(fm "$SB/.claude/agents/tech-lead.md" effort)" = medium ] \
  && [ "$(fm "$SB/.claude/skills/debug/SKILL.md" effort)" = medium ]; then
  mark_pass "write sets model and effort, and removes an inherit effort"
else
  mark_fail "write sets model and effort" "rc=$rc out=$out"
fi
if [ "$(sed -n 3,4p "$SB/.claude/agents/qa-engineer.md")" = "model: sonnet
effort: medium" ]; then
  mark_pass "a new effort line goes after the model line"
else
  mark_fail "a new effort line goes after the model line" "$(cat "$SB/.claude/agents/qa-engineer.md")"
fi
cmp -s "$TMP_ROOT/rex.before" "$SB/.claude/agents/code-reviewer.md" \
  && mark_pass "a matching file is byte-identical, body lines stay" \
  || mark_fail "matching file unchanged" "$(diff "$TMP_ROOT/rex.before" "$SB/.claude/agents/code-reviewer.md")"
cmp -s "$TMP_ROOT/custom.before" "$SB/.claude/agents/custom.md" \
  && cmp -s "$TMP_ROOT/plain.before" "$SB/.claude/skills/plain/SKILL.md" \
  && mark_pass "unmapped agent and skill files stay unchanged" \
  || mark_fail "unmapped files stay unchanged" "custom or plain changed"

bash "$SYNC" --root "$SB" --check >/dev/null 2>&1 \
  && mark_pass "--check exits 0 after the write" || mark_fail "--check exits 0 after the write" "drift remains"
out=$(bash "$SYNC" --root "$SB" 2>&1)
printf '%s' "$out" | grep -q "0 file(s) updated" \
  && mark_pass "a second write changes nothing" || mark_fail "a second write changes nothing" "$out"

# One-line change: move the reason tier to a new model.
sed -i.bak 's/"model": "opus"/"model": "fable"/' "$SB/.claude/harness-models.json"
rm -f "$SB/.claude/harness-models.json.bak"
bash "$SYNC" --root "$SB" >/dev/null 2>&1
if [ "$(fm "$SB/.claude/agents/code-reviewer.md" model)" = fable ] \
  && [ "$(fm "$SB/.claude/agents/tech-lead.md" model)" = fable ] \
  && [ "$(fm "$SB/.claude/agents/qa-engineer.md" model)" = sonnet ]; then
  mark_pass "a one-line tier change moves every agent of that tier"
else
  mark_fail "one-line tier change" "rex=$(fm "$SB/.claude/agents/code-reviewer.md" model)"
fi

# A mapped file that does not exist is drift.
jq '.agents["ghost"] = {"tier": "build"}' "$SB/.claude/harness-models.json" > "$TMP_ROOT/ghost.json"
cp "$TMP_ROOT/ghost.json" "$SB/.claude/harness-models.json"
out=$(bash "$SYNC" --root "$SB" --check 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "ghost.md is in the tier map but the file does not exist" \
  && mark_pass "a missing mapped file exits 1" || mark_fail "a missing mapped file exits 1" "rc=$rc out=$out"

# ---------------------------------------------------------------------------
echo "== 6. Routing override on top of the synced files"
FORK="$TMP_ROOT/fork"
mkdir -p "$FORK/.claude/hooks" "$FORK/.claude/agents" "$FORK/bin" "$FORK/projects"
(
  cd "$FORK" || exit 1
  git init -q
  git config user.email "test@example.com"
  git config user.name "test"
  touch onboarding.yaml projects/ideas-backlog.md
  printf 'version: 1\nprojects: []\n' > apexyard.projects.yaml
  for lib in _lib-ops-root.sh _lib-portfolio-paths.sh _lib-read-config.sh; do
    cp "$ROOT/.claude/hooks/$lib" ".claude/hooks/$lib"
  done
  cp "$ROOT/.claude/project-config.defaults.json" .claude/project-config.defaults.json
  cp "$ROUTING_HOOK" .claude/hooks/apply-agent-routing.sh
  cp "$SYNC" bin/sync-agent-tiers.sh
  cp "$SB/.claude/harness-models.json" .claude/harness-models.json
  jq 'del(.agents.ghost) | del(.skills) | .stages = {}' .claude/harness-models.json > map.tmp
  mv map.tmp .claude/harness-models.json
  for a in code-reviewer qa-engineer light-helper tech-lead; do
    printf -- '---\nname: %s\nmodel: haiku\n---\n\n# %s\n' "$a" "$a" > ".claude/agents/$a.md"
  done
  bash bin/sync-agent-tiers.sh >/dev/null 2>&1
  printf '.claude/agents/.framework-defaults.json\n.claude/session/\nagent-routing.yaml\n' > .gitignore
  git add -A
  git commit -q -m "fixture: synced agents"
) || mark_fail "routing fixture" "setup failed"

cat > "$FORK/agent-routing.yaml" <<'YAML'
version: 1
agents:
  qa-engineer:
    model: ollama/qwen3
YAML
banner=$(cd "$FORK" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
if [ "$(fm "$FORK/.claude/agents/qa-engineer.md" model)" = "ollama/qwen3" ] \
  && printf '%s' "$banner" | grep -q "applied 1 agent-routing override"; then
  mark_pass "routing hook rewrites the synced model"
else
  mark_fail "routing hook rewrites the synced model" "model=$(fm "$FORK/.claude/agents/qa-engineer.md" model) banner=$banner"
fi
out=$(cd "$FORK" && bash bin/sync-agent-tiers.sh --check 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "qa-engineer.md model: ollama/qwen3 is a routing override" \
  && mark_pass "--check accepts an active routing override" \
  || mark_fail "--check accepts an active routing override" "rc=$rc out=$out"
(cd "$FORK" && bash bin/sync-agent-tiers.sh >/dev/null 2>&1)
[ "$(fm "$FORK/.claude/agents/qa-engineer.md" model)" = "ollama/qwen3" ] \
  && [ "$(fm "$FORK/.claude/agents/qa-engineer.md" effort)" = medium ] \
  && mark_pass "a write keeps the routing override and keeps the map effort" \
  || mark_fail "a write keeps the routing override" "$(cat "$FORK/.claude/agents/qa-engineer.md")"

# Effort drift is still found while a routing override is active.
sed -i.bak 's/^effort: medium$/effort: low/' "$FORK/.claude/agents/qa-engineer.md"
rm -f "$FORK/.claude/agents/qa-engineer.md.bak"
out=$(cd "$FORK" && bash bin/sync-agent-tiers.sh --check 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "qa-engineer.md effort: low (map: medium)" \
  && mark_pass "effort drift is found on a routed agent" \
  || mark_fail "effort drift is found on a routed agent" "rc=$rc out=$out"
(cd "$FORK" && bash bin/sync-agent-tiers.sh >/dev/null 2>&1)

printf 'version: 1\nagents: {}\n' > "$FORK/agent-routing.yaml"
(cd "$FORK" && bash .claude/hooks/apply-agent-routing.sh >/dev/null 2>&1 < /dev/null)
if [ "$(fm "$FORK/.claude/agents/qa-engineer.md" model)" = sonnet ] \
  && (cd "$FORK" && bash bin/sync-agent-tiers.sh --check >/dev/null 2>&1); then
  mark_pass "a removed override restores the map model and --check passes"
else
  mark_fail "a removed override restores the map model" "$(cat "$FORK/.claude/agents/qa-engineer.md")"
fi

# ---------------------------------------------------------------------------
echo "== 7. Codex adapter reads the tier map"
CX="$TMP_ROOT/codex"
mkdir -p "$CX/.claude/agents" "$CX/.claude/skills"
printf '{ "hooks": {} }\n' > "$CX/.claude/settings.json"
cp "$FORK/.claude/harness-models.json" "$CX/.claude/harness-models.json"
cp "$FORK/.claude/agents/code-reviewer.md" "$FORK/.claude/agents/light-helper.md" "$CX/.claude/agents/"
printf -- '---\nname: qa-engineer\ndescription: QA.\nmodel: ollama/qwen3\n---\n\n# QA\n' > "$CX/.claude/agents/qa-engineer.md"
if bash "$CODEX_SYNC" --root "$CX" >"$TMP_ROOT/codex.out" 2>&1; then
  rex="$CX/.codex/agents/code-reviewer.toml"
  light="$CX/.codex/agents/light-helper.toml"
  qa="$CX/.codex/agents/qa-engineer.toml"
  grep -qx 'model = "gpt-5.5"' "$rex" && grep -qx 'model_reasoning_effort = "high"' "$rex" \
    && mark_pass "codex agent gets the tier codex model and effort" \
    || mark_fail "codex agent gets the tier codex model and effort" "$(grep '^model' "$rex")"
  grep -qx 'model = "gpt-5.4-mini"' "$light" && ! grep -q '^model_reasoning_effort' "$light" \
    && mark_pass "an inherit effort writes no codex effort line" \
    || mark_fail "an inherit effort writes no codex effort line" "$(grep '^model' "$light")"
  grep -qx 'model = "ollama/qwen3"' "$qa" \
    && mark_pass "a routing override model passes through to codex unchanged" \
    || mark_fail "a routing override model passes through" "$(grep '^model' "$qa")"
else
  mark_fail "codex adapter generation" "$(cat "$TMP_ROOT/codex.out")"
fi

# ---------------------------------------------------------------------------
echo
echo "===== test_agent_tier_map.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf 'Failed cases:%s\n' "$FAILED"
  exit 1
fi
exit 0
