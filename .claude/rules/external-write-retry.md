# Check before retrying an external write

An external write changes a system outside the repository.
A failed command can still complete its external write.
Before retrying, check the destination for the result of the first attempt.
If the result exists, reuse it and report the partial failure.
Before cleanup, verify that another complete copy exists.
If you cannot verify the destination, report the uncertainty and stop the retry or cleanup.
