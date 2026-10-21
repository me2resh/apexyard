# Block git aliases that run push or commit

> In the context of the push and commit gates, facing git aliases that run `push` or `commit` under another name, I decided to find candidate verbs in the raw command, check each candidate against cheap alias evidence, resolve only the candidates that pass, and block every alias that resolves to `push`, `commit` or a shell command, to achieve alias coverage without the false blocks and timeouts of the first attempt, accepting six named residuals and a small set of accepted false blocks.

## Status

Accepted. Approved design v5. AgDR-0253.

### Architecture evolution

- 2026-10-19 design: Option A raw-text candidate scan with cheap evidence, then resolve. Closes #1748 row 4 without the round-1 false blocks and quadratic cost.
- 2026-10-19 build (CEO decision 14): Keep only the relative performance budget (dispatcher base + 0.5 s, each block-mode gate base + 0.2 s, no extra fork on the fast path). Remove the absolute 5 s total cap. Reason: the base dispatcher already exceeds its timeout on large inputs such as the 2,000-candidate payload (#1777; fix tracked in #1780). This change does not fix #1780.
- 2026-10-19 review fix (PR #1804): Read each config view with `git config -z` and a NUL-safe temp-file parser. Reason: a newline in an alias value forged a second line under space-split parsing, and a space in an alias subsection name broke the key split.
- 2026-10-19 review fix (PR #1804): Use the same candidate boundary class as `_git_sub_re` (`[^[:alnum:]_.-]`). Reason: a path-qualified git reached the push gates for the real verb but skipped the alias scan.
- 2026-10-19 review fix (PR #1804): Match a single-quoted `-C` or `--git-dir` value with a space in the no-jq payload pattern. Reason: #1748 row 5 stayed open for that quote style.
- 2026-10-19 review fix (PR #1804): Rewrite residuals R2, R3 and R6 at class level with no runnable examples. Correct R6: a backslash-escaped command word still reaches the push gates.
- 2026-10-19 follow-up (#1816, PR #1804): Close command-word and alias classes G1 to G8. Normalise a quoted or case-variant git command word before routing. Treat an expansion in the command-word or verb position as unknown and fail closed when the rest can be a push or a commit. Decode a quoted verb with the shared word reader. Block an alias when the target repository cannot be resolved statically, or when a config path write may replace the alias before git runs. Builtin verbs other than push and commit stay allowed. Move G1 to G8 from residuals into Decisions.
- 2026-10-20 review fix (PR #1804 round 3): Count a quote in a literal command-word and verb match only when it splits a word, or when the two words stay separate shell words. One quoted string that holds both words is one shell word, so it does not route to the gates. For G7, count a directory-stack word only at a command position. Count a nested shell only when it gets a command string, or when it reads its script from stdin at a command position. Reason: prose, search patterns, heredoc bodies and script-file runs blocked ordinary commands.

## Context

Ticket: me2resh/apexyard#1748, row 4 (aliases) only. PR #1756 (merged as `23d8387`) fixed rows 1, 2, 3 and 5. PR #1747 (merged) added the shared matcher. #1747 is a PR, not an issue.

### Why PR #1756 removed alias resolution

Rex round 1 on PR #1756 found four faults in the first resolver:

1. False blocks. The resolver read every `git <word>` in the raw command, including quoted text and heredoc bodies. Five payloads that run no git verb blocked.
2. Quadratic cost. A heredoc with 40 mentions took 17.62 s at the dispatcher. A 200-line body did not finish in 9 minutes.
3. Case-sensitive keys. Git treats `ALIAS.x`, `alias.X` and the verb `X` as `alias.x`.
4. No AgDR.

Rex round 1 also listed open channels: `--config-env=alias.x=V`, `GIT_CONFIG_COUNT` with `GIT_CONFIG_KEY_n`, and `-c include.path=<file>`.

### What the code does at 23d8387

Each citation is `_lib-git-global.sh` at `23d8387` unless stated.

- `git_visit_invocations` (:397) does not parse real invocations. It gets invocations from `git_invocation_prefixes` (:406). That function runs `grep -oE` on the raw command (:383).
- Each gate passes a literal verb list. An example is `push commit` at `block-main-push.sh:577`.
- `_git_scan_globals` (:147) walks options until a named verb. It cannot discover an alias verb.
- `_git_take_global` consumes each `-c` value and discards it (:108-111). The design needs a new capture.
- `_git_take_value` returns 1 on a backslash (:77). It keeps `$(...)` and `${...}` as literal text.
- AgDR-0242 states: "Quoted text that names `git push` still matches." This follows AgDR-0113.
- The dispatcher runs the push gates only when `command_has_git_subcommand` matches `push` (`dispatch-bash.sh:350-352`). The same applies to `commit` (`:353-355`).
- `command_has_git_subcommand "git -c alias.p=push p" push` returns 1 (Observed). So no push gate runs for an alias push.
- With no matching invocation, `git_visit_invocations` runs the callback with no context (:447-449). The gate then passes.
- `git_visit_invocations` runs each invocation in a subshell (:412-438). A cache set inside the subshell is lost.
- `_git_chain_cwd` re-segments the whole command for each invocation (:278, :282, :320). This is the structural cause of the round-1 quadratic cost.
- `git_prepare_invocation` fails when a `cd` target is not a repository (:374). An alias read does not need a repository.
- The dispatcher hook has `timeout: 20` and `onFailure: block` (`settings.json:54-55`).
- Eight gates call `git_visit_invocations` in block mode. Three call it in advisory mode (`pre-push-gate.sh`, `warn-bootstrap-scope.sh`, `warn-stale-review-markers.sh`).

### How git runs a verb

Git 2.56 looks up a verb in this order (Observed by Tariq and in this record's probes):

1. Builtin. The match is case-sensitive. `git STATUS` fails with "cannot handle STATUS as a builtin" on macOS.
2. External `git-<verb>` on the exec-path or on `PATH`. An external `git-zz` runs before `alias.zz`. With `env -u PATH` or `env -i`, git does not find the external and runs `alias.zz` instead.
3. Alias. The key `alias.<verb>` is case-insensitive. The key `alias.<Name>.command` keeps the subsection case. When both forms exist, the last entry wins. A dotted alias name compares case-insensitively unless its last part is `command` (Observed in this record's probe):
   - `alias.P.x=version` runs for the verbs `p.x` and `P.x`.
   - `alias.p.X=version` runs for `p.x`.
   - `alias.P.command=version` runs for `P` and not for `p`.
   - `alias.p.COMMAND=version` runs for `p`. So the word `command` matches in any case.
4. Nothing. Git fails with "not a git command", unless `help.autocorrect` has a running value. The running values are `true`, `immediate`, a positive number and a negative number.

Alias expansion has more rules (Observed):

- Git splits the value with quotes and backslashes. `'"ver""sion"'` and `ver\sion` run `version`.
- An expansion can start with global options. `-c a.b=c version` and `-p version` run `version`.
- An expansion can define the next alias. `-c alias.qq=version qq` runs `version`.
- Git rejects `-C` and `--no-pager` in an expansion with "changes environment variables".
- When an expansion names no builtin, external or alias, git fails with "expansion of alias failed". Autocorrect does not apply at that hop.
- Git reads the config when the command runs, not when the hook runs. `git config alias.zz version && git -c alias.p=zz p` runs `version` (Observed in this record's probe). The same applies to a global `alias.p=zz` with `git config alias.zz version && git p` (Observed).
- An unquoted expansion before the verb can add words. `X='alias.p=version p'; git -c $X status` runs `version`, and so does `git -c $(printf 'alias.p=version p') status` (Observed). With a global `alias.p=version`, `X='user.name=me p'; git -c $X status` runs `version` (Observed). The quoted form `git -c "$X" status` runs `status` (Observed).
- `git -c user.name=A\ B status` runs `status` (Observed). The backslash keeps `A B` as one shell word.
- Brace expansion, globs and redirections also change the words before the verb (Observed by Hakim under bash and zsh). Examples are a brace pair in a `-c` value or in the verb, and a redirection between the options and the verb.
- A quoted `-C` or `-c` value can hold a command substitution or a backtick with an inner git command (Observed by Hakim). The outer verb can be a fast-path builtin.

### Host facts

- The Bash tool runs `/opt/homebrew/bin/zsh` on the operator's host. The hooks run `/bin/bash` 3.2 (Observed by Hakim).
- `_git_take_value` is quadratic on bash 3.2 with a UTF-8 locale (Observed by Hakim). It took 1 s at 5,000 characters, 3 s at 10,000 and 11 s at 20,000. Under `LC_ALL=C` it took 2 s at 20,000.
- Git ran a 13-hop chain. Git detects loops but has no small depth cap.

Config channels that define a running alias (Observed by Tariq): `-c`, `--config-env`, `-c include.path`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT` with `GIT_CONFIG_KEY_n`, `GIT_CONFIG_SYSTEM`, `HOME`, `XDG_CONFIG_HOME` and `GIT_DIR`. `GIT_COMMON_DIR` is Inferred. Files on disk through `include.path` or `includeIf` resolve when the read runs against the target repository with `--includes`.

An inline `-c` value that the gate cannot read also defines a running alias (Observed by Tariq). Examples are `git -c ali\as.qf=version qf`, `git -c alias.qh="$(echo version)" qh` and `K=ali; git -c "${K}as.qy=version" qy`.

An `includeIf` condition can change inside the command. The hook reads config before the command runs. Probes for this record, git 2.56, scratch HOME:

| Condition | Change in the command | Result |
|-----------|-----------------------|--------|
| `hasconfig:remote.*.url:<url>` | `git remote add o <url>` | The alias runs after the change (Observed) |
| `gitdir:<new>/` | `git init <new>` | The alias runs after the change (Observed) |
| `onbranch:<name>` | `git checkout -b <name>` | `git config --get` shows the alias. The alias lookup does not use it on an unborn branch (Observed). Later git versions can differ. |

`git config --get-regexp` exits 1 when nothing matches. It exits 128 on a bad config file (Observed).

### Assumptions

- The hook process and the Bash tool see the same `HOME`, `XDG_CONFIG_HOME` and `GIT_CONFIG*`. The design does not verify this.
- The hook and the Bash tool normally see a different `PATH`. The Bash tool sources a shell snapshot that sets `PATH` (Observed by Hakim). So the rule-7 view check is the real control for externals, not the `PATH` lookup (R4).
- The agent can change the Bash tool environment through the `env` block of `.claude/settings.local.json`. The #1762 record (CEO decision D6) makes that file a protected target. Until #1762 lands, this channel stays open.
- Files that the Bash tool sources can change the environment without command text. These are a `CLAUDE_ENV_FILE` script, `~/.claude/shell-snapshots/snapshot-zsh-*.sh` and possibly `~/.claude/session-env/<session-id>/`. This is residual R5.

### Threat framing

The alias gap has a different weight for each gate class.

| Gate class | Git-native layer | Alias escapes the native layer when |
|------------|------------------|-------------------------------------|
| Protected-branch push | `.githooks/pre-push` and server branch protection | The alias carries `--no-verify`, the command overrides `core.hooksPath`, or the clone has no hooks installed |
| Protected-branch commit | `.githooks/pre-commit:110` | Same as above |
| Commit content: `check-secrets.sh`, `validate-commit-format.sh`, `verify-commit-refs.sh`, `require-agdr-for-arch-changes.sh`, `block-onboarding-in-git.sh` | None. `.githooks/pre-commit` checks only the protected branch and private refs (:82). | Always |

`git-conventions.md:71` and AgDR-0114 make the git-native hooks the control and `block-main-push.sh` the backstop. So the commit content gates gain the most from this decision.

Without an alias, the commit content gates are already open to shell-level indirection, such as a variable verb or git through `xargs` (residual R6). So this decision is defence in depth. It closes the alias route and does not claim to close every route.

### Terms

| Term | Meaning |
|------|---------|
| Candidate | One `git [global options] <word>` match in the command text, with any `<word>` |
| View | The alias entries, `includeIf` entries and `help.autocorrect` that git would see for one target, plus the invocation's inline `-c` entries |
| Dangerous alias | An alias whose chain reaches `push`, `commit`, a shell command (`!`), or a fail-closed condition |
| Remaining verb | A verb that is not a builtin and is not an allowed external |
| Channel token | Command text that changes the config git reads in a way the gate cannot read cheaply |
| Definition evidence | Command text that can write an alias into a config file in the same command |
| Read form | `$NAME` or `${NAME}` with no `=`, `:=`, `+=` or other operator inside the braces |
| Fast-path set | A fixed list of common builtin verbs that skip all git forks |
| Residual | A known form that this decision allows on purpose |

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Scan raw text for candidates. Check cheap alias evidence first. Resolve only the candidates that pass. Block an alias that resolves to `push`, `commit` or `!`. This is the second option in the #1748 Notes, with a resolver. | Closes row 4 of #1748. No change to the 11 gate parsers. Cost stays near base for routine commands. Quoted prose with no alias evidence never reaches target resolution. | More code in the trust chain. Three residuals stay open. Some quoted-text over-match stays, as AgDR-0113 accepts. |
| A2. Same resolver as A. Splice the expanded alias arguments into each gate, so the gate checks the real push or commit. | Allows a harmless alias push, such as `git p` to a feature branch. | Changes 11 gate parsers. Each splice is a new parse surface. An alias with `-m` or a refspec needs exact git splitting in every gate. |
| B. Block every verb that is not a builtin and has an alias definition. Do not resolve. | Simple. No chain logic. | Blocks harmless aliases such as `git st` and `git lg`. High false-block rate. |
| C. Keep the current behavior. Rely on the git-native hooks and server branch protection. | No new false blocks or timeouts. | Commit content gates have no native layer. `git -c alias.ci=commit ci` skips the secret scan. A push alias with `--no-verify` skips every local control. |
| D. Block only inline forms: `-c alias.*` and `--config-env` in the command text. | One regex. No git fork. | Misses every alias in a config file, include file or environment channel. |

## Decision

Chosen: **Option A**, because it closes the alias gap for every gate class and removes each round-1 fault. Option A2 adds a parse surface to 11 gates for a convenience the agent does not need. The agent can type the real verb.

### Where the check runs

1. Add `git_alias_check <verbs>` to `_lib-git-global.sh`.
2. The dispatcher calls it on every Bash command, before the routing section at `dispatch-bash.sh:346`, with the verbs `push commit`. A block exits 2. No gate routing is needed, because a blocked alias push never runs.
3. `git_visit_invocations` calls it in block mode, before the loop at :404, in the parent shell. It passes the gate's own verb list. This covers a direct gate call, as in the #1748 repro.
4. Advisory gates do not call it. They cannot block.
5. If the dispatcher cannot load the library, it blocks a command whose text has `git` and, later, `alias.` or `--config-env` in any case. A missing control must not fail open (AgDR-0162). This fallback does not see aliases in config files. A broken install loses that coverage until the library is restored.
6. Any internal failure in `git_alias_check` blocks when the text has a git candidate. Examples are a failed continuation join and a `grep` exit 2. A `grep` exit 1 means "no match" and is not a failure. A failed `--exec-path` fork is not a block: the check then treats no exec-path command as an allowed external.

### Rules

1. Join line continuations first. Use one text for candidate discovery and target resolution. This removes the index shift in Rex round-1 note 4.
2. Find candidates at every git start position. A single `grep -oE` pass is not enough, because it does not report a match inside an earlier match.
   - List each `git` that whitespace, `<` or `>` follows, with one `grep -abo` call. Keep a position when the text start or a boundary character comes before it. Two `git` words cannot overlap, so this list is complete.
   - A position where `<` or `>` directly follows `git` is a candidate with an opaque verb.
   - Include positions inside an earlier candidate. An example is an inner git command in a quoted `-C` or `-c` value that holds `$(...)` or a backtick.
   - From each position, match the anchored candidate pattern: the shared option grammar (`_git_sub_re`, :21) followed by any shell word. The work is linear in the number of git occurrences.
   - Use `grep -a`, so a byte that looks binary does not end the scan.
   - Run the scan and rule 3 under `LC_ALL=C`.
   - Mark a candidate longer than 2 KiB opaque. Do not run `_git_take_value` on it.
   - Block the command when it has more than 4,000 candidates. The block message says to write the prose to a file.
   - Deduplicate the candidates before the 4,000-candidate count. Keep each target context for repeated text.
   - The boundary set is start, whitespace, `(`, `)`, `<`, `>`, backtick, both quotes, `;`, `|`, `&` and `=`.
   - Match each anchored candidate with in-shell `[[ =~ ]]`. Do not fork grep for each candidate.
3. Parse each candidate's global options with a new scan mode. The mode stops at the first word that is not a global option. It captures each `-c` and `--config-env` value. It reports the option where a scan fails.
   - When `_git_take_value` fails inside a `-c` or `--config-env` value, take the value word again with the `_git_opt_val` grammar (:20). That grammar keeps an escaped space (backslash then space) inside one word, as the shell does.
   - When the second read succeeds, the next word is the verb. Rule 9 still applies to the value.
   - When the second read fails, mark the verb opaque.
4. Mark the verb as opaque in these cases. Strip plain quotes from the verb, as `_git_take_value` does.
   - The verb contains a `$`, a backtick or a backslash.
   - The global-option region or the verb has one of these characters outside quotes: `$`, backtick, `{`, `}`, `*`, `?`, `[`, `<` or `>`. Each one can expand into new words or move words, so the hook cannot know the verb. This covers brace expansion, globs and redirections in bash and zsh.
   - A quoted word keeps a fixed word count and stays non-opaque.
   - The candidate is longer than 2 KiB (rule 2).
   - The option scan fails outside a `-c` or `--config-env` value.
   - The second read in rule 3 fails.
   - An opaque verb gets no builtin or external skip. Rule 18 decides it. So `git -c $X status` goes to rule 18, not to the builtin skip.
5. Keep the exact verb case for the fast-path set and the builtin check. Look up aliases with the two slots in rule 15. A candidate verb can contain `.`.
6. Skip a builtin verb:
   - Skip a verb in the fast-path set. The set is `add`, `branch`, `checkout`, `cherry-pick`, `clone`, `commit`, `config`, `diff`, `fetch`, `init`, `log`, `ls-files`, `merge`, `mv`, `pull`, `push`, `rebase`, `remote`, `reset`, `rev-parse`, `rm`, `show`, `stash`, `status`, `tag` and `worktree`. All 26 are builtins in git 2.56 (Observed).
   - Remove `rebase` and `stash` from the set when the text has `--exec-path` or `GIT_EXEC_PATH`. Before about git 2.20 to 2.22 they were exec-path scripts, so a changed exec-path can hide them (Inferred from git release history, not probed).
   - Skip a verb in `git --list-cmds=builtins`. Build the builtin set one time per process, and only when a verb is not in the fast-path set.
   - If `--list-cmds` fails or prints nothing (git older than 2.18), skip only the fast-path set. This can add blocks but cannot remove one.
7. Allow an external `git-<verb>` (an executable on the exec-path or on an absolute `PATH` entry) only when all conditions are true:
   - Rules 8 and 9 do not match. Apply them to the external before the skip. They need no fork.
   - The view has no dangerous alias for the same name. Check the inline `-c alias.<verb>` entries first, with no fork. Read the view (rule 10) only when no inline entry matches. The inline check decides only the first hop. A chain that continues past the inline entry reads the view.
   - Count only absolute `PATH` entries. A relative entry such as `./node_modules/.bin` resolves against git's cwd after `-C` or `cd`, so the hook and git can disagree.
   - List the `git-*` names on the absolute `PATH` entries and on the exec-path one time per process. Check each verb against that set.
   - The external skip is on. The skip is off when the text has `PATH` as a whole word in any form except a read form, `GIT_EXEC_PATH`, `--exec-path`, `env -i`, `env -`, `env -u`, `env --unset`, `env --ignore-environment` or `exec -c`.
   - Otherwise the verb is a remaining verb.
8. Block a remaining verb when the text has a channel token:
   - `HOME`, `XDG_CONFIG_HOME`, `GIT_DIR` or `GIT_COMMON_DIR` as a whole word, with or without `=`, in any form except a read form.
   - `GIT_CONFIG` with any suffix.
   - `--config-env`.
   - A `-c` value that starts with `include.` or `includeIf.` in any case.
   - Match each token anywhere in the literal text. This covers literal assignments, `read`, `export`, `env`, `declare -x` and `unset`. A token that quotes, expansions or `printf` formats split is residual R3.
   - Compute the text-wide checks of rules 7, 8 and 17 one time per process, not one time per candidate.
9. Block a remaining verb when its own inline config is unreadable:
   - The option scan fails inside a `-c` or `--config-env` value.
   - A `-c` key or value contains `$` or a backtick.
10. Choose the target for each remaining verb, and for each external that needs a view:
    - With no `-C`, `--git-dir` or `--work-tree`, and no `cd`, `pushd` or `popd` in the text, use the payload cwd.
    - Otherwise resolve the target with the `_git_chain_cwd` rules. Walk the segments one time per process, not one time per invocation. Do not require a repository.
    - When the target does not resolve and the verb is not a builtin, block (G7).
11. Read each view with one call: `git -C <target> [--git-dir=<dir>] config --includes --get-regexp '^(alias\..*|help\.autocorrect|include\..*|includeif\..*)$'`. Do not use `--global` or `--file`, because they turn includes off. A non-repository target reads the global and system config.
    - Add the basename of each `include.path` and `includeif.*.path` value in the view to the definition-evidence list in rule 17. A command that writes that file can then define an alias.
12. Treat exit 0 and exit 1 as a valid view. Treat any other exit as a read failure. A read failure blocks only a verb that needs the view.
13. Cache each view in the parent shell. Key the cache on the resolved `-C` directory and `--git-dir`. Environment channels need no key. Rule 8 blocks a remaining verb and an external before any view read (rule 7). A builtin needs no view.
14. Read at most 8 distinct targets in one process. Block the command when it needs a ninth.
15. Merge the invocation's inline `-c` entries after the cached view. Lowercase the section name. Later entries win. Put each alias entry into one slot:
    - `alias.<name>` goes into the case-insensitive slot `lowercase(<name>)`.
    - `alias.<s>.<v>`, when `<v>` is not `command` in any case, goes into the case-insensitive slot `lowercase(<s>.<v>)`.
    - `alias.<s>.command`, with `command` in any case, goes into the exact-case slot `<s>`.
    - A verb `V` matches the case-insensitive slot `lowercase(V)` and the exact-case slot `V`.
    - Inside one slot, the last entry wins. `alias.zz` and `alias.zz.command` share one slot in effect, because git uses the last entry (Observed).
    - When both slots match a verb and either one holds a dangerous alias, block. This avoids a dependency on git's order between the two slots, which this record did not probe.
16. Resolve the chain in the view, up to depth 10. At each hop:
    - Block a value that starts with `!`. This applies in every caller, so the dispatcher blocks it on every Bash command.
    - Split the value with git's rules up to the verb. Block a `"`, `'`, `\`, `$` or backtick before or inside the verb. Text after the verb does not matter.
    - Accept only `-c <key>=<value>`, `-p` and `--paginate` before the verb. Block any other option.
    - Merge an expansion's `-c alias.*` and `-c help.autocorrect` entries into the view for the next hop. Block an expansion `-c include.*` or `-c includeIf.*`.
    - Treat an expansion `-c` key that runs code like a `!` value, and block it. The keys are `core.fsmonitor`, `core.hooksPath`, `core.pager`, `core.editor`, `sequence.editor`, `core.sshCommand`, `diff.external`, `gpg.program` and `credential.helper`, in any case.
    - Classify the next verb with rules 5 to 7. Block a builtin in the caller's verb list. Allow any other builtin or allowed external. Follow the chain for an alias.
    - For a hop verb with no builtin, external or alias, apply the definition-evidence, conditional-include and `gitdir:` checks of rule 17. Block when one matches. The command can write the alias before git reads it, as in `git config alias.zz push && git -c alias.p=zz p`.
    - Otherwise allow that hop verb. Git fails with "expansion of alias failed". The rule-17 autocorrect check does not apply, because autocorrect does not run at a hop.
    - Block a chain longer than 10 hops, or a loop. Git allows more hops. The cap is stricter on purpose.
17. For a remaining verb with no alias, block in these cases. Otherwise allow it, because git fails with "not a git command".
    - The view has a running `help.autocorrect` value. Treat `prompt` as running.
    - The text has definition evidence: `alias.`, `include.`, `includeIf.`, `[alias`, `[include`, `.gitconfig`, `.git/config`, `git/config`, `config.worktree` or an include basename from rule 11, in any case.
    - The view has an `includeif.onbranch:` or `includeif.hasconfig:` entry. The command can change the branch or the remotes before git reads the alias.
    - The view has an `includeif.gitdir:` or `includeif.gitdir/i:` entry, and the text has an `init`, `clone` or `worktree` candidate. The command can create a repository that the condition matches.
18. Block an opaque verb when the view has a dangerous alias, a running `help.autocorrect` value, or a condition in rule 17. Also block it when rule 8 or rule 9 matches. Otherwise allow it.

### Block messages

| Condition | Message |
|-----------|---------|
| Alias to push or commit | `BLOCKED: git <verb> is an alias for git <real>. Run git <real> directly so the gates can check it.` |
| Shell alias | `BLOCKED: git <verb> is a shell alias. Run the alias body directly so the gates can check it.` |
| Channel token | `BLOCKED: this command changes git config (<token>) and runs git <verb>. Run the real verb without the change. If this is prose, write it to a file and pass -F or --body-file.` |
| Unreadable inline config | `BLOCKED: git cannot be checked with this -c value. Quote the -c value. Use a literal key and value with no $, backtick or backslash.` |
| Opaque verb | `BLOCKED: an unquoted expansion, glob or redirection before the git verb can change the command. Quote the value.` |
| Too many candidates | `BLOCKED: too many git mentions to check for aliases. Write the prose to a file and pass -F or --body-file.` |
| Definition evidence | `BLOCKED: this command writes git config and runs git <verb>. Run them as two commands. If this is prose, write it to a file and pass -F or --body-file.` |
| Conditional include | `BLOCKED: an includeIf entry can change git config during this command. Run git <verb> in a separate command.` |
| Autocorrect | `BLOCKED: help.autocorrect is set and git <verb> is not a command. Type the full verb.` |
| Config read failure | `BLOCKED: cannot read git config for <target>. Fix the config and retry.` |
| Too many targets | `BLOCKED: too many git targets to check for aliases. Split the command.` |

### No-jq behavior (AgDR-0130)

Without jq, the dispatcher reads no command text. Add a narrow raw-payload pattern to the no-jq path at `dispatch-bash.sh:386`. The pattern is `git`, the payload option grammar, then a `-c` value that starts with `alias.` in any case, or `--config-env`. A match exits 2. The pattern must not match `echo alias.x`, as Rex round-1 note 3 asked. Aliases in config files and environment channels stay open without jq. Follow-up item 3 records this gap.

### Performance budget

The CEO accepted the relative budget on 2026-10-19. On the same day the CEO removed the absolute 5 s total cap (decision 14). The perf test runs in Linux CI. It also runs on macOS `/bin/bash` 3.2 with a UTF-8 locale, because the hooks run there. The budget applies to both. It times the median of 5 runs for each payload. It runs the base hooks from `23d8387` in the same job.

| Measure | Budget |
|---------|--------|
| Dispatcher, each payload in the perf set | Base + 0.5 s |
| Each block-mode gate, direct call | Base + 0.2 s |
| Command whose candidates are all in the fast-path set | No extra git fork |
| Any other command, per process | At most 2 setup forks (builtin set, exec-path), 1 payload-cwd view and 8 target views |

An external verb such as `git lfs` now needs a view read when no inline entry matches (rule 7). The view cache keeps this inside the fork limit above.

The base dispatcher already exceeds the hook timeout on large inputs such as the 2,000-candidate payload. That is me2resh/apexyard#1777. The fix is me2resh/apexyard#1780. This record does not change that path.

The perf set has these payloads:

1. A heredoc write with 40 distinct non-builtin `git <word>` mentions.
2. A 200-line heredoc with 3 mentions on each line.
3. A commit whose heredoc message has 40 mentions. This routes all 7 block-mode commit gates.
4. 8 distinct existing `-C` targets, each with a verb that needs a view.
5. 9 distinct existing `-C` targets. The expected result is a block from rule 14.
6. One `-c` option with a quoted value of 20,000 characters.
7. One verb word of 20,000 characters.
8. 2,000 distinct candidates.
9. 4,001 candidates. The expected result is a block from rule 2.

Probe cost on macOS, git 2.56, mean of 20 runs (Observed): one view read 9.0 ms, `--list-cmds=builtins` 7.4 ms, `--exec-path` 7.0 ms.

## Consequences

### Blocked

- `git -c alias.p=push p`, with each case variant of the key and the verb.
- `git -c alias.Zq.command=push Zq`. The verb `zq` does not match this subsection, as in git.
- `git -c alias.push=commit Push`. On Linux, git finds no builtin `Push` and no external `git-Push`, so it runs the alias (Inferred). On macOS, rule 7 finds `git-Push` on the case-insensitive file system and then the dangerous alias.
- An alias to `push` or `commit` in a config file or include file that the hook can read before the command runs, for the resolved target.
- A command that can change an `includeIf` condition before git reads the alias, in the cases in rule 17.
- An alias chain that reaches `push` or `commit` through expansion options, for example `-c core.hooksPath=/dev/null push`.
- An external name with a dangerous alias of the same name. This covers `env -u PATH`, `env -i` and `unset PATH`.
- Every shell alias that a literal `git <verb>` candidate names, on every Bash command. A shell-level route to git that has no literal candidate is residual R6.
- An alias expansion that sets a key that runs code, such as `core.pager` or `core.hooksPath` (rule 16).
- A brace expansion, glob or redirection before the verb, when rule 18 finds a match.
- An inner git command in a quoted `-C` or `-c` value, such as `git -C "$(git zp)" status`.
- An unreadable inline `-c` value: a backslash, `$(...)`, `${...}` or a backtick.
- An unquoted expansion before the verb, when rule 18 finds a match. Examples are `X='alias.p=push p'; git -c $X status` and `git -c $(printf 'alias.p=push p') status`.
- A hop to an alias that the same command writes, for example `git config alias.zz push && git -c alias.p=zz p`.
- The channel forms in rule 8, the autocorrect form, and the define-then-run form in rule 17.

### Allowed

- `git st`, `git lg` and every alias that resolves to a builtin other than `push` or `commit`.
- `git lfs`, `git flow` and every external `git-<verb>` with no dangerous alias of the same name.
- An unknown verb with no alias evidence. Git fails with "not a git command".
- All five round-1 false-block payloads. Payloads 1, 3, 4 and 5 fall under rule 10 with an unresolved target. Payload 2 reads a non-repository view. This is Inferred from the code paths. The build PR tests must prove it.

### Decisions for classes G1 to G8 (#1816)

These classes were open on `dev` before #1816. Exact payloads stay private. Public text names the class only.

| ID | Class | Decision |
|---|---|---|
| G1 | A quoted git command word | Strip quotes from the command word before routing. Match the normalised word to `git`. |
| G2 | A git command word from an expansion | Treat the command word as unknown. When the rest of the simple command can be a push or a commit, route to both gate groups and block. |
| G3 | A git verb from an expansion | Treat the verb as unknown. When the rest can be a push or a commit, route to both gate groups and block. |
| G4 | A git command word in another letter case | Compare the command word case-insensitively before routing. |
| G5 | A quoted or partly quoted real verb | Decode the verb with the shared word reader (same quote rules as the alias parser). |
| G6 | A single-quoted repository path that holds a space, when jq is not installed | Covered by the #1748 row-5 / B3 payload pattern for single-quoted `-C` and `--git-dir` values. |
| G7 | A repository alias reached through a path the resolver does not follow | When an alias (non-builtin verb) runs and the target cannot be resolved statically (`env -C`, a subshell `cd`, `cd -P`, or a target option built from an expansion, a directory-stack change at a command position, a redirected directory change, a nested shell that gets a command string, or a nested shell at a command position that reads its script from stdin), block. This also applies to soft directory-chain failures. Builtin verbs other than push and commit stay allowed. |
| G8 | A repository alias from a config file written other than via `git config` | When the command text names a `.git/config` path (including `.git//config` and `.git/./config`) and then runs a non-builtin verb, block. Do not trust a stale view. |

Builtin safe verbs (status, log, diff, show, fetch, branch --list) stay allowed under every class, including a quoted or uppercase command word.

### Additional execution classes (#1825)

A nested shell with a separate option argument before its command-string option
counts as an unresolved execution context. A quoted shell command word also
counts. An eval command at a command position uses the same rule. A non-builtin
git verb in these contexts blocks when its alias or repository target cannot be
resolved. Literal read-only builtin verbs stay allowed. Placeholder-built tests
check the dispatcher and direct push and commit gates for each class.

Two near classes stay open: the plus-sign form of a shell option that takes a separate value, and an eval word that a quote splits. The shell-level indirection residual (R6) covers them. Class-level results only; exact shapes stay private.

### Residuals

Residuals name a class and why it is accepted. They give no runnable command, payload, file-path trick or variable example.

- R1. **Class: agent-written external `git-<verb>`.** An executable named `git-<verb>` on `PATH` or the exec-path runs as a normal program. Accepted because this matches any agent-written script. The native `pre-push` still applies unless the script disables hooks (AgDR-0114). Follow-up item 2. Dashed push and commit programs are excluded from this residual (#1825). The shared protected-shape check counts a command word whose last path part is a dashed push or commit program. It allows a leading path or none, quotes or escapes inside the name, and any letter case. It also counts a last path part that starts with the dashed prefix and then holds a word character that follows a quote, a backslash, a glob character, a brace or an expansion, and a path from an exec-path expansion whose last part starts with such a character. A command position follows an assignment, a redirection or one of a fixed list of wrapper and keyword words. A wrapper outside that list, or a path-qualified, quoted or escaped wrapper word, does not count. When the text holds a nested shell, an eval word or a directory-stack word at a command position, every word of the whole text counts, not only the nested body. The command-position test ignores quotes, so some data text blocks (see Accepted false blocks). A dashed program with a plain name that only shares the prefix stays allowed. The no-jq dispatcher path blocks on the name alone because it cannot see the command position. A line continuation inside a name is not joined here. Issue #1837 covers line continuations. The dashed block has its own message. The open part of this class is recorded in R3.
- R2. **Superseded by CEO decision of 2026-10-20 (PR #1804 round 3, G7 from #1816): a non-builtin verb whose repository target cannot be resolved statically blocks; read-only builtin verbs stay allowed; the block message tells the user to use a literal directory or -C path.** A soft or hard unresolved repository target blocks a non-builtin verb. This includes directory paths that contain expansions. Read-only builtin verbs stay allowed. The resolver must not use the payload repository to clear an alias in an unknown repository.
- R3. **Class: split channel or definition evidence.** A channel token or definition evidence that quotes, expansions or format strings split so the literal text no longer contains the whole-word token. Config path writes that the literal text still names (including slash and dot normalisation) are G8 and now block. Accepted for the remaining split forms because a full shell parser is out of scope. CEO decision 7; narrowed by #1816. The same applies to a dashed program name that only variables build, with no literal dashed prefix in the command word (#1825). That form cannot be told from any other variable command word without a shell parser.
- R4. **Class: external-existence disagreement.** The hook and git can disagree on whether an external `git-<verb>` exists when the hook-process `PATH` differs from the Bash-tool `PATH`, or when a `PATH` entry is relative. Rule 7 applies rules 8 and 9 first, checks the view for a dangerous alias, and counts only absolute `PATH` entries. A disagreement then matters only when the view also misses the alias. Accepted 2026-10-19.
- R5. **Class: Bash-tool sourced environment.** Files that the Bash tool sources can change `HOME`, `PATH` or a `GIT_CONFIG*` variable with no command text. The class covers a `CLAUDE_ENV_FILE` script, owner-writable shell-snapshot files under `~/.claude/shell-snapshots/`, and owner-writable session-env directories under `~/.claude/session-env/`. The hook cannot see those changes. Accepted with follow-up item 5 (CEO decision 12).
- R6. **Class: shell-level indirection beyond G1 to G5.** Forms that hide the git argv through a shell alias, a shell function, or a tool that builds argv stay open. Quoted command words, case variants, expansions in the command-word or verb position, and quoted verbs are G1 to G5 and now block when the rest can be a push or a commit. **Not in this class:** a backslash-escaped command word. The dispatcher still routes that form to the push gates. R6 is older than this decision; #1816 narrows it.
- **Class: scripted or file-fed git.** A script file, `source`, or a verb or options read from a file or command output, is outside every command-text gate. An eval command that contains a git alias now counts as an unresolved execution context (#1825). Rule 4 marks that form opaque; rule 18 blocks only on view evidence. Older than this decision.
- **Class: ungated write verbs.** Verbs that create commits or send refs other than `push` and `commit` are not gated today. This decision gates exactly the verbs the gates cover.

Literal verbs use quote-aware escape removal before builtin and alias lookup. The repository-path reader still rejects escapes and unresolved expansions.

### Accepted false blocks

- Dashed-name false blocks (#1825). The command-position test ignores quotes and reads each line alone. Data text blocks when it holds the dashed name (a) after a separator, bracket, brace, bang or backtick inside quoted text; (b) at the start of a heredoc body line or of a line in a multi-line quoted string; (c) as the end of an argument path that continues after the close of an expansion; or (d) in a command that also holds a nested shell, because the whole text then counts. The reason is the AgDR-0113 rule that quoted text can over-match. The block message names the file-based workaround.

- Prose that names a non-builtin git word with an unresolved repository target. The strict G7 rule cannot verify that word against the target config.

- An expansion in the verb position can name a read-only verb at runtime. The gate blocks when arguments or explicit shell quoting make the protected verb uncertain. Use a literal read-only verb.

These follow the AgDR-0113 rule that quoted text can over-match. Each needs a rare combination with a remaining verb.

- Prose that names an operator's push, commit or shell alias, for example `echo "use git p"` with a global `alias.p=push`.
- Prose with an unknown `git <word>` and a channel token or definition evidence in the same command. The whole-word tokens make this more frequent. For example, `read -r HOME` or the word `HOME` in prose counts. `$HOME` and `${HOME}` do not count.
- An unknown `git <word>` with an inline `-c` value that contains `$`, a backtick or a backslash. Examples are `git -c user.name="$NAME" hooks` and `git -c user.name=A\ B hooks`. `git -c user.name=A\ B status` stays allowed, because rule 3 recovers the verb.
- An unquoted expansion before a real verb, such as `git -c user.name=$NAME commit`, when rule 8, 9 or 17 matches or the view has a dangerous alias. Rule 9 always matches this example, so it always blocks. The block message says to quote the value.
- A word that equals an include basename from rule 11, with an unknown `git <word>` in the same command.
- An unknown `git <word>` when the operator's config has an `onbranch:` or `hasconfig:` include.
- An unknown `git <word>` with a `gitdir:` include and an `init`, `clone` or `worktree` candidate in the same command.
- An installed external, such as `git lfs`, when the operator also defines a dangerous alias with the same name.
- Prose with an unknown `git <word>` when the operator sets a running `help.autocorrect`. Follow-up item 4 narrows this.
- A command with more than 8 distinct resolvable targets that need a view.
- Every `git -C $d status` with an unquoted `$`, when the operator has a `!` alias in the view. Rule 18 sees a dangerous alias and cannot know the verb. The message says to quote the value.
- An unquoted brace, glob character or redirection before the verb, such as `git -c x.y=a* status`, when rule 18 finds a match.
- A candidate longer than 2 KiB, when rule 18 finds a match.
- A command with more than 4,000 git candidates.

### Required work in the build PR

- Update `.claude/rules/git-conventions.md` § "No Direct Main" with the alias rule and the block messages.
- Hakim must review the change, because it is in `.claude/hooks/**`.
- Use hermetic fixtures. Set `HOME`, `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_NOSYSTEM=1` in each test.
- Test the dispatcher and a direct call to each block-mode gate.
- Show fail-before at `23d8387` for each blocked row.
- Assert that each fast-path verb is a builtin or an exec-path command on the CI git.
- Compare the inline `-c` canonical form with `git config --get-regexp` output for a fixture set.

The test matrix:

| Group | Cases |
|-------|-------|
| Round-1 regressions | The 5 false-block payloads from PR #1756 round 1 return 0 |
| Case | `ALIAS.x`, `alias.X`, verb `X`, `alias.Zq.command` with `Zq` and with `zq`. `git -c alias.push=commit Push` blocks on Linux CI and on macOS. |
| Expansion | `-c a.b=c push`, `-p push`, `'"pu""sh"'`, `pu\sh`, `pu$h`, `` pu`x`sh ``, `-c alias.qq=push qq`, `--no-pager push`, `-C /tmp push`. An expansion with `-c core.pager=<cmd>`, `-c core.hooksPath=<dir>` or another rule-16 code-running key blocks. |
| Inner candidates | `git -C "$(git zp)" status`, `git -c x.y="$(git zp)" status` and the backtick form find the inner `zp` and block when `zp` is a dangerous alias |
| Dotted names | `alias.P.x` matches `p.x` and `P.x`. `alias.p.X` matches `p.x`. `alias.P.command` matches `P` and not `p`. `alias.p.COMMAND` matches `p`. Each with a `push` value blocks. |
| Shell words | A brace pair in a `-c` value, a brace pair in the verb, a redirection between the options and the verb, `git` followed by `>` or `<`, and a glob with matching files each mark the verb opaque. Run this row, the "Expansion" row and the "Opaque verb" row under zsh and under bash. |
| Chain | Depth 10 allowed, depth 11 blocked, a loop blocked, a hop to an unknown verb allowed. `git config alias.zz push && git -c alias.p=zz p` blocks. A global `alias.p=zz` with `git config alias.zz push && git p` blocks. A hop to an unknown verb with an `onbranch:`, `hasconfig:` or `gitdir:` plus `init` condition blocks. |
| Lookup order | External `git-zz` with no alias allowed. External `git-zz` with `alias.zz=push` blocked, with and without `env -u PATH`, `env -i`, `unset PATH` and `exec -c`. `PATH=` in the text turns off the external skip. An external with `HOME=/tmp/h` in the text blocks. A `git-zz` only on a relative `PATH` entry does not count as an external. |
| Channels | Each token in rule 8, in prefix, `export`, `env`, `read -r` and bare-word forms. `$HOME` and `${HOME}` allowed. |
| Unreadable inline config | `git -c ali\as.qf=push qf`, `git -c alias.qg=pu\sh qg`, `git -c alias.qh="$(echo push)" qh`, `git -c "$(printf 'alia%s.qz=push' s)" qz`, `K=ali; git -c "${K}as.qy=push" qy` |
| Opaque verb | `X='alias.p=push p'; git -c $X status` blocks. `git -c $(printf 'alias.p=push p') status` blocks. `X='user.name=me p'; git -c $X status` with a global `alias.p=push` blocks. `git -c "$X" status` is allowed. `git -c user.name=A\ B status` is allowed. `git -c user.name=A\ B hooks` blocks. With a `!` alias in the view, `git -C $d status` blocks. |
| Internal failures | A failed continuation join blocks. A `grep` exit 2 blocks. A failed `--exec-path` fork treats no exec-path command as an external. A binary-looking byte does not end the scan. |
| Includes | `include.path` and `includeIf "gitdir:"` files on disk resolve under `-C`. `hasconfig:` with `git remote add`, `gitdir:` with `git init <new>`, and `onbranch:` with `git checkout -b` block. Run the `onbranch:` case in a repository that has a commit. An include basename written in the same command blocks. |
| Unknown verb | Autocorrect `true`, `1`, `-1`, `immediate`, `prompt` blocked. `0`, `false`, `never`, `show` allowed. `git config alias.p push && git p` blocked. |
| Failures | Alias-free host with `git lfs ls-files` returns 0. A bad config file blocks only a verb that needs the view. A missing `--list-cmds` turns off the builtin skip and blocks nothing by itself. |
| No jq | `git -c alias.p=push p` returns 2. `echo alias.x` returns 0. |
| Perf | The 9 perf payloads within budget, on Linux CI and on macOS `/bin/bash` 3.2 |

R3 forms are not test cases. A test for an accepted residual must not assert an allow as correct behavior.

## Rollback

- Revert the build PR. The change is one PR: the library function, the dispatcher call, the `git_visit_invocations` call, the no-jq pattern, the tests and the rule text.
- The change stores no state. A revert needs no migration.
- After a revert, every alias form returns 0, as at `23d8387`.
- Revert when CI shows a budget breach on `dev`, or when an operator reports a false block outside the accepted list.
- Until the revert lands, the operator can run the real verb. The block message says so.
- Do not add an environment kill switch. The agent can set environment variables through a command prefix or `.claude/settings.local.json`. A switch would be a bypass.

## CEO decisions (2026-10-19)

The CEO accepted each v2 recommendation. These are decided:

1. **Superseded by CEO decision of 2026-10-20 (PR #1804 round 3, G7 from #1816): a non-builtin verb whose repository target cannot be resolved statically blocks; read-only builtin verbs stay allowed; the block message tells the user to use a literal directory or -C path.**
2. **Block.** Every alias that resolves to `push` or `commit` blocks with "run the real verb". Splicing into the 11 gate parsers is rejected.
3. **Shell aliases block on every Bash command.** The block message says to run the body directly.
4. **A running `help.autocorrect` blocks an unknown verb.** Follow-up item 4 narrows this.
5. **Performance budget (relative).** Base + 0.5 s at the dispatcher, base + 0.2 s per gate, no extra fork on the fast path, in Linux CI.
6. **Fail closed past 8 targets and past 10 hops.**
7. **Accept residual R3.** Tokens that quotes, expansions or `printf` formats split stay open. The CEO directed that every other round-2 finding closes in this record. This is recorded in `ceo-decisions-2026-10-19.md` § "#1748 round 2".
8. **Fix B-V3-1 and B-V3-2 in v4.** Rule 16 now checks a hop to an unknown verb. Rule 4 now marks a verb opaque after an unquoted expansion.
9. **Acknowledge R4 and the wider R3.** B-V3-3 becomes residual R4. B-V3-4 widens R3 to definition evidence that the literal text does not contain, and widens R2 to templates.
10. **Close the Tariq rounds.** Run one Hakim security design pass on v4, then build.
11. **Fix Hakim B1-B5 in v5.** Run one Hakim delta check of the changed rules only, then build. Hakim reviews the code PR. Recorded in `ceo-decisions-2026-10-19.md` § "#1748 round 4".
12. **Accept R5 in its wider form.** Hakim judged R5 acceptable with the shell-snapshot and session-env files named and follow-up item 5 in the #1762 group. The CEO accepted it on that basis.
13. **File the redirect gap as its own bug.** The pre-existing gap for a redirection between `git` and the verb in the push and commit matchers gets a separate bug with neutral wording (follow-up item 6).
14. **Drop the absolute 5 s total cap.** Keep only the relative budgets in decision 5. The base dispatcher already exceeds its timeout on large inputs such as the 2,000-candidate payload (#1777; fix #1780). This build does not fix #1780.

## Follow-up items

These are not filed. Each becomes a ticket only after this record is filed.

1. **Block config writes that define a dangerous alias or include.** Block a `git config` write of an `alias.*` value that resolves to `push`, `commit` or `!`. Also block a write of `include.path` or an `includeIf.*.path`. Also treat `git init --template` and `git clone --template` as definition evidence. This narrows R2 to file edits.
2. **Review agent-written external git commands.** Decide whether a `git-<verb>` executable in a writable session path, such as the workspace or a temp directory, needs a gate. This covers R1.
3. **Close alias forms in no-jq mode.** Cover config-file aliases, environment channels and direct gate calls when jq is missing (AgDR-0130).
4. **Narrow the autocorrect block.** Block only when the command that git would autocorrect to is `push`, `commit` or a dangerous alias.
5. **Protect the Bash tool's sourced files (#1762 D6 group).** Make `~/.claude/session-env/**` and `~/.claude/shell-snapshots/**` protected write targets. Cover Write and Edit, and Bash text that names these paths or `CLAUDE_ENV_FILE`. This narrows R5.
6. **Redirect between git and the verb (separate bug).** The push and commit matchers have a pre-existing gap for a redirection between `git` and the verb. The CEO directed a separate bug with neutral wording. This record does not describe the gap further.

## Artifacts

- me2resh/apexyard#1748 (row 4 and Notes)
- me2resh/apexyard#1756 (Rex rounds 1 and 2)
- me2resh/apexyard#1747 (merged PR that added `_lib-git-global.sh`)
- me2resh/apexyard#1777 (base dispatcher timeout on large inputs)
- me2resh/apexyard#1780 (fix for #1777; out of scope here)
- AgDR-0113 (presence checks stay on raw text)
- AgDR-0114 (git-native hooks are the control, `block-main-push.sh` is the backstop)
- AgDR-0130 (fail-closed raw-payload patterns without jq)
- AgDR-0162 (a missing control must not fail open)
- AgDR-0242 (shared git global-option matcher)

