# Declare override-only config keys, and prove the declaration by scanning the hooks

> In the context of `/update` offering to delete live configuration, facing an allowlist that a hook can outgrow silently, I decided to **keep the allowlist as data but derive its completeness check by scanning the hooks that read the override file** to achieve a test that fails when a hook starts reading a new key, accepting that the scan models one read idiom and must fail loudly if that idiom changes.

**Status**: Accepted
**Date**: 2026-09-28
**Ticket**: me2resh/apexyard#1363
**Related**: me2resh/apexyard#1365 (this PR) · [AgDR-0104](AgDR-0104-trust-chain-controls-vs-backstops.md) (why enumerating spellings does not converge)

## Context

`detect_deprecated_config_keys` treats a top-level override key absent from `project-config.defaults.json` as dead config, so `/update` offers to delete it. Several supported keys are absent by design: the hook reading each one holds its default in code and consults config only when an adopter overrides it. Accepting the offer silently disables a gate.

The first fix declared seven such keys in an `_override_only_keys` allowlist and added a test asserting the shipped allowlist covers them. That test restated the same seven keys in a fixture.

Review found an eighth. `tracker_repo` is read by `validate-pr-create.sh:306` and `verify-commit-refs.sh:334`, was absent from the allowlist, and the test passed anyway — because a fixed list can only show that a declared key stays declared. It cannot notice a key that a hook has newly begun to read. The defect and the test's blind spot are the same shape.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Add `tracker_repo`, keep the fixed-list test | Smallest diff; closes the reported instance | Leaves the mechanism that hid it. The ninth key repeats this exactly |
| Weaken the test's claim to "prevents removal from the allowlist" | Honest about what a fixed list proves | Accepts that nothing detects a new key; `/update` keeps offering to delete live config |
| Derive the key set by scanning the hooks | The test fails when a hook starts reading a new key, which is the actual failure mode | Models one read idiom (`jq '.key'` against `project-config.json`); a different idiom would go unseen |
| Declare every key in defaults and drop the allowlist | No allowlist to outgrow | Changes what the defaults file means: a declared default is a shipped value, and these keys deliberately have none |

## Decision

Chosen: **derive the key set by scanning the hooks**, and add `tracker_repo` to the allowlist.

The allowlist stays as data, because a hook's built-in default genuinely belongs in hook code rather than the defaults file. What changes is how completeness is proved: the test greps `.claude/hooks/*.sh` for reads of the override file and asserts every key it finds is either declared in defaults or present in the allowlist.

The scan's own blind spot is handled explicitly. If it matches no keys at all, the test **fails** rather than passing vacuously, because an empty result means the idiom it models has changed rather than that nothing is read.

This follows AgDR-0104's reasoning at a smaller scale: enumerating instances does not converge, so check the class. The difference from AgDR-0104's subject is that this scan reads the framework's own source at test time, not a user-supplied command string at gate time — so it can fail loudly and be corrected, rather than failing open in production.

## Consequences

- A hook that starts reading a new override-only key fails `test_detect_deprecated_config.sh` until the key is declared. Verified by mutation: removing any one of the eight allowlisted keys fails the case.
- The test reports the key set it checked, so a reviewer can see what it actually examined.
- The scan must match the file named inline **and** the file held in `$PCONFIG`, and it must not exclude a pipe between `jq` and the file name — the filter itself usually contains one, as in `jq -r '.design_paths // [] | join("|")'`. A first version of this scan excluded pipes, so it matched only the single key whose read has none. Seven keys went unpinned while the case still passed. That is recorded because the failure is silent: a scan that finds too little looks exactly like a scan that finds nothing wrong.
- A key read only for backward compatibility is named in a commented exception rather than allowlisted, because `/update` should still offer to remove it. `commit_types` is the only such key today.
- The scan still models a read idiom. A hook reading the override file some other way stays invisible to it, and the vacuous-match guard only catches the case where *every* match disappears. That residual is accepted.
- `tracker_repo` is no longer offered for deletion, so `validate-pr-create.sh` and `verify-commit-refs.sh` keep resolving the configured tracker repository.

## Artifacts

- me2resh/apexyard#1365
