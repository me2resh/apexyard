#!/usr/bin/env bash
# Regression test for me2resh/apexyard#1019.
#
# `config_get` must return plain \n-delimited text with no embedded carriage
# returns, even when the underlying jq emits CRLF line endings.
#
# The bug: on Windows (Git Bash / MSYS2) the native jq.exe writes stdout through
# a text-mode CRT handle, silently rewriting every \n it emits into \r\n.
#
# EVERY read is affected, and every line is affected. Command substitution
# strips trailing NEWLINES only, so a scalar read of `gh\r\n` yields `gh\r`, and
# a 3-element read yields three CRs with the last element ending `chore\r`
# (both od-verified). Cases 4 and 5 below exist because of exactly this: each
# FAILS against the unfixed lib, which is direct evidence that scalar reads and
# the final line are harmed. Do not reintroduce the tempting "scalars and the
# last line are safe" story — it is false, and acting on it by gating the strip
# to iterating filters would silently regress ~40 scalar production reads,
# `.tracker.kind` and the `$`-anchored `.tracker.id_pattern` among them.
#
# A MULTI-line filter is where the damage became VISIBLE, not where it was
# unique: callers join with `paste -sd'|' -`, building a regex alternation with
# carriage returns inside it that can never match a real branch name or PR
# title. Since validate-branch-name.sh and validate-pr-create.sh BLOCK on
# failure, Windows adopters could not create a compliant branch or PR at all.
# Ten hooks read multi-line config values, so the fix lives in config_get.
#
# macOS/Linux jq never emits CRLF, so the bug is latent here and a naive test
# would pass on the OLD code too — proving nothing. This test therefore forces
# the Windows behaviour with a stub `jq` earlier on PATH that appends \r to every
# line, exactly as jq.exe does. That reproduces the failure on the old code and
# passes only on the fixed code.

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf 'PASS [%s]\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL [%s]\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
  fi
}

mkdir -p "$TMP/.claude"
: > "$TMP/.apexyard-fork"

cat > "$TMP/.claude/project-config.defaults.json" <<'JSON'
{
  "branch": { "type_whitelist": ["feature", "fix", "chore"] },
  "tracker": { "kind": "gh" }
}
JSON

# --- Stub jq that mimics Windows jq.exe -------------------------------------
# Wraps the real jq and rewrites every emitted \n into \r\n. awk is used rather
# than `sed 's/$/\r/'` because POSIX does not specify `\r` as a sed escape on
# either side of the substitution — expanding it is an implementation extension,
# not a guarantee. awk's `printf "\r"` is specified, so the stub behaves the same
# everywhere. (Same reasoning as the `_CR` definition in _lib-read-config.sh.)
REAL_JQ="$(command -v jq 2>/dev/null)"
if [ -z "$REAL_JQ" ]; then
  echo "SKIP: jq not installed — cannot simulate the Windows CRLF path"
  exit 0
fi

mkdir -p "$TMP/bin"
cat > "$TMP/bin/jq" <<EOF
#!/usr/bin/env bash
"$REAL_JQ" "\$@" | awk '{ printf "%s\r\n", \$0 }'
EOF
chmod +x "$TMP/bin/jq"

PATH="$TMP/bin:$PATH"
export PATH

cd "$TMP" || exit 1
# APEXYARD_OPS_DISABLE_PIN: without this the session ops-root pin wins over the
# temp fixture and config_get reads the REAL repo config, so every assertion
# below would silently test the wrong file.
export APEXYARD_OPS_DISABLE_PIN=1
unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-read-config.sh"

# --- 1. multi-line output carries no CR ---------------------------------------
raw="$(config_get '.branch.type_whitelist[]')"
cr_count="$(printf '%s' "$raw" | tr -dc '\r' | wc -c | tr -d ' ')"
check "multi-line config_get output contains no carriage return" "0" "$cr_count"

# --- 2. the joined alternation is usable --------------------------------------
# This is the shape validate-branch-name.sh and validate-pr-create.sh build.
types="$(config_get '.branch.type_whitelist[]' | paste -sd'|' -)"
check "joined alternation is clean" "feature|fix|chore" "$types"

# --- 3. the alternation actually matches a real branch name -------------------
# The user-visible symptom: with \r present this regex matched nothing, so the
# validators rejected every branch.
branch="feature/GH-1019-example"
if printf '%s' "$branch" | grep -qE "^(${types})/"; then
  matched="yes"
else
  matched="no"
fi
check "a valid branch name matches the built alternation" "yes" "$matched"

# --- 4. single-value lookups still work (no over-stripping) -------------------
check "single-value lookup unaffected" "gh" "$(config_get '.tracker.kind')"

# --- 5. the LAST line of a multi-line read is not damaged ---------------------
# The strip runs on every line, including the final one. Check the last element
# arrives whole rather than clipped — a strip that ate one byte too many would
# still produce CR-free output and so would pass checks 1 and 2 unnoticed.
last="$(config_get '.branch.type_whitelist[]' | tail -n1)"
check "last element of a multi-line read is intact" "chore" "$last"

# --- 6. a value ending in a literal 'r' survives ------------------------------
# Asserts the behavioural contract: a value ending in 'r' comes back whole.
#
# Be precise about what this does and does not catch, because the obvious
# reading is wrong. On a CONFORMING sed this passes whether the code uses
# `$_CR` or a literal `\r`, so it does NOT catch a maintainer swapping one for
# the other — case 8 below exists for that. What it catches is a sed that reads
# `\r` as a literal 'r' (POSIX leaves that undefined), which we can only reach
# by sabotaging `_CR` to the string `r` — and note it then fails via the CR
# SURVIVING, not via truncation, since the stub leaves the value as
# 'active-reviewer\r' and `s/r$//` cannot match a trailing CR.
cat > "$TMP/.claude/project-config.json" <<'JSON'
{ "custom": { "value": "before\rafter", "ends_in_r": "active-reviewer" } }
JSON
# Assign empty rather than `unset` — the lib reads these under `set -u`, so
# unsetting them here makes it abort with "unbound variable" instead of reloading.
_CONFIG_CACHE=""
_CONFIG_ROOT_CACHE=""
check "value ending in a literal 'r' is not truncated" "active-reviewer" "$(config_get '.custom.ends_in_r')"

# --- 7. a value containing an INTERNAL carriage return is preserved -----------
# The strip is deliberately anchored to end-of-line so it cannot corrupt a
# legitimate mid-string CR. A blanket `tr -d '\r'` would fail this case.
# Assign empty rather than `unset` — the lib reads these under `set -u`, so
# unsetting them here makes it abort with "unbound variable" instead of reloading.
_CONFIG_CACHE=""
_CONFIG_ROOT_CACHE=""
inner="$(config_get '.custom.value' | tr -dc '\r' | wc -c | tr -d ' ')"
check "mid-string carriage return is preserved, not stripped" "1" "$inner"

# --- 8. the source does not rely on a `\r` escape inside sed ------------------
# The realistic regression is a maintainer "simplifying" `sed "s/${_CR}\$//"`
# into `sed 's/\r$//'`. Every runtime check above passes on a conforming sed,
# so no behavioural test on this machine can catch it — it would only surface
# on whichever platform we cannot run. Assert it at the SOURCE level instead,
# which works on every platform because it never executes sed at all.
lib="$HOOK_DIR/_lib-read-config.sh"

# 8a — the file must exist. Without this, 8c "passes" vacuously on a bad
# $HOOK_DIR: a negative grep finds no `\r` escape in a file it cannot open, and
# a test that misses its target while reporting success is worse than no test.
# 8b does NOT share that failure — a positive control cannot pass vacuously,
# which is the structural reason to have one. 8a is therefore about 8c.
[ -f "$lib" ] && lib_found="yes" || lib_found="no"
check "the lib under test was actually located" "yes" "$lib_found"

# 8b — POSITIVE control. The negative grep in 8c is narrow: a `\r` escape can
# hide from it behind a line continuation, a variable, or `-e`. Asserting the
# canonical form is PRESENT is spelling-agnostic, so any rewrite that drops
# `${_CR}` fails here even if it evades 8c. Unlike 8c it cannot pass vacuously.
#
# Matched against the whole PIPELINE, not just `sed "s/${_CR}`, because a
# file-scoped anchor is satisfied by any mention anywhere — including one of the
# comments in this very block, which would let a rewritten sed call slip past
# while the suite stayed green.
#
# `-F` (fixed string) is deliberate, not laziness: as a BRE, the `{` in
# `${_CR}` is undefined behaviour, and at least one grep implementation
# (ugrep 7.5) returns zero matches for the pattern form — which would make this
# control silently vacuous. That is precisely the class of bug this PR exists to
# fix, so the guard must not be built on it.
if grep -qF 'jq -r "$filter" 2>/dev/null | sed "s/${_CR}' "$lib" 2>/dev/null; then
  canonical="yes"
else
  canonical="no"
fi
check "config_get still strips via the \${_CR} byte" "yes" "$canonical"

# 8c — negative control. Catches the direct `s/\r$//` rewrite.
#
# It ALSO flags `sed $'s/\r$//'`, which is a false positive in principle: ANSI-C
# quoting expands to a real CR byte before sed ever sees it, so that form is
# actually portable and satisfies the same contract as $_CR. Accepted knowingly
# — nobody writes it here, and the failure direction is safe: it forces a human
# to look rather than waving a `\r` through. (An earlier revision of this
# comment claimed the opposite — that 8c does not flag it. It does.)
if grep -nE "sed[^|]*['\"]s/\\\\r" "$lib" >/dev/null 2>&1; then
  escaped="yes"
else
  escaped="no"
fi
check "config_get's sed uses a real CR byte, not a \\r escape" "no" "$escaped"

echo
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
