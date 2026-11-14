#!/usr/bin/env bash
# me2resh/apexyard#2028 / AgDR-0302 — skill tidy contract.
#
# Checks:
#   1. /spike --close and /prototype --close route to close.md before the
#      creation steps and the active-issue-skill marker. close.md keeps every
#      close behaviour of the old /spike-close and /prototype-close skills.
#   2. /task --batch routes to batch.md before the single-ticket steps.
#      batch.md keeps every behaviour of the old /tickets-batch skill and adds
#      the prefill flags.
#   3. The three old commands are alias stubs that print a deprecation note
#      and load the same mode file.
#   4. /launch-check names and offers a full audit for each WARN or FAIL row,
#      including /audit-deps and /security-review.
#   5. Each of the ten audits has a Usage section. /seo-audit and /geo-audit
#      do not claim that /launch-check fans out to them.
#   6. Every quoted skill count matches the tracked SKILL.md count.
#
# Exit 0 = all pass, exit 1 = at least one failure.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT=${SKILL_MODES_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
SK="$ROOT/.claude/skills"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
has()   { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3"; fi; }
lacks() { if grep -qF -- "$2" "$1"; then bad "$3"; else ok "$3"; fi; }
# line_of FILE FIXED-STRING -> first line number, or 0
line_of() { grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1 | grep . || echo 0; }
before() { # FILE A B LABEL: A appears and comes before B
  local a b
  a=$(line_of "$1" "$2"); b=$(line_of "$1" "$3")
  if [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]; then ok "$4"; else bad "$4 ($a !< $b)"; fi
}
fm_value() { # FILE KEY -> frontmatter value
  awk -v k="$2" 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} index($0, k": ")==1 {print substr($0, length(k)+3); exit}' "$1"
}

# --- 1. close modes ---------------------------------------------------------
for k in spike prototype; do
  skill="$SK/$k/SKILL.md"; mode="$SK/$k/close.md"
  memo="docs/$k-memos/{slug}.md"
  [ -f "$mode" ] && ok "$k: close.md exists" || bad "$k: close.md exists"
  before "$skill" "## Close mode" "### 0. Write the active-issue-skill marker" "$k: close mode is checked before the marker step"
  has "$skill" "\`.claude/skills/$k/close.md\`" "$k: SKILL.md names close.md"
  has "$skill" "Do not write the active-issue-skill marker of step 0." "$k: close mode skips the marker"
  has "$skill" "/$k --close --promote" "$k: usage shows --close --promote"
  has "$skill" "/$k --close --discard" "$k: usage shows --close --discard"
  lacks "$skill" "run /$k-close" "$k: the disposition reminder uses the new command"
  if [ "$(head -n 1 "$mode")" = '---' ]; then bad "$k: close.md has no skill frontmatter"; else ok "$k: close.md has no skill frontmatter"; fi
  has "$mode" "Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact." "$k: close.md carries the shared writing line"
  has "$mode" "tracker_create \"{owner/repo}\" \"[Feature] {title}\"" "$k: PROMOTE files a [Feature] through tracker_create"
  has "$mode" "gh issue close {$k-number}" "$k: the ticket is closed with a cross-ref comment"
  has "$mode" "mkdir -p docs/$k-memos" "$k: DISCARD creates the memo directory"
  has "$mode" "$memo" "$k: DISCARD keeps the memo path"
  has "$mode" "Disposition: DISCARD" "$k: the memo records the DISCARD disposition"
  has "$mode" "disposition: PROMOTE" "$k: the close comment records PROMOTE"
  has "$mode" "Disposition is PROMOTE or DISCARD only." "$k: the two-path rule is kept"
  has "$mode" "Ignore the \`--close\` flag" "$k: the mode flag is not read as a ticket"
done
# The /spike-close text said the spike findings section links back.
has "$SK/spike/close.md" "## Spike findings" "spike: PROMOTE body links back to the spike"
has "$SK/prototype/close.md" "## Prototype findings" "prototype: PROMOTE body links back to the prototype"

# --- 2. task batch mode -----------------------------------------------------
task="$SK/task/SKILL.md"; batch="$SK/task/batch.md"
[ -f "$batch" ] && ok "task: batch.md exists" || bad "task: batch.md exists"
before "$task" "## Batch mode" "### 0. Write the active-issue-skill marker" "task: batch mode is checked before the single-ticket steps"
has "$task" "\`.claude/skills/task/batch.md\`" "task: SKILL.md names batch.md"
has "$task" "It is unchanged." "task: the single-ticket path is unchanged"
has "$task" "Create this ticket? (yes / edit / cancel)" "task: the single-ticket confirmation is kept"
if [ "$(head -n 1 "$batch")" = '---' ]; then bad "task: batch.md has no skill frontmatter"; else ok "task: batch.md has no skill frontmatter"; fi
has "$batch" "over the per-batch cap of 20" "batch: the 20-ticket cap is kept"
has "$batch" "If N < 2, suggest" "batch: the 2-ticket floor is kept"
has "$batch" "Confirm the full batch BEFORE filing any ticket." "batch: one batch confirmation"
has "$batch" "Do **not** roll back already-filed tickets on abort." "batch: partial failure keeps filed tickets"
has "$batch" "On the first \`tracker_create\` failure" "batch: stops on the first failure"
has "$batch" "One \`tracker_create\` per ticket." "batch: one create per ticket"
for t in Feature Bug Chore Refactor Testing CI Docs; do
  has "$batch" "| $t " "batch: mixed type $t is kept"
done
for f in --project --priority --parent --labels; do
  has "$batch" "| \`$f " "batch: prefill flag $f is documented"
done
has "$batch" "A flag never skips a confirmation." "batch: prefill flags keep the confirmations"
c=$(wc -c < "$task" | tr -d ' ')
[ "$c" -le 16000 ] && ok "task: SKILL.md stays under 16000 bytes ($c)" || bad "task: SKILL.md stays under 16000 bytes ($c)"

# --- 3. alias stubs -----------------------------------------------------------
stub_check() { # alias new-command mode-file flag
  local f="$SK/$1/SKILL.md"
  [ -f "$f" ] && ok "$1: alias stub exists" || { bad "$1: alias stub exists"; return; }
  [ "$(fm_value "$f" name)" = "$1" ] && ok "$1: name matches" || bad "$1: name matches"
  case "$(fm_value "$f" description)" in
    "Deprecated alias for \`$2\`."*) ok "$1: description says deprecated alias" ;;
    *) bad "$1: description says deprecated alias" ;;
  esac
  has "$f" "Note: /$1 is deprecated. Use $2" "$1: prints a deprecation note"
  has "$f" "$4 \$ARGUMENTS" "$1: passes its arguments to the new mode"
  has "$f" "\`.claude/skills/$3\`" "$1: loads the same mode file"
  [ -f "$SK/$3" ] && ok "$1: mode file $3 exists" || bad "$1: mode file $3 exists"
}
stub_check spike-close "/spike --close" spike/close.md --close
stub_check prototype-close "/prototype --close" prototype/close.md --close
stub_check tickets-batch "/task --batch" task/batch.md --batch

# --- 4. launch-check routing ---------------------------------------------------
lc="$SK/launch-check/SKILL.md"
has "$lc" "## Routing to full audits" "launch-check: routing section exists"
has "$lc" "## Usage" "launch-check: Usage section exists"
routing=$(awk '/^## Routing to full audits/{f=1;next} f && /^## /{exit} f' "$lc")
for a in /threat-model /audit-deps /security-review /accessibility-audit /compliance-check /analytics-audit /seo-audit /geo-audit /performance-audit /monitoring-audit /docs-audit /mutation-test; do
  if printf '%s\n' "$routing" | grep -qF "\`$a"; then ok "launch-check: routes to $a"; else bad "launch-check: routes to $a"; fi
done
if printf '%s\n' "$routing" | grep -qF 'Run an audit only when the operator says yes.'; then ok "launch-check: offers, never auto-runs"; else bad "launch-check: offers, never auto-runs"; fi

# --- 5. audits: Usage + no fan-out claim -------------------------------------
for a in threat-model accessibility-audit compliance-check analytics-audit seo-audit geo-audit performance-audit monitoring-audit docs-audit mutation-test; do
  if grep -qE '^## Usage' "$SK/$a/SKILL.md"; then ok "$a: Usage section"; else bad "$a: Usage section"; fi
done
for a in seo-audit geo-audit; do
  lacks "$SK/$a/SKILL.md" "fans out to" "$a: no fan-out claim"
done

# --- 6. skill counts -----------------------------------------------------------
actual=$(git -C "$ROOT" ls-files '.claude/skills/*/SKILL.md' | awk -F/ '$3 !~ /^_/' | wc -l | tr -d ' ')
ref="$ROOT/docs/claude-md-reference.md"; wi="$ROOT/docs/whats-inside.md"
grep -qE "^### Available skills \($actual\)" "$ref" && ok "reference count is $actual" || bad "reference count is $actual"
grep -qE "^### The $actual skills" "$wi" && ok "whats-inside heading is $actual" || bad "whats-inside heading is $actual"
n=$(grep -cE "(skills/ +# |\| \`\.claude/skills/\` \| )$actual slash commands" "$wi")
[ "$n" -eq 2 ] && ok "whats-inside tree and table say $actual" || bad "whats-inside tree and table say $actual ($n of 2)"
for f in .claude/rules/skill-first.md .claude/rules/loop-mode.md; do
  if grep -qE '[0-9]+ slash commands' "$ROOT/$f"; then bad "$f quotes no skill count"; else ok "$f quotes no skill count"; fi
done
for a in spike-close prototype-close tickets-batch; do
  grep -qE "^\| \`/$a\` \| Deprecated alias for " "$ref" && ok "reference marks /$a deprecated" || bad "reference marks /$a deprecated"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
