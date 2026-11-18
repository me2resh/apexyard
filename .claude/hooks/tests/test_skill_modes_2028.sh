#!/usr/bin/env bash
# me2resh/apexyard#2028 / AgDR-0302 — skill modes and alias stubs.
#
# This suite tests what the agent does, not only what the text says.
#   1. Routing. It reads the Modes table of /spike, /prototype and /task and
#      routes sample argument lists with it. The flag works in any position.
#      The table comes before step 0, so a mode never writes the marker.
#   2. Aliases. It reads the table of each alias stub and resolves the mode
#      file by the ops-root path and by the path relative to the stub. Both
#      must be the same file that the sibling skill routes to.
#   3. Override. It runs the real link-custom-skills.sh in a sandbox fork
#      with custom /spike, /prototype and /task overrides. Every alias must
#      still resolve its mode file. An override that copies the Modes
#      section must still route.
#   4. Bodies. When the base commit is in history, every fenced block of each
#      mode file must equal the old skill's blocks (command-name lines aside),
#      and the step headings must match.
#   5. /launch-check routing, the ten audit Usage sections, and the counts.
#
# Exit 0 = all pass, exit 1 = at least one failure.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT=${SKILL_MODES_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
SK="$ROOT/.claude/skills"
BASE_SHA=2812c155   # dev before #2028; holds the old /spike-close, /prototype-close, /tickets-batch
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
check() { local label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }
has()   { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3"; fi; }
lacks() { if grep -qF -- "$2" "$1"; then bad "$3"; else ok "$3"; fi; }
line_of() { grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1 | grep . || echo 0; }
fm_value() {
  awk -v k="$2" 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} index($0, k": ")==1 {print substr($0, length(k)+3); exit}' "$1"
}
# Rows of the markdown table that follows a marker comment, as "c1<TAB>c2<TAB>c3".
table_after() { # file marker
  awk -v m="$2" '
    index($0, m) { on=1; next }
    on && /^[[:space:]]*\|/ {
      line=$0; sub(/^[[:space:]]*\|/, "", line); sub(/\|[[:space:]]*$/, "", line)
      n=split(line, c, "|"); out=""
      for (i=1; i<=n; i++) { v=c[i]; gsub(/^[[:space:]`]+|[[:space:]`]+$/, "", v); out = out (i>1 ? "\t" : "") v }
      if (out ~ /^-+(\t-+)*$/ || out ~ /^Flag\t/ || out ~ /^Mode file/) next
      print out; seen=1; next
    }
    on && seen { exit }
    on && NF && $0 !~ /^[[:space:]]*\|/ && seen { exit }
  ' "$1"
}
# route <skill-dir> <args...>: print the mode file the Modes table selects, or nothing.
route() {
  local skill=$1; shift
  local rows word flag file
  rows=$(table_after "$skill/SKILL.md" "<!-- skill-modes:route")
  for word in "$@"; do
    while IFS=$'\t' read -r flag file; do
      [ -n "$flag" ] || continue
      if [ "$word" = "$flag" ]; then printf '%s\n' "$file"; return 0; fi
    done <<< "$rows"
  done
  return 0
}

# --- 1. routing ---------------------------------------------------------------
route_case() { # skill expected-file-or-empty label args...
  local skill=$1 want=$2 label=$3; shift 3
  local got
  got=$(route "$SK/$skill" "$@")
  if [ "$got" = "$want" ]; then ok "$skill routes [$*] -> ${want:-creation flow}"; else bad "$skill routes [$*]: got '${got}' want '${want}' ($label)"; fi
}
for k in spike prototype; do
  mf=".claude/skills/_lib-modes/$k-close.md"
  route_case "$k" "$mf" first   --close --promote 142
  route_case "$k" "$mf" middle  142 --close --discard
  route_case "$k" "$mf" last    --discard owner/repo#142 --close
  route_case "$k" ""    title   Will library X handle 10k events
  route_case "$k" ""    near    --closed --promote
  [ -f "$ROOT/$mf" ] && ok "$k: routed mode file exists" || bad "$k: routed mode file exists"
done
tf=".claude/skills/_lib-modes/task-batch.md"
route_case task "$tf" first  --batch ./batch.md
route_case task "$tf" later  --priority P1 --batch ./batch.md
route_case task "$tf" last   --project owner/repo File the auth tickets --batch
route_case task ""    title  Set up PR-triggered CI pipeline
[ -f "$ROOT/$tf" ] && ok "task: routed mode file exists" || bad "task: routed mode file exists"
for k in spike prototype task; do
  r=$(line_of "$SK/$k/SKILL.md" "<!-- skill-modes:route"); m=$(line_of "$SK/$k/SKILL.md" "### 0. Write the active-issue-skill marker")
  if [ "$r" -gt 0 ] && [ "$m" -gt 0 ] && [ "$r" -lt "$m" ]; then ok "$k: modes are routed before the marker step"; else bad "$k: modes are routed before the marker step ($r !< $m)"; fi
done

# --- 2. aliases -----------------------------------------------------------------
alias_case() { # root alias sibling flag label-prefix [expected-mode-file]
  local root=$1 alias=$2 sib=$3 flag=$4 pre=$5 fixed=${6-}
  local stub="$root/.claude/skills/$alias/SKILL.md" row opsp relp args want
  [ -f "$stub" ] || { bad "$pre$alias: stub exists"; return; }
  row=$(table_after "$stub" "<!-- skill-modes:alias" | head -n 1)
  IFS=$'\t' read -r opsp relp args <<< "$row"
  if [ -n "$fixed" ]; then want=$fixed; else want=$(route "$root/.claude/skills/$sib" "$flag"); fi
  [ -n "$opsp" ] && [ -f "$root/$opsp" ] && ok "$pre$alias: ops-root path resolves ($opsp)" || bad "$pre$alias: ops-root path resolves ('$opsp')"
  [ -n "$relp" ] && [ -f "$root/.claude/skills/$alias/$relp" ] && ok "$pre$alias: relative path resolves ($relp)" || bad "$pre$alias: relative path resolves ('$relp')"
  if [ -n "$opsp" ] && [ -n "$relp" ] && [ "$root/$opsp" -ef "$root/.claude/skills/$alias/$relp" ]; then ok "$pre$alias: both paths are one file"; else bad "$pre$alias: both paths are one file"; fi
  [ "$opsp" = "$want" ] && ok "$pre$alias: same mode file as /$sib $flag" || bad "$pre$alias: same mode file as /$sib $flag ('$opsp' vs '$want')"
  case "$args" in "$flag \$ARGUMENTS") ok "$pre$alias: passes $flag and its arguments" ;; *) bad "$pre$alias: passes $flag and its arguments ('$args')" ;; esac
}
alias_case "$ROOT" spike-close spike --close ""
alias_case "$ROOT" prototype-close prototype --close ""
alias_case "$ROOT" tickets-batch task --batch ""
for a in spike-close:spike prototype-close:prototype tickets-batch:task; do
  al=${a%%:*}; sib=${a##*:}; f="$SK/$al/SKILL.md"
  [ "$(fm_value "$f" name)" = "$al" ] && ok "$al: name matches" || bad "$al: name matches"
  case "$(fm_value "$f" description)" in "Deprecated alias for "*) ok "$al: description says deprecated alias" ;; *) bad "$al: description says deprecated alias" ;; esac
  has "$f" "Note: /$al is deprecated." "$al: prints a deprecation note"
  has "$f" "v5.12.0 removes" "$al: names the removal release"
  has "$f" "needs a Skill($sib) permission" "$al: notes the permission for the new command"
done

# --- 3. override (runs the real link-custom-skills.sh) ----------------------------
HOOKS="$ROOT/.claude/hooks"
if [ -f "$HOOKS/link-custom-skills.sh" ] && [ -f "$HOOKS/_lib-ops-root.sh" ]; then
  sb=$(mktemp -d); sb=$(cd "$sb" && pwd -P)
  priv=$(mktemp -d); priv=$(cd "$priv" && pwd -P)
  trap 'rm -rf "$sb" "$priv"' EXIT
  (
    cd "$sb" || exit 1
    git init -q
    touch .apexyard-fork onboarding.yaml
    printf 'version: 1\nprojects: []\n' > apexyard.projects.yaml
    mkdir -p projects .claude/hooks .claude/skills
    printf '# ideas\n' > projects/ideas-backlog.md
    for f in link-custom-skills.sh _lib-portfolio-paths.sh _lib-read-config.sh _lib-ops-root.sh; do cp "$HOOKS/$f" .claude/hooks/; done
    cp "$ROOT/.claude/project-config.defaults.json" .claude/
    for d in spike prototype task spike-close prototype-close tickets-batch _lib-modes; do cp -R "$SK/$d" .claude/skills/; done
  )
  for k in spike prototype task; do
    mkdir -p "$priv/custom-skills/$k"
    printf -- '---\nname: %s\ndescription: adopter override\n---\n# Custom /%s\n' "$k" "$k" > "$priv/custom-skills/$k/SKILL.md"
  done
  # The task override copies the Modes section, as the section tells adopters to do.
  awk '/^## Modes$/{on=1} on && /^## Process$/{exit} on' "$SK/task/SKILL.md" >> "$priv/custom-skills/task/SKILL.md"
  printf '{ "portfolio": { "custom_skills_dir": "%s/custom-skills" } }\n' "$priv" > "$sb/.claude/project-config.json"
  ( cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 bash .claude/hooks/link-custom-skills.sh >/dev/null 2>&1 )
  if [ -L "$sb/.claude/skills/task" ] && [ -d "$sb/.claude/skill-framework-bak/task" ]; then
    ok "override: link-custom-skills.sh replaced /task and moved the framework copy"
    # The spike and prototype overrides have no Modes section; the aliases must still work.
    alias_case "$sb" spike-close spike --close "override: " ".claude/skills/_lib-modes/spike-close.md"
    alias_case "$sb" prototype-close prototype --close "override: " ".claude/skills/_lib-modes/prototype-close.md"
    alias_case "$sb" tickets-batch task --batch "override: "
    got=$(route "$sb/.claude/skills/task" --priority P1 --batch ./b.md)
    [ "$got" = "$tf" ] && [ -f "$sb/$got" ] && ok "override: a /task override with the Modes section still routes --batch" || bad "override: a /task override with the Modes section still routes --batch ('$got')"
  else
    bad "override: link-custom-skills.sh did not set up the override sandbox"
  fi
else
  bad "override: link-custom-skills.sh or _lib-ops-root.sh missing"
fi

# --- 4. bodies against the base commit --------------------------------------------------
fences() { awk '/^```/{ if (on) { on=0; print "----" } else on=1; next } on' | grep -vE 'spike-close|prototype-close|spike --close|prototype --close|tickets-batch|task --batch'; }
steps() { grep -E '^#{2,4} ' | grep -v '^### Prefill flags'; }
if git -C "$ROOT" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  for p in spike-close:spike-close prototype-close:prototype-close tickets-batch:task-batch; do
    old=${p%%:*}; new="$SK/_lib-modes/${p##*:}.md"
    if diff <(git -C "$ROOT" show "$BASE_SHA:.claude/skills/$old/SKILL.md" | fences) <(fences < "$new") >/dev/null; then ok "$old: every fenced block kept in ${p##*:}.md"; else bad "$old: fenced blocks differ from $BASE_SHA"; fi
    if diff <(git -C "$ROOT" show "$BASE_SHA:.claude/skills/$old/SKILL.md" | steps) <(steps < "$new") >/dev/null; then ok "$old: every step heading kept"; else bad "$old: step headings differ from $BASE_SHA"; fi
  done
else
  echo "SKIP: base commit $BASE_SHA not in history; body comparison not run"
fi
for m in spike-close prototype-close task-batch; do
  f="$SK/_lib-modes/$m.md"
  [ "$(head -n 1 "$f")" != '---' ] && ok "$m.md: no skill frontmatter" || bad "$m.md: no skill frontmatter"
done
[ ! -f "$SK/_lib-modes/SKILL.md" ] && ok "_lib-modes is not a command (no SKILL.md)" || bad "_lib-modes is not a command (no SKILL.md)"
c=$(wc -c < "$SK/task/SKILL.md" | tr -d ' ')
[ "$c" -le 16000 ] && ok "task: SKILL.md stays under 16000 bytes ($c)" || bad "task: SKILL.md stays under 16000 bytes ($c)"

# --- 5. /launch-check, audits, counts ---------------------------------------------------
lc="$SK/launch-check/SKILL.md"
routing=$(awk '/^## Routing to full audits/{f=1;next} f && /^## /{exit} f' "$lc")
for a in /threat-model /audit-deps /security-review /accessibility-audit /compliance-check /analytics-audit /seo-audit /geo-audit /performance-audit /monitoring-audit /docs-audit /mutation-test; do
  if printf '%s\n' "$routing" | grep -qF "\`$a"; then ok "launch-check: routes to $a"; else bad "launch-check: routes to $a"; fi
done
if printf '%s\n' "$routing" | grep -qF 'A bare "yes" does not select anything.'; then ok "launch-check: a bare yes selects nothing"; else bad "launch-check: a bare yes selects nothing"; fi
has "$lc" "Create tickets for the 2 blocking items" "launch-check: tickets are a separate menu option"
lacks "$lc" "run one? yes / pick / no" "launch-check: the ambiguous prompt is gone"
has "$lc" '`/security-review <number> <owner/repo>`' "launch-check: /security-review gets the repository"
for a in threat-model accessibility-audit compliance-check analytics-audit seo-audit geo-audit performance-audit monitoring-audit docs-audit mutation-test; do
  if grep -qE '^## Usage' "$SK/$a/SKILL.md"; then ok "$a: Usage section"; else bad "$a: Usage section"; fi
done
for a in seo-audit geo-audit mutation-test; do
  lacks "$SK/$a/SKILL.md" "fans out to" "$a: no fan-out claim"
done
lacks "$SK/mutation-test/SKILL.md" "dispatches automatically" "mutation-test: no automatic dispatch claim"

actual=$(git -C "$ROOT" ls-files '.claude/skills/*/SKILL.md' | awk -F/ '$3 !~ /^_/' | wc -l | tr -d ' ')
ref="$ROOT/docs/claude-md-reference.md"; wi="$ROOT/docs/whats-inside.md"
check "reference count is $actual" grep -qE "^### Available skills \($actual\)" "$ref"
check "whats-inside heading is $actual" grep -qE "^### The $actual skills" "$wi"
n=$(grep -cE "(skills/ +# |\| \`\.claude/skills/\` \| )$actual slash commands" "$wi")
[ "$n" -eq 2 ] && ok "whats-inside tree and table say $actual" || bad "whats-inside tree and table say $actual ($n of 2)"
for f in .claude/rules/skill-first.md .claude/rules/loop-mode.md; do
  if grep -qE '[0-9]+ slash commands' "$ROOT/$f"; then bad "$f quotes no skill count"; else ok "$f quotes no skill count"; fi
done
for a in spike-close prototype-close tickets-batch; do
  check "reference marks /$a deprecated" grep -qE "^\| \`/$a\` \| Deprecated alias for " "$ref"
done
agdr="$ROOT/docs/agdr/AgDR-0302-skill-modes-and-alias-stubs.md"
has "$agdr" "v5.12.0, the release after that, removes them." "AgDR-0302 names the removal release"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
