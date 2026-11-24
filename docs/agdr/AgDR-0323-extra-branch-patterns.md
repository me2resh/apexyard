# AgDR-0323: Accept tracker-native branch names from config

## Context

Ticket #2083 asks the branch-name gate to accept names that a tracker creates. Jira's **Create branch** action produces `<KEY>-<number>-<summary-slug>` with no `type/` prefix. Jira links the branch and its PR to the ticket by that exact name. `validate-branch-name.sh` requires `{type}/{TICKET-ID}-{description}`, so the adopter loses the link or works around the gate.

Earlier exemptions in this hook name fixed shapes: handover branches (AgDR-0129) and dependency-bot prefixes (AgDR-0175). A tracker shape differs for each adopter, so the hook cannot name it ahead of time.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Fixed Jira shape in the hook | No config | Wrong for Linear, Shortcut and custom trackers. Needs a code change for each tracker |
| Config list of regexes, empty by default | Each adopter states its own shape. The default gate does not change | The adopter can write a broad pattern. Regex dialect differs by platform |
| Read the list from the sibling overlay as well | Lets the private portfolio set it | AgDR-0315 limits the overlay to tighten-only keys. This key loosens the gate |
| Disable the gate with a mode setting | Already exists for some gates | Turns off the type check for every branch, not only the tracker shape |

## Decision

Chosen: a `.branch.extra_patterns[]` list read with `config_get`, empty by default.

- **Whole-name match.** Each entry is an extended regex matched with `grep -qxE --`. `ABC-123` does not match `xABC-123y`. A match passes the gate. No match falls through to the unchanged `type/` rule.
- **Source.** The list comes only from the ops fork's `.claude/project-config.json` and the shipped defaults. The sibling overlay cannot set it, so the tighten-only rule of AgDR-0315 stays whole. This is the same trust source as `.branch.trunk_whitelist`, which already exempts exact names.
- **Dialect.** The hook uses the `grep -E` of the machine. The docs tell adopters to write portable POSIX ERE and no backreferences. A hook that bundled its own regex engine would add a dependency for a small gain.
- **Fail closed.** The hook checks every entry before it matches any. An invalid regex, a non-string entry, an entry with a newline, or a value that is not an array blocks the push and names the entry. The result does not depend on entry order.
- **Order.** The block runs after the trunk, release, sync, bot, handover and `orbit/` checks and before the `type/` rule. A pattern cannot unlock an `orbit/` branch that fails the records check.

## Consequences

- With the key unset, every adopter keeps today's behaviour. The block adds one config read for each push.
- A broad pattern such as `.*` turns off the branch-name check for every branch that reaches the block. That choice belongs to the adopter. The docs say so. Protected-branch rules still apply because `block-main-push.sh` runs first and apart from this hook.
- The gate reads only the ops fork's config, so a pattern for one managed project also accepts that shape in the others. The docs say so.
- One entry can behave differently on macOS and Linux if it uses a dialect extension. The docs name `\d` and backreferences. The failure is mostly toward blocking. On some platforms a dialect escape can match a literal character instead, so a pattern can accept a few names it should not.
- This key relaxes the branch-name check only. Ticket-first, secrets, commit format, PR title, review and merge gates still apply.

## Artifacts

- me2resh/apexyard#2083
- me2resh/apexyard#2125
- `.claude/hooks/validate-branch-name.sh`
- `.claude/hooks/tests/test_validate_branch_name_extra_patterns.sh`
