# A vibe-coded request

## Type a plain request

Ask for a Corner Shop login page. Plain words describe the goal. They do not bypass the gates.
Try: build me a login page
Note: Demonstrate this request with no active ticket.

## Observe the blocked edit

The ticket gate blocks code edits when no ticket is active. Read the gate message before you continue.
Note: Show the actual hook message. The pane does not enforce this gate.

## File a ticket

Create a feature ticket for the login page. Define the behavior and the acceptance criteria.
Try: /feature Corner Shop login page
Check: skill feature
Done: You filed the login page ticket.

## Start it and name the branch

Start the real ticket. Use a branch such as feature/GH-<ticket-number>-login-page. Keep this change within that ticket.
Try: /start-ticket <ticket-number>
Check: skill start-ticket
Done: You started the ticket.

## Open a PR

A pull request, or PR, presents the change for review. Include the ticket number and test results.
Try: open a PR
Check: bash (?:^|&&|\|\||[;\n])\s*gh\s+pr\s+create\b(?![^;\n&|]*--help\b)
Done: You opened a pull request.

## Ask Rex to review

Rex is the code reviewer agent. Run /code-review for the PR. Resolve his findings before you request approval.
Try: /code-review <pr-number>
Check: skill code-review
Done: You asked Rex for a review.
Note: A matching skill call does not prove that Rex approved the PR.
