# Review and merge

## Request code review

Run /code-review for the Corner Shop PR. Rex checks the change against the ticket and tests.
Try: /code-review <pr-number>
Check: skill code-review
Done: You asked Rex for a review.

## Read the verdict

Resolve blocking findings. Confirm that checks pass and Rex approved the current PR revision.
Note: A checkpoint confirms a call. It does not confirm the review verdict.

## Explain this PR

Walk through what changed, why, the risky parts, and the decisions the agent made. Use /explain-pr before you approve when you want a grounded brief.
Try: /explain-pr <pr-number>
Check: skill explain-pr
Done: You asked for a read-only PR walkthrough.
Note: /explain-pr never writes an approval marker and never merges. It can end with an optional comprehension quiz.

## Approve this PR

Give explicit approval for this PR. Run /approve-merge with its real number. The merge gate checks the required evidence.
Try: /approve-merge <pr-number>
Check: skill approve-merge
Done: You requested merge approval for this pull request.
Note: Only the human can authorize this merge. Do not run this command during an unapproved demo. Optional: /approve-merge <pr-number> --quiz runs a comprehension check first.

## Verify the result

Check the merged change against every acceptance criterion. Confirm QA results before you mark the ticket done.
Note: QA means quality assurance. Use the real results from Corner Shop.
