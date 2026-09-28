#!/bin/bash
# test_resolve_project_repo_registry.sh — resolve-project-repo.sh must print
# exactly ONE line for a project that is NOT the last entry in the registry,
# and must strip double quotes as well as single quotes (apexyard#1446,
# Hakim N1, round 3). Reproduced the bug on a real 3-entry registry before
# fixing: awk's `exit` still runs END, so a middle entry printed its repo
# twice.
#
# No network. Synthetic registry, three entries, target is entry 2 of 3.

set -u

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$SKILL_DIR/lib/resolve-project-repo.sh"

fail=0
sb=$(mktemp -d "${TMPDIR:-/tmp}/orbit-resolve-repo-test.XXXXXX")

registry="$sb/apexyard.projects.yaml"
cat > "$registry" <<'YAML'
projects:
  - name: alpha-widget
    repo: acme/alpha-widget
    workspace: workspace/alpha-widget
  - name: beta-widget
    repo: "acme/beta-widget"
    workspace: workspace/beta-widget
  - name: omega-widget
    repo: acme/omega-widget
    workspace: workspace/omega-widget
YAML

# --- Case 1: target is the MIDDLE entry (not the last) --------------------
output=$("$HELPER" "$registry" "beta-widget")
rc=$?
line_count=$(printf '%s' "$output" | grep -c .)

if [ "$rc" -ne 0 ]; then
  echo "FAIL: expected exit 0 for beta-widget, got $rc (output: $output)"
  fail=1
fi
if [ "$line_count" -ne 1 ]; then
  echo "FAIL: expected exactly one line for a non-last entry, got $line_count lines: $output"
  fail=1
fi
if [ "$output" != "acme/beta-widget" ]; then
  echo "FAIL: expected acme/beta-widget (quotes stripped), got: $output"
  fail=1
fi

# --- Case 2: target is the FIRST entry (also not the last) ----------------
output2=$("$HELPER" "$registry" "alpha-widget")
rc2=$?
line_count2=$(printf '%s' "$output2" | grep -c .)

if [ "$rc2" -ne 0 ] || [ "$line_count2" -ne 1 ] || [ "$output2" != "acme/alpha-widget" ]; then
  echo "FAIL: expected exactly one line 'acme/alpha-widget' for the first entry, got rc=$rc2 output: $output2"
  fail=1
fi

# --- Case 3: target is the LAST entry (the only case the old code got right) ---
output3=$("$HELPER" "$registry" "omega-widget")
rc3=$?
line_count3=$(printf '%s' "$output3" | grep -c .)

if [ "$rc3" -ne 0 ] || [ "$line_count3" -ne 1 ] || [ "$output3" != "acme/omega-widget" ]; then
  echo "FAIL: expected exactly one line 'acme/omega-widget' for the last entry, got rc=$rc3 output: $output3"
  fail=1
fi

# --- Case 4: unknown project resolves to nothing, exit 1 ------------------
output4=$("$HELPER" "$registry" "does-not-exist" 2>/dev/null)
rc4=$?
if [ "$rc4" -eq 0 ] || [ -n "$output4" ]; then
  echo "FAIL: expected exit 1 and no output for an unregistered project, got rc=$rc4 output: $output4"
  fail=1
fi

# --- Case 5: a CRLF line ending and a trailing "# comment" are both
# stripped (round 4, Rex advisory) --------------------------------------
registry2="$sb/apexyard-crlf.projects.yaml"
printf 'projects:\n  - name: gamma-widget\n    repo: acme/gamma-widget  # primary mirror\r\n    workspace: workspace/gamma-widget\n' > "$registry2"

output5=$("$HELPER" "$registry2" "gamma-widget")
rc5=$?
line_count5=$(printf '%s' "$output5" | grep -c .)
if [ "$rc5" -ne 0 ] || [ "$line_count5" -ne 1 ] || [ "$output5" != "acme/gamma-widget" ]; then
  echo "FAIL: expected exactly one line 'acme/gamma-widget' with the CRLF and comment stripped, got rc=$rc5 output: $output5"
  fail=1
fi

# --- Case 6: a nested repo: key under an entry must not override that
# entry's own top-level repo: (round 4, Rex advisory) --------------------
registry3="$sb/apexyard-nested.projects.yaml"
cat > "$registry3" <<'YAML'
projects:
  - name: delta-widget
    repo: acme/delta-widget
    mirror:
      repo: acme/delta-widget-mirror
    workspace: workspace/delta-widget
YAML

output6=$("$HELPER" "$registry3" "delta-widget")
rc6=$?
line_count6=$(printf '%s' "$output6" | grep -c .)
if [ "$rc6" -ne 0 ] || [ "$line_count6" -ne 1 ] || [ "$output6" != "acme/delta-widget" ]; then
  echo "FAIL: expected exactly one line 'acme/delta-widget' (the entry's own top-level repo:, not the nested mirror.repo:), got rc=$rc6 output: $output6"
  fail=1
fi

rm -rf "$sb"

if [ "$fail" -eq 0 ]; then
  echo "PASS: resolve-project-repo.sh prints exactly one line for any registry position, quotes stripped"
fi
exit "$fail"
