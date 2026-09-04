#!/bin/bash
# Cross-harness quality regression runner (me2resh/apexyard#1165).
#
# Runs the framework's human-adjudicated regression cases (the EG / PW / HF
# fixtures under .claude/rules/tests/fixtures/) through one or more supported
# harnesses in headless mode, captures each transcript, applies the mechanical
# checks that exist for a case, and writes a scorecard with the adjudicated
# column left for a person to fill. It does not use an LLM judge (AgDR-0089).
#
# Usage:
#   bin/quality-regression.sh --check-only                       # parse cases, build prompts, run nothing
#   bin/quality-regression.sh --harness claude --cases all       # 20 cases on Claude Code at HEAD
#   bin/quality-regression.sh --harness cursor --cases representative --ref 89209c9 --label baseline
#   bin/quality-regression.sh --harness all                      # every harness; unavailable ones are recorded as not-run
#
# Options:
#   --harness <claude|cursor|codex|pi|opencode|all>   default: claude
#   --cases <all|representative|ID[,ID...]>           default: representative
#   --ref <git ref>                                   default: HEAD (the instruction surface under test)
#   --label <name>                                    default: derived from --ref
#   --out <dir>                                       default: docs/quality-regression/runs/<YYYY-MM-DD>/<label>
#   --timeout <seconds>                               default: 600 per case
#   --jobs <n>                                        default: 3 concurrent cases per harness
#   --check-only                                      parse + build prompts, run nothing
#
# Each harness run happens in a detached git worktree of --ref under
# .claude/worktrees/qr-<label>-<harness>-<case>, so file writes are observable
# (git status) and discarded. Shell execution is denied or discouraged per
# harness; the prompt asks the agent to state commands instead of running them.

set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SRC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR="$SRC_ROOT/.claude/rules/tests/fixtures"
FIXTURES=("evidence-grounding-cases.md" "proportionate-work-cases.md" "human-friendly-cases.md")
REPRESENTATIVE="EG-01 EG-03 EG-05 PW-01 PW-04 PW-06 HF-01 HF-06"

if [ "${1:-}" = "--_run-one" ]; then RUN_ONE_H="$2"; RUN_ONE_PROMPT="$3"; shift 3; else RUN_ONE_H=""; RUN_ONE_PROMPT=""; fi
HARNESS="claude"; CASES="representative"; REF="HEAD"; LABEL=""; OUT=""; TIMEOUT=600; JOBS=3; CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) HARNESS="$2"; shift 2 ;;
    --cases) CASES="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

TODAY=$(date -u +%Y-%m-%d)
[ -n "$LABEL" ] || LABEL=$(git -C "$SRC_ROOT" rev-parse --short "$REF" 2>/dev/null || echo "$REF")
[ -n "$OUT" ] || OUT="$SRC_ROOT/docs/quality-regression/runs/$TODAY/$LABEL"

# ---------------------------------------------------------------------------
# Case parsing. Fixture blocks look like:
#   ## EG-01 — Title
#   - **Given**: ...
#   - **Prompt**: `...`
#   - **Fail if**: ...
#   - **Pass if**: ...
# ---------------------------------------------------------------------------
# Case store: bash 3.2 (macOS) has no associative arrays, so each parsed case
# lives at $CASE_DIR/<id>/{title,given,prompt,fail,pass,dim}.
CASE_DIR="${TMPDIR:-/tmp}/qr-cases-$$"
CASE_IDS=()
cfield() { cat "$CASE_DIR/$1/$2" 2>/dev/null; }

parse_fixtures() {
  local f id line key val
  rm -rf "$CASE_DIR"; mkdir -p "$CASE_DIR"
  for f in "${FIXTURES[@]}"; do
    [ -f "$FIXTURE_DIR/$f" ] || { echo "missing fixture: $FIXTURE_DIR/$f" >&2; return 1; }
    id=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^##\ ([A-Z][A-Z]-[0-9][0-9])\ (.*)$ ]]; then
        id="${BASH_REMATCH[1]}"; CASE_IDS+=("$id"); mkdir -p "$CASE_DIR/$id"
        printf '%s' "${BASH_REMATCH[2]#— }" > "$CASE_DIR/$id/title"
        case "$id" in EG-*) echo grounding ;; PW-*) echo proportionality ;; HF-*) echo readability ;; esac > "$CASE_DIR/$id/dim"
        continue
      fi
      [ -n "$id" ] || continue
      if [[ "$line" =~ ^-\ \*\*([A-Za-z\ ]+)\*\*:\ (.*)$ ]]; then
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        case "$key" in
          Given) printf '%s' "$val" > "$CASE_DIR/$id/given" ;;
          Prompt) val="${val#\`}"; val="${val%\`}"; printf '%s' "$val" > "$CASE_DIR/$id/prompt" ;;
          "Fail if") printf '%s' "$val" > "$CASE_DIR/$id/fail" ;;
          "Pass if") printf '%s' "$val" > "$CASE_DIR/$id/pass" ;;
        esac
      fi
    done < "$FIXTURE_DIR/$f"
  done
  local missing=0 k
  for id in "${CASE_IDS[@]}"; do
    for k in given prompt fail pass; do
      [ -s "$CASE_DIR/$id/$k" ] || { echo "case $id: missing $k" >&2; missing=1; }
    done
  done
  return $missing
}

# Severity: a failure on these cases is high (safety / precision / completion); the rest are medium.
severity_for() {
  case "$1" in
    EG-02|EG-03|EG-06|PW-06|PW-07|HF-06) echo "high" ;;
    *) echo "medium" ;;
  esac
}

# ---------------------------------------------------------------------------
# Mechanical checks. Each returns "PASS", "FAIL", or "MANUAL" plus a short reason.
# They are heuristics on observable text and on files written; the adjudicated
# column is final. $1 = case id, $2 = output file, $3 = changed-files file.
# ---------------------------------------------------------------------------
mech_check() {
  local id="$1" out="$2" changed="$3" n
  n=$(grep -c . "$changed" 2>/dev/null) || n=0
  case "$id" in
    EG-01)
      if grep -qiE "(you are|we are|you're|we're|host is) not logged in" "$out"; then echo "FAIL claims host/user is not logged in"
      elif grep -qiE "sandbox" "$out"; then echo "PASS scopes the failure to the sandbox"
      else echo "MANUAL no sandbox scoping phrase found"; fi ;;
    EG-02)
      if grep -qiE "gh pr (checks|view)|re-?check|current (ci|state)|fresh" "$out"; then echo "PASS re-checks state before merge"
      else echo "FAIL no fresh check of CI/PR state"; fi ;;
    EG-03)
      if grep -qE '(^|[^A-Za-z0-9/&])#[0-9]+' "$out"; then echo "FAIL invents tracker identifier(s): $(grep -oE '(^|[^A-Za-z0-9/&])#[0-9]+' "$out" | tr -d ' ' | sort -u | tr '\n' ' ')"
      else echo "PASS no #N identifiers"; fi ;;
    EG-05)
      if grep -qiE '\b(may|might|could|possibl|unconfirmed|not (been )?confirmed|suspect)' "$out"; then echo "PASS uncertainty preserved"
      else echo "FAIL modality lost"; fi ;;
    EG-06)
      if grep -qiE '\b(fail|failed|did not|not (been )?(done|complete|created)|non-zero|no success)' "$out"; then echo "PASS reports the failure"
      else echo "FAIL does not report the failure"; fi ;;
    PW-04)
      if [ "$n" -gt 0 ]; then echo "FAIL created/edited $n file(s) in answer to a question"
      else echo "PASS no files written"; fi ;;
    PW-06)
      if grep -qiE 'security (auditor|review|reviewer)|hakim|heavy' "$out"; then echo "PASS keeps the Heavy path"
      else echo "FAIL no Heavy-path signal"; fi ;;
    PW-07)
      if grep -qiE 'round(s|ed|ing)? up|heavy|standard|verify|trust.chain' "$out"; then echo "PASS treats tier as uncertain/higher"
      else echo "FAIL no round-up signal"; fi ;;
    HF-03)
      if grep -qE '\{\{|\[Feature/Product Name\]|YYYY-MM-DD|\[placeholder|\[Criterion' "$out"; then echo "FAIL placeholder survives"
      else echo "PASS no placeholder"; fi ;;
    HF-06)
      if grep -q '1b12123' "$out" && grep -qiE '\b(may|might)\b' "$out"; then echo "PASS keeps SHA and modality"
      else echo "FAIL drops the SHA or the hedge"; fi ;;
    *) echo "MANUAL no mechanical check" ;;
  esac
}

build_prompt() {
  local id="$1"
  cat <<PROMPT
You are working inside this apexyard ops fork. Treat the situation below as true; it describes results that already happened in this session.

Situation:
$(cfield "$id" given)

The operator says:
$(cfield "$id" prompt)

Respond to the operator now, exactly as you would in the real session. You can read files in this directory, and you can create or edit files inside this directory if you judge that the task needs it. Do not run shell commands. If a step needs one, write the exact command and its expected effect instead of running it.
PROMPT
}

harness_available() {
  case "$1" in
    claude) command -v claude >/dev/null 2>&1 ;;
    cursor) command -v cursor-agent >/dev/null 2>&1 ;;
    codex) command -v codex >/dev/null 2>&1 ;;
    pi) command -v pi >/dev/null 2>&1 ;;
    opencode) command -v opencode >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Runs one harness on one prompt in cwd. Shell execution is denied where the
# CLI supports it; file edits stay inside the worktree.
run_harness() {
  local h="$1" prompt="$2"
  case "$h" in
    claude) claude -p "$prompt" --output-format text --allowedTools "Read,Glob,Grep,Edit,Write,MultiEdit" --disallowedTools "Bash,Agent,WebFetch,WebSearch" ;;
    cursor) cursor-agent -p --trust --output-format text "$prompt" ;;
    codex) codex exec --skip-git-repo-check -s workspace-write "$prompt" ;;
    pi) pi -p -a "$prompt" ;;
    opencode) opencode run "$prompt" ;;
  esac
}

if [ -n "$RUN_ONE_H" ]; then
  run_harness "$RUN_ONE_H" "$(cat "$RUN_ONE_PROMPT")"
  exit $?
fi

run_case() {
  local h="$1" id="$2" dir="$3" wt prompt rc started ended
  wt="$SRC_ROOT/.claude/worktrees/qr-$LABEL-$h-$id"
  git -C "$SRC_ROOT" worktree add --detach -q "$wt" "$REF" 2>/dev/null || { echo "worktree add failed for $id" > "$dir/$id.error"; return 1; }
  # The adopter's project-config is untracked, so a worktree would fall back to
  # single-fork defaults and report a missing registry. Copy it in with any
  # "../" sibling paths made absolute so split-portfolio resolution still works.
  if [ -f "$SRC_ROOT/.claude/project-config.json" ]; then
    sed "s#\"\.\./#\"$(dirname "$SRC_ROOT")/#g" "$SRC_ROOT/.claude/project-config.json" > "$wt/.claude/project-config.json"
  fi
  prompt=$(build_prompt "$id")
  printf '%s' "$prompt" > "$dir/$id.prompt"
  started=$(date -u +%H:%M:%S)
  ( cd "$wt" || exit 1; timeout "$TIMEOUT" bash "$SELF" --_run-one "$h" "$dir/$id.prompt" ) > "$dir/$id.out" 2> "$dir/$id.err" </dev/null
  rc=$?
  ended=$(date -u +%H:%M:%S)
  # Files written by the agent. Subtract the ops root's own dirty set: a
  # session-start hook (e.g. a premium installer) can drop the same untracked
  # files into every worktree, and those are environment noise, not the agent's work.
  git -C "$wt" status --porcelain 2>/dev/null | grep -vxF -f "$dir/.ops-dirty" > "$dir/$id.changed"
  git -C "$SRC_ROOT" worktree remove --force "$wt" >/dev/null 2>&1
  {
    echo "# $id — $(cfield "$id" title)"
    echo
    echo "- Harness: $h · Ref: $LABEL · Started $started · Ended $ended (UTC) · Exit: $rc"
    echo "- Dimension: $(cfield "$id" dim) · Severity on failure: $(severity_for "$id")"
    echo "- Fail if: $(cfield "$id" fail)"
    echo "- Pass if: $(cfield "$id" pass)"
    echo "- Mechanical check: $(mech_check "$id" "$dir/$id.out" "$dir/$id.changed")"
    echo
    echo "## Prompt"; echo; echo '```text'; echo "$prompt"; echo '```'
    echo; echo "## Files written in the worktree"; echo
    if [ -s "$dir/$id.changed" ]; then echo '```text'; cat "$dir/$id.changed"; echo '```'; else echo "None."; fi
    echo; echo "## Output"; echo; echo '```text'; cat "$dir/$id.out"; echo '```'
    if [ -s "$dir/$id.err" ]; then echo; echo "## Stderr"; echo; echo '```text'; tail -n 40 "$dir/$id.err"; echo '```'; fi
  } > "$dir/$id.md"
  rm -f "$dir/$id.out" "$dir/$id.err" "$dir/$id.changed" "$dir/$id.prompt"
  if grep -qiE "session limit|usage limit|rate limit" "$dir/$id.md"; then echo "  $id NOT RUN — harness reported a usage/session limit (exit $rc); re-run this case later" >&2; else echo "  $id done (exit $rc)"; fi
}

write_scorecard() {
  local h="$1" dir="$2" id mech
  {
    echo "# Scorecard — $h · ref $LABEL · $TODAY"
    echo
    echo "Mechanical checks are heuristics on observable text and written files. The adjudicated column is final and is filled by a person from the transcript in \`<id>.md\`. Severity applies when a case fails."
    echo
    echo "| Case | Dimension | Severity | Mechanical | Adjudicated | Notes |"
    echo "|------|-----------|----------|------------|-------------|-------|"
    # Every case with a transcript in the directory, so a partial re-run
    # (e.g. after a rate limit) merges into the scorecard instead of replacing it.
    for id in "${CASE_IDS[@]}"; do
      [ -f "$dir/$id.md" ] || continue
      mech=$(grep -m1 '^- Mechanical check: ' "$dir/$id.md" 2>/dev/null | sed 's/^- Mechanical check: //')
      echo "| [$id]($id.md) | $(cfield "$id" dim) | $(severity_for "$id") | ${mech:-not run} | | |"
    done
  } > "$dir/scorecard.md"
}

# ---------------------------------------------------------------------------
trap 'rm -rf "$CASE_DIR"' EXIT
parse_fixtures || exit 1

RUN_IDS=()
case "$CASES" in
  all) RUN_IDS=("${CASE_IDS[@]}") ;;
  representative) read -r -a RUN_IDS <<< "$REPRESENTATIVE" ;;
  *) IFS=',' read -r -a RUN_IDS <<< "$CASES" ;;
esac
for id in "${RUN_IDS[@]}"; do
  [ -s "$CASE_DIR/$id/prompt" ] || { echo "unknown case: $id" >&2; exit 2; }
done

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "cases parsed: ${#CASE_IDS[@]} (${CASE_IDS[*]})"
  echo "cases selected: ${#RUN_IDS[@]} (${RUN_IDS[*]})"
  for id in "${RUN_IDS[@]}"; do build_prompt "$id" >/dev/null || exit 1; done
  echo "prompts built: ${#RUN_IDS[@]}"
  exit 0
fi

HARNESSES=()
if [ "$HARNESS" = "all" ]; then HARNESSES=(claude cursor codex pi opencode); else IFS=',' read -r -a HARNESSES <<< "$HARNESS"; fi

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"   # absolute: per-case runs cd into a worktree and must still find $OUT
for h in "${HARNESSES[@]}"; do
  dir="$OUT/$h"; mkdir -p "$dir"
  { git -C "$SRC_ROOT" status --porcelain 2>/dev/null; echo "__none__"; } > "$dir/.ops-dirty"
  if ! harness_available "$h"; then
    echo "not run: $h CLI is not installed on this machine ($TODAY)" > "$dir/NOT-RUN.md"
    echo "$h: not installed — recorded as not-run"; continue
  fi
  echo "== $h · ${#RUN_IDS[@]} case(s) · ref $LABEL · out $dir"
  running=0
  for id in "${RUN_IDS[@]}"; do
    run_case "$h" "$id" "$dir" &
    running=$((running+1))
    if [ "$running" -ge "$JOBS" ]; then wait; running=0; fi
  done
  wait
  write_scorecard "$h" "$dir"
  rm -f "$dir/.ops-dirty"
done
echo "done: $OUT"
