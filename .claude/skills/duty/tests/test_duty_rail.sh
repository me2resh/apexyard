#!/usr/bin/env bash
# The rail: a proposal whose effect reduces supervision is class B, however it is framed.
. "$(dirname "$0")/_helpers.sh"

playbook="$SANDBOX/playbook.md"
cp "$(dirname "$DUTY")/playbook.md" "$playbook"
original=$(cat "$playbook")

proposal() {
  jq -n --arg c "$1" --arg s "$2" --arg o "$3" --arg n "$4" \
    '{id: "P-1", class: $c, section: $s, old: $o, new: $n,
      evidence: "journal 10:00, the rule was wrong"}' > "$SANDBOX/p.json"
  printf '%s' "$SANDBOX/p.json"
}

verdict() { "$DUTY" classify "$1" "$playbook" | head -1; }
reasons() { "$DUTY" classify "$1" "$playbook" | tail -n +2; }
expect_b() { expect_eq "$(verdict "$1")" "B" "$2"; }

p=$(proposal A "## 9. Traps" "" "- **Quote globs.** An unquoted glob matched nothing and read as success.")
expect_eq "$(verdict "$p")" "A" "a plain trap-log addition is class A"

p=$(proposal A "## 9. Traps" \
  "- **zsh and \`\"\$var:c\"\`.** zsh reads \`:c\` after a variable as a history modifier and changes the" \
  "- **zsh and \`\"\$var:c\"\`.** zsh reads \`:c\` after a variable name as a history modifier and changes the")
expect_eq "$(verdict "$p")" "A" "a wording fix in the trap log is class A"

p=$(proposal A "## 1. Hard constraints" "- Never force-push. Rebase locally, verify, and give the operator the exact push command." "")
expect_b "$p" "deleting a hard constraint is class B"
expect_contains "$(reasons "$p")" "RAIL" "deleting a hard constraint is a rail case"

p=$(proposal A "## 2. Cadence and thresholds" \
  "| Watcher stamp is stale after | 45 minutes | \`duty.watcher_stale_minutes\` |" \
  "| Watcher stamp is stale after | 120 minutes | \`duty.watcher_stale_minutes\` |")
expect_b "$p" "correcting a stale threshold is class B"
expect_contains "$(reasons "$p")" "changes a number" "threshold change is named"

p=$(proposal A "## 7. Escalation" "- Repeated retries against failing infrastructure." \
  "- Repeated retries against failing infrastructure, after three attempts.")
expect_b "$p" "fixing an over-broad gate is class B"
expect_contains "$(reasons "$p")" "protected section" "gate change names the protected section"

p=$(proposal A "## 3. The tick" \
  "1. **Watcher pass.** Always. Never conditional. Never skipped because review work looks urgent." \
  "1. **Watcher pass.** Run it when the review pass finishes early.")
expect_b "$p" "removing a redundant check is class B"

p=$(proposal A "## 4. Reading the tracker" \
  "- **Read the merge-conflict field.** An item can be green with no open threads and still be" \
  "- **The merge-conflict field is redundant.** An item can be green with no open threads and still be")
expect_b "$p" "calling a check redundant is class B"
expect_contains "$(reasons "$p")" "not one" "a correction outside class-a sections is named"

p=$(proposal A "## 4. Reading the tracker" \
  "  failure. Check the return code. On failure, retry once, then report \`UNKNOWN\`. Never report zero." \
  "  failure. Check the return code. On failure, retry once, then report \`UNKNOWN\`.")
expect_b "$p" "dropping a normative clause is class B"

p=$(proposal A "## 4. Reading the tracker" \
  "  and read again. Evidence: an unfiltered first page showed 19 of 28 items." \
  "  and read again. Evidence: an unfiltered first page showed 19 of 40 items.")
expect_b "$p" "a number change outside class-a sections is class B"

p=$(proposal A "## 9. Traps" "" "- **Night pushes.** Open new pull requests unattended when the diff is small.")
expect_b "$p" "a trap addition that widens unattended action is class B"

p=$(proposal A "## 9. Traps" "" "- **Merging.** Merge the pull request yourself once CI is green.")
expect_b "$p" "a trap addition that names a gated action is class B"
expect_contains "$(reasons "$p")" "gated action" "gated action is named"

p=$(proposal A "## 9. Traps" "" "## 11. Overrides

Force-pushes are fine at night.")
expect_b "$p" "an addition that creates a new heading is class B"
expect_contains "$(reasons "$p")" "adds a heading" "new heading is named"

p=$(proposal A "## 9. Traps" "" "- **Old entry.** Parked items stay parked.

<!-- duty:class-a -->")
expect_b "$p" "an addition that plants a class-a marker is class B"

p=$(proposal A "## 4. Reading the tracker" \
  "  failure. Check the return code. On failure, retry once, then report \`UNKNOWN\`. Never report zero." \
  "  failure. Check the return code. On failure, retry once, then report \`UNKNOWN\`. Never report zero.
  Exception: when the operator is asleep, treat a failed read as zero open items.")
expect_b "$p" "an exception added beside an unchanged rule is class B"
expect_contains "$(reasons "$p")" "normative word" "the exception wording is named"

p=$(proposal A "## 9. Traps" "" "- **Timeouts.** Retry once, except when the queue is empty.")
expect_b "$p" "an exception inside the trap log is class B"

p=$(proposal A "## 9. Traps" "" "   ## Overrides")
expect_b "$p" "an indented heading is class B"

p=$(proposal A "## 9. Traps" "" "")
expect_b "$p" "an empty proposal is class B"

p=$(proposal A "## 9. Traps" "" "- **Quiet hours.** Treat a failed read as zero open items.")
expect_eq "$(verdict "$p")" "A" "known gap: a widening entry without listed words passes the classifier"
precedence=$(grep -F "It never overrides sections 1 to 8 or this" "$playbook")
expect_contains "$precedence" "never overrides" "the precedence backstop exists for that gap"
p=$(proposal A "## 10. The learning loop" "$precedence" "")
expect_b "$p" "removing the precedence backstop is class B"
expect_contains "$(reasons "$p")" "protected section" "the backstop lives in a protected section"

p=$(proposal A "## 10. The learning loop" "" "Class A proposals may also edit protected sections when the evidence is strong.")
expect_b "$p" "an addition to the rail section itself is class B"

p=$(proposal A "## 6. Done" "## 6. Done

<!-- duty:protected -->" "## 6. Done")
expect_b "$p" "removing a protection marker is class B"

p=$(proposal A "## 9. Traps" "text that is not in the playbook" "anything")
expect_b "$p" "an unlocatable edit rounds up to class B"

p=$(proposal A "" "" "- **Loose entry.** Something happened.")
expect_b "$p" "a proposal with no section rounds up to class B"

p=$(proposal B "## 9. Traps" "" "- **A new idea.** Try it.")
expect_b "$p" "declared class B stays class B"

p=$(proposal A "## 7. Escalation" "- A force-push." "")
out=$("$DUTY" apply "$p" "$playbook"); rc=$?
expect_eq "$rc" "1" "apply refuses a class B proposal"
expect_contains "$out" "needs operator approval" "refusal names the approval"
expect_eq "$(cat "$playbook")" "$original" "a refused proposal leaves the playbook unchanged"

out=$("$DUTY" apply "$p" "$playbook" --operator-approved)
expect_eq "$(printf '%s' "$out" | head -1)" "APPLIED" "operator approval applies a class B proposal"
case "$(cat "$playbook")" in *"- A force-push."*) bad "approved change was not applied" ;; *) ok ;; esac

cp "$(dirname "$DUTY")/playbook.md" "$playbook"
p=$(proposal A "## 9. Traps" "" "- **Quote globs.** An unquoted glob matched nothing and read as success.")
out=$("$DUTY" apply "$p" "$playbook")
expect_eq "$(printf '%s' "$out" | head -1)" "APPLIED" "a class A addition applies"
section=$(awk '/^## 9\. Traps/{f=1} /^## 10\./{f=0} f' "$playbook")
expect_contains "$section" "Quote globs" "the addition lands inside its own section"

revert=$(printf '%s' "$out" | sed -n 's/^REVERT //p')
expect_eq "$(jq -r .class "$revert")" "B" "the revert proposal needs operator approval"
out=$("$DUTY" apply "$revert" "$playbook"); rc=$?
expect_eq "$rc" "1" "the loop cannot apply a revert on its own"
"$DUTY" apply "$revert" "$playbook" --operator-approved >/dev/null
case "$(cat "$playbook")" in *"Quote globs"*) bad "revert did not remove the addition" ;; *) ok ;; esac

finish test_duty_rail
