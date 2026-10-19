---
id: AgDR-0252
timestamp: 2026-10-19T00:00:00Z
agent: tech-lead (Hisham)
model: claude-opus-5-5
session: ceo-decisions-2026-10-19
trigger: user-prompt
status: accepted
category: security
---

# AgDR-0252: Initial commit and push of a new split-portfolio repository

> In the context of `/setup` Step 2b, facing a commit gate and a push gate that both block the initial commit and push to a new portfolio repository's protected branch, I decided that the agent stages the seed files and the operator runs the commit and push, to achieve a working setup with no new gate exception, accepting one manual step and one amendment to the "No Direct Main" rule.

## Decisions recorded

The CEO decided these items on 2026-10-19 (session record `ceo-decisions-2026-10-19.md`, § "#1739"):

1. **Decision accepted.** No gate exception. The agent stages named files. The operator runs the commit and push from a printed command. `/setup` verifies the result with the exact ref and the forge.
2. **#1739 Expected line and Severity reversed.** The fork's protected-branch list governs the portfolio repo. Severity changes from major to minor. The comment text in § "Change to the #1739 criterion" is posted before the closing PR.
3. **"No Direct Main" amended.** The closing PR amends `.claude/rules/git-conventions.md` § "No Direct Main" to name this one operator action. § "Amendment to No Direct Main" has the text.
4. **Staging-guard gap parked.** `block-git-add-all.sh:19` does not match `git -C <path> add -A`. The gap stays a discovery. A bug is filed only on approval. This record does not depend on the gap, because the agent stages files by name.

## Context

Ticket: me2resh/apexyard#1739, first-push remainder. PR #1750 fixed the target part and merged as `2529bec`. The push gate now checks the branch of the repo that the `cd` chain or `-C` names (`.claude/hooks/block-main-push.sh:455-470`). The commit gate uses the same target rule (`block-main-push.sh:521-535`).

Both gates block the Step 2b flow on the new repo's `main`:

- The push gate blocks with "Cannot push directly to a protected branch ('main')" (`block-main-push.sh:470-472`).
- The commit gate blocks with "Cannot commit directly on protected branch 'main'" (`block-main-push.sh:537-539`).
- `git add` is not gated by `block-main-push.sh`.

Evidence for the three results:

- Tariq observed them with hooks exported from `23d8387` and a sibling repo made with `git init -b main` (unborn HEAD).
- This record repeated the check on macOS, git 2.56.0. It used the exported `block-main-push.sh` and JSON payloads for `git -C "<sib>" add -- f`, `git -C "<sib>" commit -m ...` and `git -C "<sib>" push -u origin HEAD`. The results were rc 0, rc 2 and rc 2.

`/setup` Step 2b creates the private repo (item 3, `.claude/skills/setup/SKILL.md:166`). It clones the repo as a sibling (item 4, `:167`). It seeds the files and does "initial commit + push" (item 5, `:168-177`). Step 2b item 6 then writes the `portfolio:` block to `.claude/project-config.json` (`:178-196`). Step 2b item 7 runs `portfolio_validate` (`:211`). The top-level "Step 6: Write onboarding.yaml" (`:616`) is a different step.

PR #1750 first added a carve-out with AgDR-0245. Three review rounds followed.

Round 1 (two reviews at `80163f30`) found these carve-out faults:

1. The probe did not check the remote that the push uses. A `-c url.<real>.insteadOf=<empty-path>` value or a `remote.origin.pushurl` value can send the push to a remote with heads while the probe sees an empty remote.
2. The probe ignored `GIT_CONFIG_COUNT` env values, `pushInsteadOf`, `branch.<b>.pushRemote` and `remote.pushDefault`.
3. `remote get-url` prints only the first URL. A remote with two URLs pushes to both.
4. The carve-out used `exit 0` before the commit check. Thus every commit in the command skipped the protected-branch commit check.

Round 2 (at `8e79a43d`) reviewed a redesign. The redesign replaced the probe with a local rule: the named remote has no tracking refs. It also added an unborn-HEAD commit exemption. Finding A showed that the local rule let a non-force push reach a populated protected branch. A repo can hold the remote's commits under a second remote name, after deleted tracking refs, or after a fetch by URL. The review also noted that the exemption allowed a commit on an orphan `main` in a repo with history, and missed an `export GIT_DIR` in an earlier segment.

Round 3 (at `28bc67ad`) approved the removal of the carve-out, the unborn-HEAD commit exemption, their helpers, their rule text and AgDR-0245.

The 2026-10-18 status comment on #1739 lists two design options:

1. Allow the command only when HEAD is unborn and the command only adds, commits and pushes.
2. Probe every push URL with `git remote get-url --push --all` and require all of them to have no branches.

The issue states a workaround: an operator push with a `!` command. A `!` command runs outside the agent's Bash tool, so the PreToolUse gates do not apply to it. The `!` prefix exists only in Claude Code. Step 2d lists opencode, pi, Codex and Cursor as other harnesses (`SKILL.md:489-530`). Step 2d runs after Step 2b, so `/setup` does not know the harness at Step 2b.

The git-native hooks do not apply to the operator's commit and push either. `core.hooksPath` is a per-clone value. `/setup` Step 0.5 installs it only in the ops fork (`SKILL.md:83-89`). The portfolio clone has no `core.hooksPath` and no `.githooks/`. Thus `.githooks/pre-commit` and `.githooks/pre-push` do not run there. An exception is a global `core.hooksPath` in the operator's git config. § "Failure modes" covers that case.

Step 2b item 4 runs `cd .. && gh repo clone your-org/<name>` (`SKILL.md:167`). A relative path such as `../<name>` after that step depends on the shell's directory at that time. Rule 2 below uses an absolute path for this reason.

`/setup` already needs an operator. Step 2 asks one open-ended question and waits (`SKILL.md:118-127`). Step 2b item 3 says "Confirm before running" (`:166`). Every option menu uses `AskUserQuestion` (`:35`).

`git-conventions.md` § "No Direct Main" says "Every change must go through a PR. Zero exceptions." (`:71`). § "File Staging" forbids `git add -A`, `git add .` and `git add --all` (`:61`).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A.** Keep both gates. The agent stages the seed files by name. The operator runs the commit and push from a printed command. `/setup` then verifies the result. | No change to any gate. The operator sees and runs the only write to a protected branch. Matches the merge rule that a human acts on protected state. | One manual step. Needs an amendment to "No Direct Main". |
| **B.** Remote-probe carve-out (#1739 option 2). Allow a protected push when every URL from `remote get-url --push --all` has no heads. Refuse `-c`, `--config-env` and `GIT_*` values. Resolve the remote in push order. Keep the commit check. | Setup runs with no pause. | Each condition is a new trust-chain check. Round 1 found four faults in a simpler version. The push also needs a commit exception, which B does not give. A "registered portfolio repo" condition would be self-attested, as in Option D. |
| **B'.** Unborn-HEAD root-commit exception (#1739 option 1, round 2 fix option 1). Allow a commit and a push only when HEAD is unborn and the command only adds, commits and pushes. | The safety comes from git. A non-force push of a new root commit to a populated branch fails as non-fast-forward. Local checks only. | Needs two gate exceptions: a commit on an unborn protected HEAD, and a push. Must refuse every force form: `-f`, `--force`, `--force-with-lease`, a `+` refspec, `--mirror`, and a stored `remote.<n>.mirror` or `remote.<n>.push`. Must refuse `-c`, `--config-env` and `GIT_*` values, including an `export GIT_DIR` in an earlier segment. Must refuse an orphan `main` in a repo with history. |
| **C.** Push the initial commit to a non-protected branch. Then set that branch as the default, or create `main` through the forge API. | No gate change. | Moves the protected write to `gh api`, which the push gate does not see. That is a bypass pattern, not a fix. Leaves a stray branch. |
| **D.** Run Step 2b item 6 before the push. Then allow pushes from the registered portfolio path. | Uses the existing config block as the trust signal. | The agent writes `.claude/project-config.json` itself (item 6, `SKILL.md:181`). Thus the signal is self-attested. The block names a local path, not where the push lands. Round 1 faults 1-3 still apply. The new order breaks resume: Step 2a detection (`:155-158`) sees the block and skips Step 2b, push included. |
| **E.** `/setup` writes a one-shot session marker. The gates allow one protected commit and push while the marker exists. | Small change. | The main thread can write the marker. The near precedent is `.claude/session/active-bootstrap` (Step 0, `SKILL.md:74`). It is self-written, and only the process gate `require-active-ticket.sh` reads it (`require-active-ticket.sh:934`). A trust-chain backstop that reads such a marker lets any session grant itself protected pushes. |
| **F.** Create the repo with `gh repo create --add-readme`. Seed the files on a feature branch and merge them through a PR in the portfolio repo. | Fully compliant with the rules and gates. No rule amendment. | The merge needs Rex and a human merge approval in a repo that is not registered yet. That cost lands on first-run setup. It still needs a human action (the merge approval), so it does not remove the manual step. |

## Decision

Chosen: **Option A**, because each automated option needs a gate exception or a self-attested signal in the trust chain, and the operator is already present.

The reasons, in order:

1. Option B' is the strongest automated option. Git gives it real safety against a populated branch. But it needs two gate exceptions and a long list of refusals. Each refusal is a new parse of command text. Each of the three #1750 rounds found a bypass in a carve-out of this class.
2. The operation runs once for each adopter. A carve-out would run its checks on every protected commit and push in every session.
3. `/setup` is interactive by design (`SKILL.md:35`, `:118-127`, `:166`). One more operator step does not change the mode of the skill.
4. Options B, D and E depend on a signal that the agent can write or that does not name the push destination.
5. Option C moves the write out of the gate's view. Option F costs a full review and merge for a seed commit, and it still needs a human.

Thus Option A is better than Option B'. A later record can revisit B'. That record must answer each fault from all three #1750 rounds.

### Rules for `/setup` Step 2b

Rule 1 runs around item 4. Rules 2 to 9 replace the "initial commit + push" bullet in Step 2b item 5 (`SKILL.md:177`).

1. Before item 4, the agent runs `git rev-parse --show-toplevel` in the ops fork. It records the printed path as `<fork-root>`. After item 4, the agent runs `git -C "<fork-root>/../<name>" rev-parse --show-toplevel`. It records that path as `<abs-path>`. Later commands use both values as literal text, because shell state does not persist between Bash calls.
   - Neither value depends on the shell's directory after the `cd ..` of item 4 (`SKILL.md:167`).
   - On Git for Windows, `rev-parse` prints the `C:/dir` form (AgDR-0246 § Context). That form works in Git Bash, PowerShell and cmd.
2. The agent seeds the files of item 5 under `<abs-path>`, as today.
3. The agent stages the seed files by name, with one command:

   ```bash
   git -C "<abs-path>" add -- apexyard.projects.yaml projects/.gitkeep workspace/.gitkeep \
     onboarding.yaml custom-skills/README.md custom-handbooks/README.md agent-routing.yaml .gitignore
   ```

4. The agent shows the staged list from `git -C "<abs-path>" diff --cached --name-only`.
5. The agent does not run the commit or the push. The gates block both. The agent never adds `--no-verify`, `-c` or a force option to the printed command.
6. The agent prints the command in two forms. The first form is for Claude Code:

   ```text
   ! git -C "<abs-path>" commit -m "chore: initialise portfolio" && git -C "<abs-path>" push -u origin HEAD
   ```

   The second form is for a terminal. The agent prints it with this note: "In any other harness, run these two commands in a terminal. Run the second command only when the first one succeeds."

   ```text
   git -C "<abs-path>" commit -m "chore: initialise portfolio"
   git -C "<abs-path>" push -u origin HEAD
   ```

7. The agent asks one `AskUserQuestion` with three options, in this order:
   - "Done"
   - "Commit or push failed (paste the error)"
   - "Stop here"

   When the harness has no `AskUserQuestion`, the agent asks the same three options in prose (`SKILL.md:38`).
8. On "Done", the agent verifies the result with read-only commands:

   ```bash
   P="<abs-path>"
   BR=$(git -C "$P" symbolic-ref --short HEAD)
   LOCAL=$(git -C "$P" rev-parse --verify HEAD)
   REMOTE=$(git -C "$P" ls-remote origin "refs/heads/$BR" | awk -v r="refs/heads/$BR" '$2 == r { print $1 }')
   FORGE_ERR=$(mktemp)
   FORGE=$(gh api "repos/<owner>/<name>/branches/$BR" --jq .commit.sha 2>"$FORGE_ERR") || FORGE=""
   [ -n "$LOCAL" ] && [ "$LOCAL" = "$REMOTE" ] && [ "$LOCAL" = "$FORGE" ]
   ```

   - Record `<owner>` and `<name>` before this check. The reuse path skips item 3. Do not derive `<owner>/<name>` from the remote URL.
   - `BR` comes from `symbolic-ref`, not from a literal `main`. The clone's branch depends on the server and on `init.defaultBranch`.
   - The `awk` filter compares the ref name exactly. An `ls-remote` pattern matches the tail of a ref, even a full `refs/heads/<b>` pattern.
   - The command uses no `--heads` and no `--branches`. Git deprecates `--heads`, and older git does not have `--branches`.
   - `ls-remote` reads the fetch URL. The forge check covers a push that `pushurl` or `pushInsteadOf` sends to another URL.
   - When `FORGE` is empty, show the contents of `$FORGE_ERR` to the operator. Then remove the temp file (`rm -f "$FORGE_ERR"`). Map the error to branch-absent (HTTP 404, or "Branch not found"), authentication (HTTP 401 or 403, or "auth" in the error), or a network or other error. Keep `|| FORGE=""`. An empty `FORGE` never matches `LOCAL`.

   Note (2026-10-19, #1776): A missing branch sets `FORGE` to an empty string. The reuse path records `<owner>/<name>` before this check.

   Note (2026-10-19, #1782): When `FORGE` is empty, show the `gh api` stderr and map it to the three forge failure rows. The check still fails closed. The decision does not change.

   Note (2026-10-19, #1792): After the operator sees `$FORGE_ERR`, remove the temp file with `rm -f "$FORGE_ERR"`. The decision does not change.

9. When all three values match, the agent continues with Step 2b item 6. When a value differs, the agent applies § "Failure modes".

### Resume rule

A re-run today fails at item 3, because the repo exists. It also fails at item 4, because the directory exists. Step 2a skips Step 2b only after item 6 ran (`SKILL.md:155-158`). The agent applies these checks in order on each run of Step 2b. Each check uses read-only commands.

| State | Check | Action |
|-------|-------|--------|
| The chosen repo exists on the forge | `gh repo view <owner>/<name> --json isPrivate,isEmpty` | Stop when `isPrivate` is false. Otherwise ask one `AskUserQuestion`: "Reuse `<owner>/<name>`", "Pick another name", "Stop here". Skip item 3 only on "Reuse". |
| The repo is not empty, and no sibling clone exists | `isEmpty` is false, and `gh api repos/<owner>/<name>/contents/apexyard.projects.yaml` fails on the default branch | Stop. Report that the repo is not empty and is not a portfolio repo. When the file exists, continue with item 4. |
| The sibling directory exists | `git -C "<abs-path>" remote get-url origin` names `<owner>/<name>` | Skip item 4. Stop when the directory is not a repo or `origin` names another repo. |
| HEAD is unborn | `git -C "<abs-path>" rev-parse --verify -q HEAD` fails | Create only the seed files that are missing. Do not overwrite a file. Then apply rules 3 to 9. |
| HEAD has a commit | `git -C "<abs-path>" ls-tree -r --name-only HEAD -- <8 seed paths>` lists all 8 paths | Stop when a path is missing. Report the missing paths. Do not seed on the protected branch. Otherwise apply the next three rows. |
| HEAD has a commit, and the remote and forge SHAs equal HEAD | Rule 8 | Skip the commit and the push. Continue with item 6. |
| HEAD has a commit, and the branch is absent on the remote and the forge | Rule 8 | Print only the push command. Then apply rules 7 to 9. |
| HEAD has a commit, and the remote or forge SHA differs from HEAD | Rule 8 | Stop. Report both SHAs. Do not offer a force push. |

### Failure modes

| Failure | How `/setup` sees it | `/setup` action |
|---------|----------------------|-----------------|
| Staging stages nothing, because one seed path is missing | Rule 3 exits with `pathspec '<path>' did not match any files` (rc 128). Git stages no path in that case. | Re-create the missing seed file from item 5. Run rule 3 again. |
| The operator picks "Stop here" | The answer | Stop. Print the resume note: "Run /setup again to continue. Nothing reached the forge." The staged files stay. |
| The commit fails, for example with no git identity | The pasted error | Show the git message. Ask the operator to fix it. Print the command again. |
| A git-native hook blocks the commit, through a global `core.hooksPath` | The pasted hook message | Show the hook message. Ask the operator how to continue. The agent never suggests `--no-verify`. |
| The push fails on authentication | The pasted error | Suggest `gh auth status` and `gh auth setup-git`. Print the push command again. The agent does not run the push. |
| The push fails as non-fast-forward | The pasted error | Stop. Do not offer a force push. The remote has commits that `/setup` did not make. |
| The operator runs the command in another directory, or edits the path | Rule 8 fails | The command uses `git -C` with an absolute path, so the shell's directory does not matter. Report the value that differs. Print the command again. |
| The operator picks "Done" but did not run the command | Rule 8 fails: HEAD is unborn or the remote has no branch | Report the result. Print the command again. |
| The push went to another URL, for example through a global `pushurl` or `pushInsteadOf` | `REMOTE` can match while `FORGE` is empty | Stop. Show `git -C "<abs-path>" remote get-url --push --all origin`. Ask the operator to fix the config. |
| The session ends during the pause | The next run | `clear-bootstrap-marker.sh` clears the bootstrap marker at SessionStart. Step 0 writes it again. Step 2b then applies § "Resume rule". |
| No operator is present | The Step 2 question gets no answer | Not supported today (`SKILL.md:118-127`, `:166`). This record does not change that. |

After two failed checks in one run, the agent stops and prints the resume note.

### Amendment to No Direct Main

Chosen: amend the rule in the closing PR.

Replace the first two sentences of `.claude/rules/git-conventions.md:71` ("Every change must go through a PR. Zero exceptions.") with this text:

> Every change must go through a PR. One operator action is the only exception. The operator makes the initial commit and push of the new, empty portfolio repository that `/setup` Step 2b creates. An agent never makes that commit or that push, and the gates still block it.

Keep the rest of `:71` as it is.

The rejected alternative is to justify that the rule does not apply. That justification fails for three reasons:

1. The rule says "No commits directly to `main`/`master`", and the initial commit is one.
2. Option F shows that a PR path exists, so the rule can apply.
3. An unstated exception teaches readers that a hook block is the only rule. The amendment keeps the rule and the practice the same.

The amendment names an operator action, not a gate exception. `block-main-push.sh` does not change.

### Change to the #1739 criterion

The criterion covers the commit and the push. Sequence:

1. Done: the CEO accepted the decision, the reversal and the amendment on 2026-10-19 (§ "Decisions recorded").
2. This record is AgDR-0252. AgDR-0247 to AgDR-0251 are taken.
3. Before `gh pr create`, the agent that opens the closing PR posts this comment on #1739 as the framework author account (atlas-apex):

   > Changed criterion for the remaining part of this issue. The CEO confirmed this change.
   >
   > - The fork's protected-branch list applies to the portfolio repo.
   > - The agent does not commit or push to a protected branch of that repo.
   > - `/setup` Step 2b stages the seed files by name. The operator runs the initial commit and push.
   > - `/setup` prints the command and verifies the result against the remote and the forge.
   >
   > This replaces the Expected line "The fork's protected-branch list does not govern that repo."
   > Severity changes from major to minor. The remaining defect is skill text that tells the agent to run a blocked step.
   > Decision record: AgDR-0252. The closing PR changes `.claude/skills/setup/SKILL.md` Step 2b and `.claude/rules/git-conventions.md` § "No Direct Main".

4. The closing PR changes Step 2b, amends "No Direct Main", adds this record, and says `Closes #1739`.

## Architecture evolution

### Remove the FORGE_ERR temp file after show (#1792)

Rule 8 captured `gh api` stderr in a temp file and showed it when `FORGE` was empty. The skill did not remove that file after the show. The agent now runs `rm -f "$FORGE_ERR"` after the operator sees the text. The verify check and the three forge failure rows stay the same.

## Consequences

- No change to `block-main-push.sh` or to any other hook. No new trust surface.
- The agent never writes to a protected branch of the portfolio repo.
- Setup has one manual step. The printed command is one line in Claude Code and two lines in a terminal.
- The verify step checks the exact ref on the remote and on the forge. A push that goes to another URL fails the check.
- A re-run after an interrupted Step 2b continues from the last finished item.
- "No Direct Main" names one operator exception. Readers see the exception in the rule, not only in a skill.
- A later record can revisit Option B'. It must answer each fault from all three #1750 rounds.

## Rollback

- Revert the closing PR. That reverts the Step 2b text and the "No Direct Main" amendment.
- Set this record's status to `rolled-back`.
- No hook rollback is necessary, because no hook changes.
- An adopter who already pushed has nothing to undo.
- An adopter in the middle of setup gets the old Step 2b text and the old block. That is the state before this record.

## Out of scope

- `block-git-add-all.sh:19` matches `git add -A` but not `git -C <path> add -A`. This record checked the regex with `grep -E` on both forms. This record does not depend on the gap, because rule 3 names each file. The CEO parked the gap as a discovery (§ "Decisions recorded", item 4).

## Artifacts

- me2resh/apexyard#1739 (issue body, 2026-10-18 status comment, merge comment)
- me2resh/apexyard#1750 (review rounds 1 to 3, removal of AgDR-0245, merge `2529bec`)
- `.claude/skills/setup/SKILL.md` Step 2b at `23d8387`
- `.claude/rules/git-conventions.md` § "No Direct Main" at `23d8387`
- `.claude/hooks/block-main-push.sh` at `23d8387`
- Tariq review of the v1 draft, 2026-10-19 (CHANGES REQUESTED)
- Tariq delta review of the v2 draft, 2026-10-19 (APPROVED, advisories S1-S5)
- CEO decisions, 2026-10-19 (session record `ceo-decisions-2026-10-19.md`, § "#1739")
