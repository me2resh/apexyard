---
id: AgDR-0256
timestamp: 2026-10-19T00:00:00Z
agent: platform-engineer (Adel)
model: claude-opus-5-5
session: build-1759
trigger: user-prompt
status: executed
category: security
---

<!-- Design: Hisham (tech-lead) v6, reviewed by Tariq (approved v3 for security review) and Hakim (v4, v5, v6 delta). CEO decisions of 2026-10-19 accepted every recommendation. Built by Adel for me2resh/apexyard#1759. -->

# AgDR-0256: Share PR metadata across the merge gates in one dispatch

> In the context of the four merge gates in `dispatch-bash.sh`, facing 9 to 13 serial `gh` calls that pass the 20-second dispatcher timeout on slow networks, I decided that the dispatcher fetches the PR metadata one time, gives the trusted values to the gates as environment variables, keeps only a digest-checked file list on disk, and reads the head SHA again after the gates pass, to achieve a merge route of 5 or 6 calls that finishes inside its timeout, accepting a new, bounded trust surface that Hakim must review.

## Glossary

| Term | Meaning in this record |
|------|------------------------|
| Prefetch | The dispatcher step that fetches the PR metadata one time, before the first merge gate runs (`prefetch_pr_metadata`) |
| Snapshot | The values that one prefetch fetched: head SHA, head branch, base ref, changed-file count and file list |
| Cache hit | A gate uses a snapshot value instead of its own forge call |
| Miss | A reader rejects the snapshot. The gate then makes its own forge call |
| Recheck | The dispatcher step that reads the head SHA again after all four gates pass (`recheck_pr_head`) |
| Key | The repo and PR number that a snapshot belongs to |

## Context

Ticket: me2resh/apexyard#1759. Related: #1623, #1760, #1761.

### Forge calls before this change

The merge route on the `gh` path made 9 to 13 serial forge calls. Each gate is a separate process, so a per-process memo did not help.

| Gate | Calls |
|------|-------|
| `block-unreviewed-merge.sh` | Head branch (squash or rebase only), head SHA, base ref |
| `require-design-review-for-ui.sh` | `changed_files`, the paginated file list, head SHA (UI PR only) |
| `block-merge-on-red-ci.sh` | `gh pr checks`, head SHA, workflows (no checks only), runs for the head SHA, and 2 commit-check calls when `gh pr checks` gives no result (AgDR-0244) |
| `require-architecture-review.sh` | `changed_files`, the paginated file list, head SHA (design PR only) |

This build measured the counts through the real dispatcher and the real gates, with a `gh` shim that logs each call (`test_prmeta_1759.sh`, run at upstream `dev` `4ef5fee`):

| Case | Calls before |
|------|--------------|
| Plain merge, no UI or design files, checks present | 9 |
| Same, no checks | 10 |
| Squash merge, UI and design files, checks present | 12 |

### Timeout before this change

- The dispatcher timeout was 20 seconds with `onFailure: block`.
- The profile chose 20 seconds from a macOS p95 of 2748 ms.
- The rule is "timeout >= 5 x p95, and never under 10 seconds".
- On the Linux host in #1759, one `gh` call takes 0.9 to 1.9 seconds. 10 calls gave 18.6 to 22.3 seconds.

### Trust constraint

- The review gate compares the marker SHA with the head SHA "as the forge reports it — state that a local file write cannot fabricate" (AgDR-0104, AgDR-0109).
- The agent's Bash calls run as the operator's uid. Mode 0700 does not protect a file against the same uid.
- A forged file list with no UI or design paths makes those two gates exit 0.
- So a trusted scalar must not be on disk.

### Fail-open class

- `dispatch-bash.sh` sets `set -euo pipefail`. Exit 2 blocks a tool call on every Claude Code version.
- With `onFailure: block`, exit 1 also blocks on Claude Code 2.1.295 or later. On an older client, exit 1 lets the call run (`docs/hooks-fail-closed.md`).
- Exit 0 always lets the call run. So exit 0 after a crash is the dangerous result.
- On `/bin/bash` 3.2 with `set -eu`, a read of an unset variable stops the shell even where `set -e` is off, for example in an `if` condition, an `&&` list, or a function called as `f || true`. Inside an EXIT trap, `$?` is then 0. A status-preserving trap then exits 0.
- Other crashes keep a non-zero status, usually 1: a `set -e` abort on a bare `grep -qE`, a bare `_h=$(false)`, and a `pipefail` abort. Exit 1 lets the call run on a client older than 2.1.295.

### The merge does not check the head

`_tracker_merge_gh` builds `gh pr merge <N> --repo <R>` with no `--match-head-commit`. So the forge merges whatever head the PR has at merge time.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A1. Per-dispatch cache file that holds all values | Removes the duplicate calls. Simple read path. | The same uid can rewrite the head SHA or the file list during the dispatch. A forged list makes the UI and design gates exit 0. |
| A2. Per-dispatch prefetch. Trusted scalars in the gate environment. Only the file list on disk, with its SHA-256 digest in the environment. A head recheck after the gates. | Removes the duplicate calls. No trusted scalar on disk. A rewritten file fails the digest check. Each gate keeps its own fetch as the fallback. | New code in the trust chain. Needs a digest tool. Adds one recheck call. Does not cover glab. |
| B. A2 with one GraphQL query | One round trip for 100 or fewer files. | Still needs the A2 trust channel. Saves at most one call. |
| C. Parallel calls | Wall time drops to the slowest gate. | Block order and fail-closed result get harder to reason about. Total calls stay at 9 to 13. |
| D. Raise the timeout only | No code change. | About 120 seconds on the #1759 host. A hung call holds the operator for 2 minutes. |
| E. Merge the calls inside each gate | No new trust surface. | 8 or 9 calls. Still close to 20 seconds on the #1759 host. |

## Decision

Chosen: **Option A2**, because it cuts the route to 5 or 6 calls, keeps every trusted scalar off disk, and keeps each gate's own fetch as the fallback.

### D1. When the prefetch runs

The prefetch runs inside `run_merge_gates`, before the first gate, only when every condition is true:

1. `is_merge_command "$COMMAND"` is true.
2. `has_conflicting_repo_flags "$COMMAND"` is false.
3. `merge_command_uses_variable "$COMMAND"` is false.
4. `extract_explicit_repo_from_command` returns a repo. Then `resolve_merge_repo` in each gate returns the same value with no forge call.
5. The repo passes `merge_repo_is_valid`. This one library function replaces the inline check in `block-merge-on-red-ci.sh`. The CI gate and the prefetch call it.
6. `extract_pr_number "$COMMAND" text-only` returns a number. The text-only mode skips the forge fallback. The gates keep the default mode.
7. `_forge_from_command` and `_forge_kind_for` both return `gh`.

When any condition is false, the dispatcher makes no snapshot and no recheck. The gates run as before.

### D2. Trust channel

#### Scalars

1. At start, before any hook runs, the dispatcher unsets every `APEXYARD_PRMETA_*` variable (a `compgen` scan plus the explicit list) and the control variables `_dispatch_complete`, `_prmeta_have_snapshot`, `_prmeta_dir` and `_rc`. Then it assigns `_dispatch_complete=0`, `_prmeta_have_snapshot=0`, `_prmeta_dir=` and `_rc=0`.
   - Bash imports every environment variable as a shell variable. Without this step, an inherited `_dispatch_complete=1` turns a crash into exit 0, and an inherited `_prmeta_dir` aims the cleanup at a directory that another process chose.
   - `unset` also removes an inherited export attribute, so a control variable never reaches a child process.
   - A test seam must use the `APEXYARD_PRMETA_` prefix, so the same unset removes it in production. This build adds no test seam.
2. The prefetch makes these calls:
   - `gh pr view <N> --repo <R> --json headRefOid,headRefName,baseRefName,changedFiles`
   - `gh api --paginate repos/<R>/pulls/<N>/files?per_page=100 --jq '.[].filename'`, only when `changedFiles` is 1 to 3000
   - For `HOST/OWNER/REPO`, `gh pr view` takes the full value, and `gh api` takes `repos/OWNER/REPO/...` and `--hostname HOST`. The key stays the full value.
3. The scalars are all or none. A `jq` filter checks every field type first. The dispatcher exports these values in one `export` statement, only after every value is valid:
   - `APEXYARD_PRMETA_OWNER_PID` (the dispatcher's `$$`)
   - `APEXYARD_PRMETA_REPO`, `APEXYARD_PRMETA_PR`
   - `APEXYARD_PRMETA_HEAD`, `APEXYARD_PRMETA_BRANCH`, `APEXYARD_PRMETA_BASE`, `APEXYARD_PRMETA_COUNT`
4. The file list is optional. The dispatcher exports `APEXYARD_PRMETA_DIR` and `APEXYARD_PRMETA_FILES_SHA256` only when the second call, the digest and the write all pass. When the file list fails, the scalars stay exported, and the gates fetch the list.
5. The snapshot holds forge data only. It never holds a marker, a verdict or an approval.
6. A missing, mismatched or invalid value causes a fresh fetch. It never causes an allow.

#### PID binding

7. A reader uses a scalar only when `APEXYARD_PRMETA_OWNER_PID` equals the gate's `$PPID`.
8. The binding is a guard against accidental inheritance. It is not authentication. It stops a stale or inherited value, an older settings file with one hook entry for each gate, and a direct test run of a gate.
9. `$PPID` cannot be set through the environment.
10. The binding holds for the current spawn shape. `run_fail_closed_hook` starts the gate as a plain command. All four gates use `#!/bin/bash`, so the kernel runs the gate in the same process. The binding also holds inside the gate's own `$(...)` and subshells.
11. The binding silently misses when the dispatcher starts a gate inside a command substitution, inside a function in a pipeline, as a non-last command in a subshell, or under a forking wrapper such as GNU `timeout`.
12. A miss is safe, because the gate fetches. But a miss returns the route to 9 to 13 calls. So `test_prmeta_1759.sh` case 1 runs through the real `dispatch-bash.sh`.
13. Residual: an attacker who controls the hook environment (a settings `env` block or the launch environment) can bind values to the stable Claude Code PID. This record accepts that residual. That attacker can already change the hook registration in the same settings file.
    - Today's control on that file is Claude Code's protected-path handling of `.claude/settings*.json`. It is vendor behaviour that this repo does not test. Public reports say that it covers Edit and Write tool writes, but not Bash writes such as `sed -i`.
    - The planned repo-side control is the #1762 draft. This record does not depend on it.
    - A stronger form exists: `/bin/bash` 3.2 loads functions from `BASH_FUNC_<name>%%` variables, and `BASH_ENV` and `PATH` give the same reach. This record does not fix it. It is parked as a #1762 discovery.

#### File list

14. The file list is the only data on disk. The dispatcher writes it to `<dir>/files`. It makes `<dir>` with `mktemp -d "${TMPDIR:-/tmp}/apexyard-prmeta.XXXXXX"` and sets mode 0700.
15. One byte form serves the writer and every reader. `L` is the list as `$(...)` returns it. The canonical bytes are `printf '%s\n' "$L"`. The digest is SHA-256 of the canonical bytes.
16. The writer works from memory only:
    - It captures the `gh` output with `if ! list=$(gh api ...)`.
    - When the list is empty, it writes no file and exports no file-list variables.
    - It checks that the line count of the canonical bytes equals `COUNT`. On a mismatch, it writes no file.
    - It computes the digest in memory, then writes the same bytes with `( set -C; printf '%s\n' "$list" >"$dir/files" )`. The subshell keeps `noclobber` inside it.
    - On a failed `chmod` or write, it removes the directory at once.
    - It never reads the file back.
    - `noclobber` refuses only an existing regular file. A pre-created symlink to `/dev/null` takes the write silently. Readers reject a symlink (rule 17). A pre-created FIFO makes the writer wait (rule 27).
17. A reader accepts `<dir>/files` only when it is a regular file and not a symlink (`[ -f ] && [ ! -L ]`). A FIFO or a device fails this check.
18. A reader reads at most 4194305 bytes with `head -c`. A result longer than 4194304 bytes is a miss. The reader sets `LC_ALL=C`, so `${#var}` counts bytes.
19. A reader captures the bytes one time into memory. It hashes `printf '%s\n' "$L"` of that value, compares the result with `APEXYARD_PRMETA_FILES_SHA256`, and checks that the line count equals `COUNT`. An empty value is a miss. The gate uses only the value that the reader hashed. Command substitution removes final newlines and NUL bytes, so added bytes of that kind cannot change the result.
20. A reader also rejects `<dir>` when it is a symlink, when the current uid does not own it, or when its mode is not 0700 (`ls -ld` gives `drwx------`, with an optional `.` or `@` suffix). These checks are defense in depth. The digest is the real guard.
21. The digest tool is `shasum -a 256`, then `sha256sum`, then `openssl dgst -sha256`, through `command -p`. One library function, `prmeta_sha256`, normalises the output to 64 lowercase hex characters for the writer and the readers. When no tool is present, the dispatcher writes no file list. `cksum` is not allowed.
22. The file list never goes into the environment. 3000 paths can exceed the Linux limit of 131072 bytes for one environment string.
23. `COUNT=0` is a file-list miss. The dispatcher writes no file. The gate fetches and blocks on the empty list, as before.

#### The miss path

24. Before this change, the miss path in the design and architecture gates wrote the `gh` output to `$TMPDIR/apexyard-pr-files.XXXXXX` and read it back. A same-uid rewrite between the write and the read could make the gate exit 0.
25. Both gates now capture the `gh` output straight into memory with `! CHANGED=$(gh api --paginate ... 2>/dev/null)`. The temporary file, its `mktemp ... || exit 2` line and the unused `CHANGED_COUNT` are removed.
26. Hakim must check this change, because it touches the same trust property.

#### Residual risks

27. Two FIFO cases can make a process wait for a reader or a writer. Both end at the dispatcher timeout. These are denials of service only.
    - The reader checks `[ -f ]` before it reads. A same-uid process can swap `<dir>/files` for a FIFO between that check and the `head -c` read. `head` then waits.
    - A same-uid process can create a FIFO at `<dir>/files` after `mktemp -d` and before the write. `noclobber` does not refuse a FIFO, so the writer waits.
    - On Claude Code 2.1.295 or later, the timeout blocks the call (`onFailure: block`), so these cases fail closed.
    - On an older client, a hook timeout lets the call run. That is not a regression. Any hung gate behaves the same way on such a client.
28. A same-uid process with debugger rights can change a process's memory. This record does not address that risk. On macOS, SIP protects `/bin/bash`, which runs the gates. The dispatcher runs under the first bash on `PATH`.
29. The file list is not tied to the head SHA. A push during the file-list call, then a push back before the recheck, gives a file list from another commit. The same race existed before, because each gate read the head and the list at different times.

### D3. One reader in the library

1. The readers live in `_lib-extract-pr.sh`: `prmeta_get <field> <pr> <repo>` (head, branch, base, count) and `prmeta_file_list <pr> <repo>`.
2. Each reader checks the PID binding, the key and the value shapes. The file-list reader also checks the directory, the file, the digest and the line count.
3. Valid value shapes:
   - Head SHA matches `^[0-9a-f]{40}$`.
   - `BRANCH` and `BASE` are not empty and hold no control characters.
   - `APEXYARD_PRMETA_FILES_SHA256` matches `^[0-9a-f]{64}$`.
   - `COUNT` is an integer from 0 to 3000 with no leading zero.
   - Repo and PR equal the gate's own `resolve_merge_repo` and `extract_pr_number` results exactly.
4. `resolve_pr_head` and `resolve_pr_head_branch` call the reader first.
5. A new `resolve_pr_base_ref` replaces the inline base-ref call in `block-unreviewed-merge.sh`.
6. `block-merge-on-red-ci.sh` calls the head reader when `CMD_REPO` is not empty. Otherwise it fetches.
7. The design and architecture gates call the readers for the list and the count. On a miss they make their two calls into memory. The whole final guard (`CHANGED_RC`, empty list, more than 3000 files) runs on the hit path and on the miss path.
8. The prefetch builds the key with the same library parsers. There is no second parser.
9. With `APEXYARD_DEBUG_PRMETA=1`, each reader prints one stderr line: hit, or miss and the reason. The line holds no file list. The name is outside the `APEXYARD_PRMETA_` prefix on purpose. The flag only prints.
10. Each gate adds the new library functions to its `_require_lib` list, so a library without them fails closed.

### D4. Head recheck

1. After the fourth gate passes, and only when `_prmeta_have_snapshot` is 1, the dispatcher runs `recheck_pr_head`. It captures the head with `if ! h=$(gh pr view <N> --repo <R> --json headRefOid -q .headRefOid 2>/dev/null)`. Every failure path calls `exit 2`.
2. When the result differs from `APEXYARD_PRMETA_HEAD`, the dispatcher exits 2 with "BLOCKED: PR #N HEAD moved during gate evaluation". The message names both SHAs and tells the operator to retry.
3. When the read fails or the result is not a 40-character lowercase SHA, the dispatcher exits 2 with "BLOCKED: could not confirm PR #N HEAD".
4. After the recheck, `clear_pr_metadata` removes the snapshot from the environment, so a later hook in the same dispatch does not see it.

Why the recheck is needed: with one snapshot, the CI gate reads the runs for the old head. The old head can be green. Without a recheck, the forge then merges a new, unreviewed head. The pinned merge with `--match-head-commit` is a follow-up ticket (CEO decision 1).

### D5. A prefetch failure never changes the exit status

1. The first statement of `run_merge_gates` installs a completion-flag EXIT trap:
   `trap '_rc=$?; if [ -n "${_prmeta_dir:-}" ]; then rm -rf -- "$_prmeta_dir" 2>/dev/null || true; fi; if [ "${_dispatch_complete:-0}" != 1 ]; then _rc=2; fi; exit "$_rc"' EXIT`
   - Every exit before completion becomes exit 2, whatever its status. A crash with status 0, 1 or any other value then blocks on every client.
   - `_dispatch_complete=1` is the last statement of `dispatch-bash.sh`. A normal pass then exits 0.
   - Every explicit `exit` in `dispatch-bash.sh` is `exit 2`. A later edit that adds a planned exit after the trap must set the flag first. `test_prmeta_1759.sh` checks this statically.
   - A dispatch that never reaches `run_merge_gates` gets no trap and behaves as before.
2. The prefetch is one function. It checks each step with `if`. The caller runs it as `prefetch_pr_metadata || true`.
3. A failure in `mktemp`, `gh`, `jq`, the digest or the write leaves no partial export. The gates then fetch.
4. A failure in the cleanup never changes the exit status.
5. A kill signal that bash cannot trap, such as SIGKILL, skips the trap. The directory then stays in `$TMPDIR`. No later dispatch uses it.

### D6. Call count after the change

| Case | Before | After (measured) |
|------|--------|------------------|
| Plain merge, no UI or design files, checks present | 9 | 5 |
| Same, no checks | 10 | 6 |
| Squash merge, UI and design files, checks present | 12 | 5 |
| `gh pr checks` gives no result (AgDR-0244 fallback) | +2 | +2 |
| No `--repo`, no literal PR number, or glab | Unchanged | Unchanged, because D1 makes no prefetch |

### D7. Timeout and NFR

Measurement: the real dispatcher and the real four gates in a sandbox ops root with fixture markers, `/bin/bash` 3.2 on macOS, n=30, plain merge with checks present. "Before" is upstream `dev` `4ef5fee`.

| Host | Calls before / after | p50 before / after (ms) | p95 before / after (ms) |
|------|----------------------|-------------------------|-------------------------|
| macOS, real GitHub API, open 5-file PR | 9 / 5 | 10818 / 7209 | 13015 / 9567 |
| Simulated #1759 host (`gh` shim, 0.9 to 1.9 s per call) | 9 / 5 | 14553 / 8172 | 16669 / 9661 |

- NFR-1 (p95 15 seconds or less on the #1759 host): met on the simulated host, 9661 ms. The real #1759 host was not available.
- NFR-2 (macOS p95 not above 2748 ms): not comparable. 2748 ms was a route that the review gate blocked early, on a faster network. On today's network the full route went from 13015 ms to 9567 ms.
- NFR-3: the 8-call exception path is about 8 x 1.9 + 1.2 = 16.4 seconds on the #1759 host, under the new timeout.
- The profile line after #1759 was `profile: dispatch-bash.sh p95_ms=9661` (plain merge, simulated host).
- The timeout after #1759 was 60 seconds. 5 x 9661 ms is 48.3 seconds. Rounded up to 60 seconds for the 6-call and 8-call routes.
- **#1796** re-profiles on the #1770 chain (simulated p95 14885 ms) and sets the timeout to 75 seconds. See § Architecture evolution and the updated #1770 table.
- No document gives `.claude/settings.local.json` timeout advice.
- A per-call time limit shipped in #1796 (`apexyard_gh`).

#### Carry-over chain shape (PR #1770)

The CEO asked for a measurement on a branch with a chain of "merge dev into branch" commits. PR #1770 (merged as `64e6e10`) has 4 such merges. When the Rex marker is on the last reviewed commit, `block-unreviewed-merge.sh` runs the carry-over walk in `_lib-merge-behind.sh` (`rex_approval_carries_over`). The walk makes one `gh api branches/<base>` call, then one `gh api commits/<sha>` call for each step, with local git work between the calls.

Measurement: the real dispatcher and the real four gates in a sandbox ops root, a squash merge of #1770, the Rex marker on `f107fb9`, the other markers on the head `9ae6007`, n=30, `/bin/bash` 3.2 on macOS. "Simulated" replays recorded real responses with 0.9 to 1.9 s per call.

| Host | Calls after #1759 / after #1796 | p50 after #1759 / after #1796 (ms) | p95 after #1759 / after #1796 (ms) |
|------|----------------------------------|-------------------------------------|-------------------------------------|
| macOS, real GitHub API | 10 / 6 | 9918 / 11322 | 11469 / 16542 |
| Simulated #1759 host | 10 / 6 | 17861 / 13656 | 18986 / 14885 |

(#1759 columns: AgDR table above for the #1770 shape. #1796 columns: n=30 on this build, fair before = post-#1759 hooks at `46ffd5ff`.)

- The snapshot removes 5 calls: 3 `gh pr view` calls in the review gate, the CI gate head read, and one of the two duplicate file-list pairs. The recheck adds 1.
- **#1796:** the walk is one GraphQL call (base tip + up to 10 first-parent steps). Rex and CEO share the memo in one process. Route calls: 6.
- For this shape on the simulated host after #1796, NFR-1 is met: p95 14885 ms.
- 5 x 14885 ms is 74.4 seconds. The dispatcher timeout is **75 seconds** (inside CEO decision 4's 60–75 band; tell the CEO before going above 75).
- Per-call limit: `apexyard_gh` default 20 s (`_lib-gh-timeout.sh`).

### D8. Rollback

1. To revert the prefetch, remove the `prefetch_pr_metadata || true` line in `run_merge_gates`. Then there is no snapshot and no recheck, and the gates fetch.
2. The reader changes in the gates stay harmless after that revert.
3. That revert does not revert the in-memory miss path (D2 rule 25). That change is safe on its own. Keep it.
4. The timeout change reverts on its own: the `timeout` value in `.claude/settings.json` and the profile line.
5. The change keeps no persisted state and needs no data migration.

### D9. Tests

`.claude/hooks/tests/test_prmeta_1759.sh` covers the D9 list of the v6 design. The case labels carry the D9 numbers.

- Layer A runs the real dispatcher with the real four gates in a sandbox, with a logging `gh` shim: the call counts (1), head moved (10), recheck failure and bad SHA (11), no prefetch for a non-merge `gh api` call, a missing `--repo`, a variable target, glab and conflicting repo flags (12, D1), a gate block (13), prefetch failures (14), cleanup failure (15), `COUNT=0` and the empty list (20), scalars without the list (21), no temporary list file (22), the writer count check (27), the enterprise host (28), inherited `APEXYARD_PRMETA_*` (8) and inherited control variables (32). Each new allow path has a paired unsafe case: a UI PR with no design marker and a stale Rex marker still block on a cache hit.
- Layer B calls the readers from a child whose parent is the snapshot owner: wrong key (2), no snapshot (3), invalid values (4), rewritten file (5, 17), line count (6), unsafe directory (7), wrong owner PID (9), FIFO, `/dev/zero` symlink and a file over 4 MiB (19), empty file with a valid digest (20), writer and reader agreement on the whole file and a prefix that must not match (18), a 3000-path list out of the environment (16), and the final guard for `COUNT` above 3000 (26).
- Layer C makes fault copies of the real `dispatch-bash.sh` at test time, at named anchors, for every crash class in § "Fail-open class": an unset read as a plain statement, in an `if` condition and in an `&&` list, inside the prefetch (23); an unset read in the recheck (24); a bare `grep -qE`, a bare failing capture and a `pipefail` abort in the recheck (30); an unset read in the D1 checks and right after the trap (31); and an inherited `_dispatch_complete=1` with a crash (32). Each gives exit 2.
- A static check (33) confirms that every `exit` in the dispatcher is `exit 2`, that `_dispatch_complete=1` is the last statement, and that the trap is the first statement of `run_merge_gates`.
- The suite runs on `/bin/bash` 3.2 on macOS and on bash 5 in the Linux CI job (test 29).

### D10. Order with #1761

This change lands after #1761 and is built on it. The key uses the gates' own parsers, so it follows the #1761 matcher with no extra edit.

## Consequences

- With a literal PR number and `--repo` on the `gh` path, the route drops from 9 to 12 calls to 5 or 6.
- A new trust surface enters the chain: exported scalars, a PID binding and a digest-checked file. Hakim must review the prefetch, the readers, the recheck, the trap and the in-memory miss path.
- The miss path in the design and architecture gates no longer uses a temporary file.
- A future change that starts a gate under a forking wrapper or in a pipeline loses every cache hit.
- The recheck adds one call and closes a race that the gates left open after the review gate's head read.
- glab keeps its own fetch. A merge with no `--repo` gets no prefetch (#887 class unchanged).
- Every exit before completion in a merge dispatch becomes exit 2.
- A larger timeout means a hung call holds the operator longer before the fail-closed block.
- The file-list cache needs a SHA-256 tool. Without one, the route is slower, not less safe.
- No document gives `.claude/settings.local.json` timeout advice. A follow-up ticket tests which `timeout` wins when two entries merge (CEO decision 5).

## CEO decisions (2026-10-19)

1. Recheck the head now. File the pinned merge with `--match-head-commit` as a follow-up ticket.
2. Use exported scalars, the PID binding and a digest-checked file list. Hakim reviews it.
3. NFR-1: merge-route p95 is 15 seconds or less on the #1759 host.
4. Set the timeout from a new measurement. The expected value is 60 to 75 seconds.
5. Remove the `.claude/settings.local.json` timeout advice until a test shows which `timeout` wins.
6. Keep glab uncached. Track the paydown in a ticket.
7. Land this change after #1761.

## Follow-up tickets

Not filed by this build. The CEO accepted the first and third rows. The other rows need the CEO's go first.

| Title | Scope |
|-------|-------|
| [Task] Pin `_tracker_merge_gh` to the reviewed head | Pass `--match-head-commit <snapshot SHA>` so the forge refuses a moved head. |
| [Task] Decide head pinning for raw merges | Choose a gate rule for a raw merge without `--match-head-commit` or `-f sha=`: require, warn, or record as residual. |
| [Task] Add a glab prefetch or a glab call budget | Prefetch through `glab mr view --output json`, or measure the glab route and record its budget. |
| [Task] Test which dispatcher timeout wins on override | Test a repeated dispatcher entry in `.claude/settings.local.json`, then document the result. |
| [Spike] Per-call time limit for merge-gate `gh` calls | **Done in #1796** (evolution entry above). `_lib-gh-timeout.sh` / `apexyard_gh`; default 20 s; `timeout` / `gtimeout` / watchdog. |
| [Task] Cut the forge calls of the carry-over chain walk | **Done in #1796** (evolution entry above). One GraphQL query per walk; Rex/CEO share the memo in-process. |
| [Discovery, parked under #1762] Function and environment injection into hooks | `BASH_FUNC_<name>%%`, `BASH_ENV` and `PATH` can replace `gh`, `jq` or `shasum` in every gate. |
| [Task] Refuse unscoped merges in the review and CI gates (optional) | Make the review and CI gates block an empty `CMD_REPO` (#887 class). |

## Architecture evolution

### Carry-over walk batching and per-call gh limit (#1796)

The #1759 snapshot cut the plain merge route. It left the Rex carry-over walk
on one forge call per merge-dev step. On the #1770 shape (4 steps) the route
was 10 calls and the simulated-host p95 was 18986 ms, so NFR-1 failed and
60 s was only 3.2 × p95.

This evolution (same AgDR number — not a new decision number) changes the
walk and the gate forge path:

1. **One GraphQL call per walk.** `rex_approval_carries_over` loads the base
   tip (`repository.ref(qualifiedName: refs/heads/...)`) and up to 10
   first-parent commits (oid, tree, parents) in a single `gh api graphql`
   query. The forge stays the source of parents and trees. Local git only
   recomputes merge-tree and ancestry.
2. **Shared memo in one gate process.** Rex and CEO call the walk in the
   current shell (via `_REX_CARRY_LAST`), not only via `$()`. The second
   check reuses the same chain when `(repo, new_sha, base)` match.
3. **Per-call time limit.** `_lib-gh-timeout.sh` / `apexyard_gh` wraps each
   merge-route `gh` call. Default 20 s (`APEXYARD_GH_CALL_TIMEOUT`). Prefers
   `timeout`, then `gtimeout`, then a bash-native watchdog. A stall returns
   124 and prints a BLOCKED line; the review gate treats carry-over
   `timeout` as exit 2. The wrapper wraps the `gh` child only, so the
   AgDR-0256 PPID binding for PR metadata still holds.

4. **Watchdog + command substitution (CI suite cap).** The watchdog must
   write its timeout flag before signalling, and must TERM/KILL direct
   children of the `gh` PID. A test stub that ran `sleep 120` under a
   shell (not `exec sleep`) left that sleep as a child; bash `$()` in
   `_rex_carry_fetch_chain` waited for it for the full 120 s, so
   `test_block_unreviewed_merge.sh` hit the Linux CI per-suite cap
   (rc=124) even though the case asserted "forge call timed out". Tests
   use `exec sleep` and `APEXYARD_GH_CALL_TIMEOUT=1`. The suite stays well
   under 120 s. Cap unchanged.

5. **Host-qualified repos stay on github.com only (#1809 H1, A6, A7, A8, B6).**
   The walk parses `OWNER/REPO` and `github.com/OWNER/REPO`. Any other
   `HOST/OWNER/REPO` returns `unknown` with no forge call. Reasoning: if
   the walk stripped a non-github host, it would read a different
   repository on a different forge (cross-forge twin). On `dev`, that shape
   already failed closed via a 404 on the REST path. This PR does not add
   enterprise-host support.
   - Hostname rule (B6): the GraphQL call passes `--hostname github.com`
     only for the explicit `github.com/OWNER/REPO` form. This is the rule
     `block-merge-on-red-ci.sh` uses. A plain `OWNER/REPO` passes no
     `--hostname` and follows `GH_HOST`, like the rest of the gate.
   - Fetch URL (A7): for the explicit `github.com/OWNER/REPO` form, the
     fallback fetch URL is `https://github.com/OWNER/REPO.git`. The host
     segment is not repeated in the URL.
   - Segments (A8): the explicit form has exactly three segments. A value
     with four or more segments returns `unknown` with no forge call, as
     `merge_repo_is_valid` does.

6. **GraphQL string variables use `-f` (#1809 A3).** `owner`, `name`,
   `oid`, and `qname` stay strings. `-F` would coerce an all-digit value to
   an integer and fail the GraphQL type check.

7. **`tracker_review_at_sha` uses `apexyard_gh` (#1809 A2).** The posted-
   review check shares the same per-call limit. A stall returns rc 2 (fail
   closed).

Fail-closed rules are unchanged: an unreadable step, a tree mismatch, or a
chain over 10 steps still means "does not carry over".

Measurement (n=30, #1770 shape): see the updated table under § "Carry-over
chain shape (PR #1770)". Simulated p95 after #1796 is 14885 ms. The
dispatcher timeout is 75 seconds (5 x that p95, rounded up inside the
CEO 60–75 band). Profile line: `profile: dispatch-bash.sh p95_ms=14885`.

## Artifacts

- me2resh/apexyard#1759, #1623, #1760, #1761, #1796
- AgDR-0104, AgDR-0109, AgDR-0120, AgDR-0162, AgDR-0169, AgDR-0244, AgDR-0247
- `.claude/hooks/dispatch-bash.sh`, `.claude/hooks/_lib-extract-pr.sh`, `.claude/hooks/_lib-merge-behind.sh`, `.claude/hooks/_lib-gh-timeout.sh`, the four merge gates
- `.claude/hooks/tests/test_prmeta_1759.sh`, `.claude/hooks/tests/test_lib_merge_behind.sh`
- `docs/perf/hook-fail-closed-profile-2026-10.md`, `docs/hooks-fail-closed.md`
- Design reviews: Tariq (2026-10-19), Hakim security review of v4 and delta checks of v5 and v6 (2026-10-19). Hakim's v6 advisories are in this build: the crash-class tests, the control-variable unset, the whole-file digest test and the rule 27 wording.
