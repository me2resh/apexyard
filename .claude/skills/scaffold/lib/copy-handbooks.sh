#!/usr/bin/env bash
# Copy handbooks and shorten inherited prose. Keep all rules and examples.
set -euo pipefail
[ "$#" -eq 2 ] || exit 2
source_dir=$1 target=$2
for bucket in general architecture; do
  cp -R "$source_dir/$bucket" "$target/"
  while IFS= read -r -d '' file; do
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '*Part of '*) continue ;;
        'Commit messages explain **WHY**'*) line='Commit messages explain **WHY**, not WHAT. The diff shows the change. The message records the reason for future readers.' ;;
        'Commit messages that say '*) line='Vague commit messages waste that opportunity. The reader must search the PR, the ticket, or the author history for the reason.' ;;
        '2. The PR has a commit with no body AND'*) line='2. The PR has a commit with no body and a diff above 50 lines. Small changes can use a subject alone.' ;;
        'Attribution cuts both ways.'*) line='Include the required trailers in commits and PRs. Remove tool attribution from product artifacts. The tool is not a product feature. Rex reports this as advisory.' ;;
        'Dependencies point **inward**.'*) line='Dependencies point **inward**. Outer layers know inner layers. Inner layers do not know outer layers.' ;;
        'The dependency rule is what makes '*) line='The dependency rule keeps the domain testable without infrastructure mocks. It permits storage changes without business rule changes. It protects the domain from framework changes.' ;;
        '**Enforcement:** **blocking**'*) line='**Enforcement:** **blocking**. Rex requests changes for a violation. Resolve the fault or amend the handbook through a separate PR before merge.' ;;
        'Database schema migrations must be '*) line='Database schema migrations must support the previous release for at least one release. A migration must not break the previous code during rollout.' ;;
        'Production rollouts are not atomic.'*) line='Production rollouts are not atomic. Old and new code run against the same database during deployment. An incompatible migration can cause errors or data loss.' ;;
        '2. AND there is no associated migration AgDR'*) line='2. The PR has no linked migration AgDR. Report this fault as an additional check. The migration hook also requires the record.' ;;
        '> - This release: stop reading '*) line='> - This release: stop reading `role_v1` and use `role_v2`. Keep the column. Record the change in an AgDR.' ;;
        '- A `DROP` on a column that was added AND'*) line='- A `DROP` on a column that a prior release added and deprecated. Verify that production code no longer reads the column.' ;;
      esac
      line=${line//doesn\'t/does not}
      line=${line//don\'t/do not}
      line=${line//isn\'t/is not}
      line=${line//aren\'t/are not}
      line=${line//can\'t/cannot}
      line=${line//you\'re/you are}
      line=${line//they\'re/they are}
      printf '%s\n' "$line"
    done < "$file" > "$target/$bucket/${file#"$source_dir/$bucket/"}"
  done < <(find "$source_dir/$bucket" -type f -name '*.md' -print0)
done
