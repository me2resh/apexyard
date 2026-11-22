# Verify skeleton — Service

Use the controlled technical writing profile for evidence.
Use this file with `.claude/skills/verify/SKILL.md`. Fill in its setup fields first.

## Start the app

Start the service and its required local dependencies.
Wait for the documented health response within a bounded timeout.

## Drive the main flows

Send a request for the main success flow and record its result.
Send one invalid input and record its result.
Check expected state changes when the flow writes data.
For a worker or pipeline, submit a fixture and inspect its output instead of inventing an HTTP endpoint.

## Print evidence

Report the health check command, its exit code, and the response.
Report each request command, its status code, and a redacted response excerpt.
Report expected and observed state changes.
