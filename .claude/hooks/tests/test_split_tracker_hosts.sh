#!/bin/bash
# Split issue/review tracker axes (#1225). No real tracker calls are made.
set -u

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SB=$(mktemp -d)
mkdir -p "$SB/.claude/hooks" "$SB/bin"
cleanup() { rm -rf "$SB"; }
trap cleanup EXIT
cp "$HOOK_DIR/_lib-tracker.sh" "$HOOK_DIR/_lib-read-config.sh" "$HOOK_DIR/_lib-portfolio-paths.sh" "$HOOK_DIR/check-private-refs-runtime.sh" "$SB/.claude/hooks/"
chmod +x "$SB/.claude/hooks/check-private-refs-runtime.sh"
touch "$SB/.apexyard-fork" "$SB/onboarding.yaml"
cat > "$SB/.claude/project-config.defaults.json" <<'JSON'
{"tracker":{"kind":"gh","issue_kind":"jira","review_kind":"glab"}}
JSON
printf 'version: 1\nprojects: []\n' > "$SB/apexyard.projects.yaml"
git -C "$SB" init -q
cat > "$SB/bin/glab" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${GLAB_CAPTURE:?}"
exit 0
EOF
chmod +x "$SB/bin/glab"
cd "$SB" || exit 1
. "$SB/.claude/hooks/_lib-tracker.sh"

fail=0
assert_eq() {
  if [ "$2" = "$3" ]; then printf 'PASS: %s\n' "$1"; else printf 'FAIL: %s (expected %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi
}

tracker_clear_cache
assert_eq 'legacy tracker_kind remains issue axis' jira "$(tracker_kind o/r)"
assert_eq 'issue axis resolves explicit issue_kind' jira "$(tracker_issue_kind o/r)"
assert_eq 'review axis resolves explicit review_kind' glab "$(tracker_review_kind o/r)"
printf 'review body\n' > "$SB/body"
GLAB_CAPTURE="$SB/review" PATH="$SB/bin:$PATH" tracker_review_submit o/r 42 comment "$SB/body"
assert_eq 'review submission dispatches to glab' mr "$(sed -n '1p' "$SB/review")"
assert_eq 'review submission uses note create' create "$(sed -n '3p' "$SB/review")"

cat > "$SB/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: split
    repo: o/r
    tracker:
      issue_kind: linear
      review_kind: gh
YAML
tracker_clear_cache
assert_eq 'per-project issue_kind overrides global axis' linear "$(tracker_issue_kind o/r)"
assert_eq 'per-project review_kind overrides global axis' gh "$(tracker_review_kind o/r)"

if [ "$fail" -ne 0 ]; then exit 1; fi
echo 'PASS: split tracker host cases'
