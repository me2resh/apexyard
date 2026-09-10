# AgDR-0135: Parse Commit Options Without Evaluation

## Context

Issue [#1146](https://github.com/me2resh/apexyard/issues/1146) reports that the
commit-format hook validates the last message paragraph. Git uses the first
-m value as the subject.

A raw-pattern change can create a bypass. Text in another option can resemble
a message option. The hook input must not be evaluated.

## Options Considered

1. Keep the greedy raw-pattern extractor.
2. Search the raw command for the first -m pattern.
3. Tokenize the command without evaluation.

## Decision

Use a small Bash tokenizer. It preserves quoted values and identifies actual
Git option tokens. It does not execute command text.

The hook reads the first -m or --message option after git commit. It keeps the
existing file-message support. It blocks an incomplete option and an unsafe
command shape.

## Consequences

A normal subject plus body command now passes. A quoted value in --trailer
cannot impersonate a message option. A compound command that contains a
commit now fails closed. The tests cover these outcomes.

The tokenizer supports the command shapes that the hook already supports.
Complex shell syntax remains subject to the existing heredoc exception.

## References

- Ticket: me2resh/apexyard#1146
- Review: me2resh/apexyard#1194
