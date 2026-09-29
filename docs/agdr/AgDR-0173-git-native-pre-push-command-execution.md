---
id: AgDR-0173
timestamp: 2026-09-27T00:00:00Z
agent: claude (Platform Engineer — Adel)
model: claude-opus-4-8[1m]
trigger: user-prompt
status: executed
category: security
---

# Run configured pre-push commands from the git-native hook, not from command text

> In the context of `pre-push-gate.sh` picking a target repository out of
> the Bash command's text and running that repository's configured
> checks, facing four review rounds on PR #1405 that each narrowed but
> never closed the resulting injection path (Hakim's H1, H3, and L2
> findings), I decided to move command execution to the git-native
> `pre-push` hook, run it only inside an ApexYard fork, and demote
> `pre-push-gate.sh` to an advisory reminder, to achieve a target
> resolution with no command text to parse, accepting that a managed-
> project clone gets no local pre-push check from ApexYard at all and
> relies on its own CI.

## Context

- Issue #1366: `pre-push-gate.sh` runs a repository's configured
  `.pre_push.commands` against the session's own working-directory repo,
  not the repository a `git push` command actually targets. In a sibling
  checkout, this ran the wrong repository's checks.
- PR #1405 tried to fix #1366 by parsing the push command's text to find
  the target repository. Reviewers closed it after four rounds. Hakim's
  final findings on that PR:
  - **H1 (HIGH).** The text split ignored quotes, heredocs, and
    comments. A heredoc body, a quoted string, a commit message, or an
    echo could mention a push without being one. Any of these could make
    the gate run a repository's declared commands before any permission
    prompt.
  - **H3 (MEDIUM).** Several real push shapes (`--git-dir`, a `GIT_DIR`
    assignment, `pushd`, two pushes in one command) still checked the
    working directory with no warning.
  - **L2 (LOW, accepted, not a regression).** Some real push forms
    (`env`, `eval`, `bash -c`, command substitution) skip the four
    Claude-layer push hooks entirely. CI and the git-native protected-
    branch hook remain the backstop for these.
- AgDR-0104 already recorded that a security gate built on regex or
  substring matching over Bash command text cannot be made sound. PR
  #1405 is a second, independent proof of that record for a different
  hook.
- `.githooks/pre-push` already exists as the git-native layer for
  protected-branch enforcement (AgDR-0114). Git invokes it with the
  pushed repository already resolved as its working directory. It reads
  git's own stdin ref lines, not command text.
- `bin/run-pre-push-checks.sh` already runs from that same git-native
  hook. It only runs this repository's own hardcoded framework checks: a
  markdown linter, a shell linter, and a subpack smoke test. It does not
  read a repository's own `.pre_push.commands`.
- AgDR-0115 already forbids ApexYard from setting `core.hooksPath` in a
  managed-project clone. `/handover` never calls `bin/install-git-hooks.sh`
  against a freshly cloned managed project, for the same reason (Rex
  finding S2, PR #1428 round 3). The script itself has no such refusal.
  The caller simply never invokes it there. Pointing git at a just-
  cloned repository's own scripts, with no provenance check, is a real
  hazard (the #1087 HIGH-1 finding). Any pre-push design for #1366 has
  to hold that line, not work around it.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A — Keep narrowing the text parser** (PR #1405's approach) | No architecture change | Four rounds already failed to close H1. AgDR-0104 predicts no round will |
| **B — Move execution to the git-native hook, ApexYard-fork clones only. Make `pre-push-gate.sh` advisory-only (chosen)** | No command text to parse. Git resolves the target repository by construction. Never installs a hook in a managed clone, matching AgDR-0115 | A managed-project clone gets no local pre-push check from ApexYard at all. An ApexYard-fork clone without `core.hooksPath` installed gets none either |
| **C — Move execution to the git-native hook. Keep `pre-push-gate.sh` running commands against its own cwd when `core.hooksPath` is unset** | Keeps some local blocking coverage for the common case | Reintroduces the exact #1366 mis-scoping in the sibling-checkout case, silently, whenever `core.hooksPath` is unset |
| **D — Restrict which repositories may supply commands (an allowlist)** | Narrows the blast radius | Does not fix H1 or H3. A crafted command can still pick an allowed repository. Rejected once already, in PR #1405's own AgDR-0171 draft |

## Decision

Chosen: **Option B**. `bin/run-configured-pre-push-checks.sh` is a new
script, invoked from `.githooks/pre-push`, that reads a repository's own
`.pre_push.commands` and runs them. Its working directory is always the
pushed repository, set by git itself, before this script or
`.githooks/pre-push` runs at all. There is no command text here to
parse, so H1, H3, and L2 do not apply to this path.

**Plain rule (maintainer decision, PR #1428 round 2): ApexYard runs
configured local pre-push commands only inside an ApexYard fork that has
the git-native hook installed. A managed-project clone gets no local
pre-push check from ApexYard, ever.** That clone's own CI is its
backstop. This matches AgDR-0115, which already forbids ApexYard from
setting `core.hooksPath` in a managed clone. This decision adds no path
that installs a hook into a managed clone.

Before this decision, the Claude-layer gate ran a repository's commands
itself, sometimes against the wrong repository (#1366). After it, only
an ApexYard fork's own git-native hook runs them, and only inside that
fork.

`pre-push-gate.sh` no longer reads or runs any repository's commands. It
checks the session's own working-directory repo. It names that repo in
every message, and states plainly that the check covers only that repo.

It prints install advice only for sessions with a valid pin to the
checked repo's main worktree. A linked worktree shares that main
worktree. The pin identifies the ApexYard fork. Files in the checked
repo alone cannot establish that identity (Hakim finding A5, Rex
finding S1, PR #1428 round 3).

The hook validates the pin with `_lib-ops-root.sh` and compares it with
the checked repo's Git common directory. It gives no advice if the pin
is absent, disabled, or invalid. A round-2 draft
of this hook instead trusted a `.apexyard-fork` marker, or a
`.githooks/pre-push` plus `bin/install-git-hooks.sh` pair, present in
the working-directory repo itself. Round 3's review showed a managed
repo can ship either shape and talk the hook into recommending
`core.hooksPath` for itself. The ops-root check closes that spoof gap
only for sessions with a valid pin. Without one, `resolve_ops_root`
falls back to a walk-up that can accept the checked repo's own marker.

With a valid pin to another repo, it prints a short note instead. That
note says ApexYard runs no local pre-push checks there. It never gives
the `core.hooksPath` install advice. AgDR-0115 forbids suggesting that
advice for this case (PR #1428 review, Rex finding B2). It never blocks.

Config resolution inside `bin/run-configured-pre-push-checks.sh` pins
`_CONFIG_ROOT_CACHE` to `$REPO_ROOT` before calling `config_get`. This
bypasses `_lib-read-config.sh`'s ops-fork walk-up. That walk-up would
otherwise resolve an enclosing ops fork's config for a project nested
under `workspace/<name>/` (PR #1405 review, finding B1). This is the
same bug class in a different lookup.

Option C was rejected. It would restore local blocking coverage for a
clone without `core.hooksPath`. It would do this only by restoring the
exact bug #1366 reports, silently, in exactly the case that bug
describes.

## Consequences

- **An ApexYard fork with `core.hooksPath` installed** runs
  `.pre_push.commands` against the repository being pushed, for a
  terminal push and a Claude Code-driven push alike. Config comes from
  that same repository.
- **An ApexYard fork without `core.hooksPath` installed** gets no local
  blocking check for `.pre_push.commands`. `pre-push-gate.sh` reminds a
  pinned session once per matching push, and names that fork by path.
  An unpinned session gets no install advice. CI is the only backstop
  until the fork installs the git-native hook.
  `bin/run-pre-push-checks.sh` already documents this same accepted
  trade-off for its own hardcoded checks on a fresh clone.
- **A managed-project clone** gets no local pre-push check from ApexYard
  at all, whether or not `core.hooksPath` happens to be set there. Its
  own CI is the only backstop, by design, not by omission. `pre-push-
  gate.sh` prints at most a one-line note naming that clone and stating
  that ApexYard runs no checks there — never install advice. AgDR-0115
  already forbids the alternative (ApexYard setting `core.hooksPath` in
  that clone).
- `block-main-push.sh`, the `--no-verify` backstop, and the #1230 ops-
  scope guard are unchanged. This decision touches only
  `.pre_push.commands` execution, not protected-branch enforcement.
- `.claude/hooks/detect-role-trigger.sh`'s trust-chain path list now also
  matches `bin/run-configured-pre-push-checks.sh`. An edit to it fires
  the Security Auditor role trigger, matching AgDR-0153's existing
  treatment of `bin/run-pre-push-checks.sh`.
- `bin/run-configured-pre-push-checks.sh` disables the session-scoped
  resolution cache before it loads the config reader (Hakim's A1, PR
  #1428 review). That cache is keyed by a weak fingerprint with no path
  in it, and a git hook can share its session id with the session that
  invoked the push.
- Docs updated for accuracy: `docs/getting-started.md` § "Terminal push
  hook", `docs/rule-audit.md`, `.claude/skills/setup/SKILL.md`, and the
  `.pre_push` comment in `.claude/project-config.defaults.json`.
- Test isolation (Rex finding R1, PR #1428 round 3): `bin/run-hook-tests.sh`
  exports `APEXYARD_DISABLE_RESOLUTION_CACHE=1` for its whole suite (test
  isolation, #528/AgDR-0120). A case that proves the resolution-cache
  fix compares a fixed script against a scratch copy with the fix
  removed. Both copies must run with that variable explicitly unset.
  Otherwise the suite-level export decides the outcome, not the
  script's own line. `test_run_configured_pre_push_checks.sh`'s case 8
  does this.

## Artifacts

- Issue #1491 (valid pin and linked worktree refinement)
- AgDR-0198 (decision to require a valid pin for install advice)
- me2resh/apexyard#1366 (the bug this record closes)
- me2resh/apexyard#1405 (the closed PR whose review found H1, H3, L2 and
  motivated this design)
- me2resh/apexyard#1428 (this PR — round 2 findings added the
  managed-clone scope rule and the resolution-cache fix, round 3
  findings replaced the self-reported fork check with `resolve_ops_root`
  and fixed the CI test-isolation gap)
- AgDR-0104 (command-text parsing cannot be made sound)
- AgDR-0114 (the git-native protected-branch layer this design reuses)
- AgDR-0115 (ApexYard never sets `core.hooksPath` in a managed clone —
  the rule this decision holds)
- `.claude/hooks/pre-push-gate.sh`, `bin/run-configured-pre-push-checks.sh`,
  `.githooks/pre-push`
