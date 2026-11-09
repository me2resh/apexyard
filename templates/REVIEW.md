# Review severity

Use severity to order findings. Keep all current gate rules.

## Blocking

A Blocking finding meets the existing Blocking-Severity Bar.
Example: A changed access check lets an unauthorised user read private data.

## Important

An Important finding needs attention but does not meet the blocking bar.
Example: A test omits a useful boundary case without evidence of a defect.

## Nit

A Nit suggests a small improvement. It does not block approval.
Example: A local variable name hides its purpose.

Count every finding. List at most five nits.
Report other nits as `Additional nits: N`.
Do not promote style faults to Blocking without evidence of harm.
