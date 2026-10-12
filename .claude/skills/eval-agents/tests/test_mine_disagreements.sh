#!/usr/bin/env bash
# test_mine_disagreements.sh - tests for lib/mine_disagreements.py (#1440).
#
# 1. Runs the Python unit tests (parsing, grouping, fixture mining).
# 2. Runs the miner against a fake `gh` on PATH. It checks that every forge
#    call is a read, that the output holds the expected candidate, and that
#    the corpus directory is unchanged.
# 3. Checks that validate-corpus.sh rejects a corpus built from raw drafts,
#    so a candidate cannot pass as an adjudicated entry.
#
# No network. Run: .claude/skills/eval-agents/tests/test_mine_disagreements.sh
set -uo pipefail

# Keep the working tree clean: no __pycache__ next to the lib or the tests.
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
MINER="$LIB_DIR/mine_disagreements.py"
VALIDATE="$LIB_DIR/validate-corpus.sh"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CORPUS_DIR="$ROOT/docs/eval-agents/corpus"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mine-disagreements-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# --- 1. Python unit tests -------------------------------------------------
if python3 -m unittest discover -s "$SCRIPT_DIR" -p 'test_mine_disagreements.py' >"$tmp/unit.out" 2>&1; then
  ok "python unit tests ($(grep -Eo 'Ran [0-9]+ tests' "$tmp/unit.out"))"
else
  bad "python unit tests"
  cat "$tmp/unit.out"
fi

# --- 2. Fake gh: read-only calls, expected candidate, corpus unchanged ----
corpus_manifest() {
  find "$CORPUS_DIR" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    cksum "$f"
  done
}
before="$(corpus_manifest)"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
  "pr list")
    printf '[{"number":7,"url":"https://github.com/example-org/example-repo/pull/7"}]\n'
    ;;
  "api --method")
    # Two pages, back to back, the way `gh api --paginate` prints them.
    sha=1234567890abcdef1234567890abcdef12345678
    printf '[{"id":71,"body":"## Code Review: PR #7\\n\\n### Verdict\\n**APPROVED**\\n","commit_id":"%s","submitted_at":"2026-09-01T10:00:00Z","html_url":"https://example.test/r71"}]\n' "$sha"
    printf '[{"id":72,"body":"## Security Review: PR #7\\n\\n### Verdict\\n**CHANGES REQUESTED**\\nHIGH: fail-open.\\n","commit_id":"%s","submitted_at":"2026-09-01T10:05:00Z","html_url":"https://example.test/r72"}]\n' "$sha"
    ;;
  *)
    echo "fake gh: unexpected call: $*" >&2
    exit 9
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

: >"$tmp/gh.log"
if FAKE_GH_LOG="$tmp/gh.log" PATH="$tmp/bin:$PATH" \
  python3 "$MINER" --repo example-org/example-repo --limit 5 >"$tmp/live.json" 2>"$tmp/live.err"; then
  ok "miner exits 0 against fake gh"
else
  bad "miner exits 0 against fake gh"
  cat "$tmp/live.err"
fi

if python3 - "$tmp/live.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
ids = [c["candidate_id"] for c in report["candidates"]]
assert ids == ["rex-7-12345678"], ids
assert report["scanned"]["prs"] == 1, report["scanned"]
assert report["scanned"]["reviews"] == 2, report["scanned"]
PY
then
  ok "fake gh output holds the expected candidate (paginated pages merged)"
else
  bad "fake gh output holds the expected candidate"
fi

if grep -Eqi -- '(^| )(-X|--method) ?(POST|PATCH|PUT|DELETE)|(^| )-f |(^| )-F |--field|--raw-field|--input' "$tmp/gh.log"; then
  bad "every gh call is a read"
  cat "$tmp/gh.log"
elif grep -Ev '^(pr list --repo example-org/example-repo --state merged |api --method GET --paginate repos/example-org/example-repo/pulls/7/reviews$)' "$tmp/gh.log" | grep -q .; then
  bad "every gh call is a read (unexpected call shape)"
  cat "$tmp/gh.log"
else
  ok "every gh call is a read ($(wc -l <"$tmp/gh.log" | tr -d ' ') calls)"
fi

after="$(corpus_manifest)"
if [ "$before" = "$after" ]; then
  ok "corpus directory unchanged"
else
  bad "corpus directory unchanged"
fi

# A failing gh is a clean exit 1, not a traceback.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "HTTP 401: Bad credentials" >&2
exit 1
GH
chmod +x "$tmp/bin/gh"
PATH="$tmp/bin:$PATH" python3 "$MINER" --repo example-org/example-repo >/dev/null 2>"$tmp/err.out"
rc=$?
if [ "$rc" -eq 1 ] && grep -q "list failed (exit 1)" "$tmp/err.out" && ! grep -q Traceback "$tmp/err.out"; then
  ok "gh failure exits 1 with a message"
else
  bad "gh failure exits 1 with a message (rc=$rc)"
  cat "$tmp/err.out"
fi

# --- 3. A raw draft never validates as a corpus entry ---------------------
if ! python3 "$MINER" --fixture "$SCRIPT_DIR/fixtures/mine-disagreements/merged-prs.json" >"$tmp/fixture.json"; then
  bad "miner generates raw drafts"
  exit 1
fi
if ! python3 - "$tmp/fixture.json" "$tmp/drafts.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
corpus = {"agent": "rex", "schema_version": 1,
          "entries": [c["draft_entry"] for c in report["candidates"]]}
assert corpus["entries"], "draft list must not be empty"
json.dump(corpus, open(sys.argv[2], "w"))
PY
then
  bad "raw draft helper succeeds with a non-empty list"
  exit 1
fi
if [ ! -s "$tmp/drafts.json" ]; then
  bad "raw draft file exists"
  exit 1
fi
if bash "$VALIDATE" rex "$tmp/drafts.json" >"$tmp/validate.out" 2>&1; then
  bad "validate-corpus.sh rejects raw drafts"
  cat "$tmp/validate.out"
elif grep -q -F "'ground_truth_defects' must be an array" "$tmp/validate.out" &&
  grep -q -F "recorded_verdict.was_justified must be a boolean" "$tmp/validate.out"; then
  ok "validate-corpus.sh rejects raw drafts"
else
  bad "validate-corpus.sh reports both raw draft rejection reasons"
  cat "$tmp/validate.out"
fi

echo
echo "mine_disagreements: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
