# Handbook: Reliability checklist

**Enforcement:** advisory.

Triggers select candidates, not violations. Rex verifies each candidate against the changed code.
Unrelated code and changes without the stated risk are not applicable.

## Format and discovery

Each item has a heading and three single-line fields: `Trigger:`, `Check:`, and `Source:`.
Use `path:` for a shell glob or `regex:` for a Python regular expression.
Path globs match repository-relative paths. `*` can match slashes.
Regular expressions match added and removed lines, without diff prefixes. Matching ignores case.
Context lines do not trigger checks.

Add adopter items to `architecture/reliability-*.md` in either handbook layer.
The loader reads public `handbooks/` and the directory from `portfolio_custom_handbooks_dir`.
Files add items without replacing framework items.
Keep each file's enforcement declaration under the conventions in [the handbook guide](../README.md).

Run `bash .claude/skills/code-review/reliability-triggers.sh < review.diff` from any directory.
The loader requires Python 3. It prints only matching items, including their handbook paths.
A trigger can select a broad candidate when the diff cannot prove the full risk.

## Local schema version

Trigger: regex: `\b(schema[_ -]?version|user_version)\b`
Check: For a local database schema version change, verify a migration record, committed schema files, and a migration test.
Source: [#2092](https://github.com/me2resh/apexyard/issues/2092), incident summary dated 2026-11-21.

## Cache compatibility

Trigger: regex: `\b(cache\w*|cached\w*)\b`
Check: For a new field read from a cache without expiry, verify a test using old entries.
Source: [#2092](https://github.com/me2resh/apexyard/issues/2092), incident summary dated 2026-11-21.

## Audit ignore entries

Trigger: regex: `(audit.{0,40}(ignore|exception)|(ignore|exception).{0,40}audit|GHSA-[\w-]+|CVE-\d{4}-\d+)`
Check: For an audit ignore entry, verify evidence that the advisory still exists.
Source: [#2092](https://github.com/me2resh/apexyard/issues/2092), incident summary dated 2026-11-21.

## Deployment isolation

Trigger: path: `.github/workflows/*`
Check: For a deployment workflow change, verify the isolation test and confirm that the live job contains no secret.
Source: [#2092](https://github.com/me2resh/apexyard/issues/2092), incident summary dated 2026-11-21.

## Content flag outputs

Trigger: regex: `\b(content[_ -]?flag\w*|\w*(?:draft|published|visible|visibility|enabled|disabled))\b`
Check: For a content flag, verify output checks for every flag state.
Source: [#2092](https://github.com/me2resh/apexyard/issues/2092), incident summary dated 2026-11-21.
