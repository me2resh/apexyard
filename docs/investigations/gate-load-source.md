# Investigation: gate load sources

Local gates load executable files from the ops-fork working tree. They do not select the PR base revision.
Review instructions and handbooks also lack a required revision pin. CI runs candidate code and candidate tests together.
Use a trusted baseline for enforcement. Treat candidate checks as additional regression tests.

## Trigger

On 2026-11-21, [issue #2093](https://github.com/me2resh/apexyard/issues/2093) requested this investigation.
A framework change might alter the checks that judge that change.
The owner required an offline investigation and prohibited hook, workflow, and agent changes.

## Terms

- **Ops tree** means the ops-fork working tree selected by the session pin or directory search.
- **Base** means the target branch commit recorded for a PR.
- **Head** means the candidate commit submitted by a PR.
- **Candidate checkout** includes a synthetic merge of the base and head.
- **Trusted baseline** means an independently approved revision selected outside candidate-controlled files.
- **Self-judgment** means candidate rules control a check applied to that candidate.

## Hypotheses being tested

- H1: Local gates always load rules from the base. Rejected.
- H2: A separate ops tree isolates managed-project changes from local gate changes. Supported, with conditions.
- H3: Every Rex guide loads from a trusted revision. Rejected as a documented guarantee.
- H4: CI separates candidate implementation from trusted test policy. Rejected for the hook suite.

## Method

1. Read `CLAUDE.md`, the writing rule, and `templates/tickets/investigation.md`.
2. Trace settings, dispatchers, gate dependencies, marker writers, handbook discovery, and review policy resolution.
3. Inspect every workflow that directly invokes `.claude/hooks/tests` or the hook suite runner.
4. Run the selected local regression suites through `bin/run-hook-tests.sh`.

Evidence refers to tracked files at `7aba837ef84e45493ed855c849cd14c686adae00`.
The existing branch is `docs/GH-2093-gate-load-source`. Local `dev` is an ancestor at `a3028d17f3aed6b40b52751d819487ad29e1adda`.
Local `origin/dev` differs. Network access prevents checking its freshness or the current remote base.
No branch reset occurred. The existing worktree and history remain intact.
Recipes below are proposed demonstrations. They were not executed against weakened checks.
No live PR, forge response, ruleset, harness session, or hosted workflow was tested.

## Findings

### Observations: local execution boundary

`.claude/settings.json:84` resolves the session pin first, then searches parent directories for an ops anchor.
It executes `$r/.claude/hooks/dispatch-bash.sh`. The shell-alias entry repeats this at `.claude/settings.json:95`.
The pin contains a directory, not a commit. `_lib-ops-root.sh:286-312` implements the same directory selection.
The helper normalizes linked worktrees to their main checkout at `_lib-ops-root.sh:80-104,134-137`.
`pin-ops-root.sh:90-91` uses that helper when establishing the session pin.
The inline settings wrapper searches directories directly when no valid pin exists.
Therefore, a normal pinned session can retain main-checkout hooks while reviewing a linked candidate worktree.
`dispatch-bash.sh:23` locates sibling hooks. Lines 95-97 source the sibling merge parser.
Lines 154-168 enforce failure handling. Lines 440-443 invoke all four merge gates.
None of these steps exports gate code from the base.

The table uses paths relative to `.claude/hooks/` unless another root appears.
Each row states whether edits can judge themselves.

| Check | Code or rule source and evidence | Does the edited copy judge its PR? |
|---|---|---|
| Rex and human merge approvals | Ops tree. `block-unreviewed-merge.sh:109-137` loads sibling libraries. Lines 299-309 select marker storage. Lines 450-492 handle approval carry-over. | Yes, if the selected ops tree contains the candidate changes. No automatic head fetch selects the code. |
| Posted Rex review requirement | Ops tree code and configuration. `block-unreviewed-merge.sh:502-553` reads `review_markers.require_posted_review` and calls the tracker library. | Yes under the same condition. A candidate configuration edit can also disable this optional requirement. |
| Green CI merge gate | Ops tree code. `block-merge-on-red-ci.sh:144-153` loads sibling parser and repository helpers. Lines 27-49 describe forge checks against head. | Yes under the same condition. Forge results describe head, but the local acceptance logic comes from the ops tree. |
| UI design merge gate | Ops-tree code. `require-design-review-for-ui.sh:116-133,229-249` loads sibling libraries. Lines 216,253,301-302 read project-root configuration. Lines 320-321 select the design marker. | Candidate ops-tree code can suppress the trigger. Project-clone `ui_paths` or `ui_paths_exclude` edits can also suppress it with unchanged ops hooks. |
| Architecture merge gate | Ops-tree code. `require-architecture-review.sh:101-118` loads sibling libraries. Lines 201,224-225,272-273 read project-root configuration. Lines 291-292 select the marker. | Candidate ops-tree code can suppress the trigger. Project-clone `design_paths` or `design_paths_exclude` edits can also suppress it with unchanged ops hooks. |
| Rex marker body and verdict validation | Ops tree. `.claude/skills/code-review/SKILL.md:87-90` sources the ops marker library. `_lib-review-markers.sh:677-711` validates the body, verdict, and SHA before writing. | Yes when the candidate library occupies that ops tree. Validation does not authenticate its own source revision. |
| Human approval prerequisite helper | Supplied ops tree. `.claude/skills/approve-merge/scripts/approve-merge.sh:8-25,49-65` loads configuration, carry-over logic, and marker helpers from `marker_home`. | Yes if candidate files occupy that supplied tree. This helper checks prerequisites before human approval. |
| Typed human marker writer | Ops-tree skill. `.claude/skills/approve-merge/SKILL.md:117,148-178` loads the marker helper and specifies the structured approval record. | Yes if candidate skill or library content supplies the procedure. Human approval remains a separate required action. |
| Menu approval writer and validator | Ops-tree `record-menu-approval.sh:40-65` loads sibling helpers and writes the selected approval. `_lib-menu-approval.sh:41-45` defines record validation. | Yes if candidate files occupy the selected ops tree. This applies to human, design, and architecture menu records. |
| Menu approval forgery backstop | Ops-tree `block-forged-menu-approval.sh:1-16,90-96` loads its sibling write detector. `dispatch-bash.sh:259-265` routes it. | Yes under the same condition. Text matching does not authenticate the source revision. |
| Marker-write warning | Ops tree. `.claude/settings.json:75` invokes `warn-review-marker-write.sh`. `dispatch-bash.sh:255` also routes it. `warn-review-marker-write.sh:814-870` warns and exits zero. | Yes under the same condition. This is an advisory backstop, not an approval control. |
| Reviewer file-write restriction | Ops tree. `.claude/settings.json:64` invokes `limit-reviewer-writes.sh`. Its lines 40-70 source sibling libraries and identify the hook root. | Yes under the same condition. Its current policy blocks reviewer writes outside the review-body folder. |
| Reviewer repository mutation restriction | Ops tree. `dispatch-bash.sh:121-122` passes its own ops root. Lines 255-258 route the reviewer restrictions. | Yes under the same condition. The restriction does not pin its implementation. |
| Stale approval warning | Ops tree. `.claude/settings.json:128` invokes `warn-stale-review-markers.sh`. Its lines 64-96 load sibling helpers. | Yes under the same condition. Changing this warning alone does not remove the merge SHA check. |
| Unqualified approval warning | Ops tree. `.claude/settings.json:132,145` invokes `warn-unqualified-review-marker.sh`. Its lines 91-118 load sibling helpers. | Yes under the same condition. This warning does not accept an approval. |
| Active-reviewer cleanup | Ops tree. `clear-active-reviewer-marker.sh:45-72` loads sibling root and marker helpers. | Yes under the same condition. This changes review-session state, not the merge verdict directly. |
| Live hook and settings write guard | Ops tree. `.claude/settings.json:34` invokes `block-protected-target-writes.sh`. Its lines 5-17 load sibling protection code. | Candidate code can govern a later session rooted there. Current-session protection limits direct mutation, as described below. |
| Hook-disabling configuration guard | Ops tree code. `block-hook-disabling-config-change.sh:21-36,59-85` compares settings with a session snapshot or local HEAD. | A later session can start with candidate code. The comparison baseline is not necessarily the PR base. |

Approval state and enforcement code have different sources.
`block-unreviewed-merge.sh:305-309` stores approvals under the ops root.
`require-architecture-review.sh:248` reads candidate file names through the forge when snapshot data is absent.
`require-design-review-for-ui.sh:276` does the same for UI changes.
Those head-derived inputs do not make the executing hook a head checkout.
Marker SHA checks bind approval to code. They do not bind enforcement to a trusted baseline.

`block-protected-target-writes.sh:27-29` rejects direct edits to live hook state.
`_lib-protected-state.sh:46-73,79-86` derives protected roots from the session pin, snapshot, and project directory.
`block-protected-target-writes.sh:65-70` explicitly permits isolated worktree development outside the live tree.
Therefore, ordinary edits in a separate candidate worktree do not replace the running ops-tree hooks.
A session subsequently rooted in that candidate tree can execute its copies.
This is a source-selection weakness, not proof that the current write guard permits live hook edits.

### Observations: Rex guides and handbook sources

The review instructions name paths rather than immutable revisions.
`.claude/agents/code-reviewer.md:17-35` names framework rules and handbooks.
The agent omits `CLAUDE.md` according to lines 22-24.
The following table records the specified sources. It does not claim an observed harness load.

| Guide or loader | Source and evidence | Self-judgment condition |
|---|---|---|
| Rex agent definition | Installed ops-tree agent path. `.claude/skills/code-review/SKILL.md:27` names `.claude/agents/code-reviewer.md`. | Yes if the harness loads the candidate definition. An already loaded agent might retain its earlier instructions. |
| Code-review skill | Ops-tree skill. `.claude/skills/code-review/SKILL.md:49,62,68` names writing, policy, and depth guides. | Yes if invoked from candidate skill content. The repository does not specify a base export for the whole skill. |
| Framework review rules | Ops-tree paths in `.claude/agents/code-reviewer.md:26-35`. | Yes if those paths resolve into the candidate tree. This includes quality, workflow, writing, ceremony, evidence, code, role, and decision rules. |
| Review workflow | `workflows/code-review.md`, named by `.claude/agents/code-reviewer.md:35`. | Yes if the reviewer reads the candidate copy. No base revision appears in that instruction. |
| Severity and policy guide | `docs/skills/drive-to-green.md:9-22` resolves a project policy, then a shared policy. | Yes if the guide, resolver, or resolved policy comes from candidate-controlled storage. The no-weakening rule is prose. |
| Project review policy | Private portfolio `custom-templates/projects/<project>/REVIEW.md`. `docs/skills/drive-to-green.md:14-19` specifies precedence. | A framework-only PR cannot normally edit a separate private repository. A PR controlling the selected local policy can affect review. |
| Shared review policy | Private portfolio `custom-templates/REVIEW.md`, then ops-tree `templates/REVIEW.md`. `_lib-portfolio-paths.sh:971-1000` resolves existing files. | Yes for a selected candidate copy. A separate private override prevents changes to the unused framework default from taking effect. |
| Review-depth guide | Ops-tree `docs/skills/code-review-depth.md:3-9` requires exporting the tier script from base or a recorded trusted ops baseline. | The script has an explicit trusted-source rule. The guide itself has no revision pin. |
| Tier classifier | Base `bin/review-tier.sh`, or trusted ops baseline, per `docs/skills/code-review-depth.md:3-9`. | No, when that procedure is followed. A head-only script edit must not control its own tier. |
| Public handbook discovery guide | Ops-tree `handbooks/README.md:13-24` and agent discovery at `.claude/agents/code-reviewer.md:430-455`. | Yes for candidate guide content. Their architecture/general applicability wording differs. The agent narrows applicability by changed paths. |
| Public architecture handbooks | Ops-tree `handbooks/architecture/*.md`. Agent lines 432-449 define selection. | Yes when candidate files occupy the selected public root. |
| Public general handbooks | Ops-tree `handbooks/general/*.md`. Agent lines 432-449 define selection. | Yes under the same condition. |
| Public language handbooks | Ops-tree `handbooks/language/<lang>/*.md`. Agent lines 432-449 match language extensions. | Yes under the same condition. |
| Public domain handbooks and guide | Ops-tree `handbooks/domain/<area>/*.md` and `handbooks/domain/README.md`. Agent lines 450,457-466 define glob matching. | Yes under the same condition. Candidate `paths` edits can exclude the changed code. |
| Private handbooks | Configured `portfolio_custom_handbooks_dir`. `_lib-portfolio-paths.sh:589-602` defaults to `./custom-handbooks`. Agent lines 430-455 load both layers. | No for changes confined to a separate public framework tree. Yes if candidate configuration redirects the root or candidate files occupy it. |
| Handbook enforcement guide | `.claude/agents/code-reviewer.md:468-479` applies both layers and reads `ENFORCEMENT: blocking`. | Yes when the agent or handbook body comes from the candidate tree. |
| Agent reference guide | `docs/agents/code-reviewer-reference.md`, linked at `.claude/agents/code-reviewer.md:20`. The agent does not require reading it for every review. | Conditional. Candidate changes affect review only when the reviewer consults that copy. |
| Review-copy guide | Ops-tree `docs/skills/review-copies.md:3-10`, required by `.claude/skills/code-review/SKILL.md:45`. | Yes if candidate instructions supply the procedure. This guide selects the test checkout, not a trusted policy revision. |

The public substantive samples are `architecture/clean-architecture-layers.md`, `architecture/migration-safety.md`, `general/commit-message-quality.md`, and `language/typescript/strict-mode.md`.
All use the public-root loading path above. Index files do not establish another trusted source.
`handbooks/architecture/migration-safety.md:10,19-28` declares blocking enforcement and prohibits destructive single-step migrations.
The same file says handbook amendments require a separate PR at line 15.
That instruction discourages weakening. The loader does not enforce separate revisions.

The scratch clone does not define the policy source.
`.claude/agents/code-reviewer.md:77-86` uses scratch copies for candidate tests.
`.claude/skills/code-review/review-copy.sh:74-77` fetches and checks out `refs/pull/<pr>/head`.
Reading a policy relative to that clone would read head. The instructions do not require doing so.
Thus universal claims that Rex always reads head, or always reads base, lack evidence.

### Observations: CI hook-test workflows

The following classification comes from repository YAML and scripts.
For `pull_request`, the `github.sha` checkout represents the synthetic merge containing candidate changes.
This event interpretation was not verified against hosted Actions because network access was disabled.

| Workflow or component | Load source with evidence | Can candidate changes affect their own check? |
|---|---|---|
| `.github/workflows/tests.yml` tier selection | Candidate checkout on PRs. Lines 34-53 check out `github.sha` and run `bin/select-affected-tests.sh`. | Yes. The selector can classify its own change as docs-only. |
| Hook matrix | Candidate checkout. `tests.yml:64-78,108-139` checks out `github.sha` and runs `bin/run-hook-tests.sh`. | Yes. Candidate hooks, tests, runner, and workflow affect the result. |
| Required-check aggregation | Candidate workflow logic. `tests.yml:154-173` maps matrix and tier results into `hook test suite`. | Yes. Candidate aggregation can accept a skipped suite or omit failure enforcement. |
| Reviewed parser snapshots | Separate upstream objects. `tests.yml:115-137` fetches PR 1466 and checks three complete commit SHAs. | Snapshot bytes are pinned. Candidate workflow and tests still decide whether to verify or use them. |
| Suite discovery and quarantine | Candidate runner. `bin/run-hook-tests.sh:108-145` selects the repository, quarantine list, and discovered tests. | Yes. Candidate edits can remove tests or quarantine failures. |
| Subpack smoke tests | `.github/workflows/extract-subpacks-on-release.yml:23-26,71-79` uses a PR trigger, default checkout, and candidate hook test. | Yes on PRs. Release and manual events use their selected event revision, not a PR-specific trusted base. |
| Scaffold fault tests | `.github/workflows/scaffold-starter-gates.yml:4-9,56-69` uses default checkout and candidate hook-test fixtures. | Yes on PRs. Candidate patches or `expect-fault.sh` can suppress fault detection. |

For scheduled runs, `tests.yml:37,77` explicitly selects `dev`.
Push and manual runs use the event SHA through the same expressions.
Neither path provides an independent pre-merge check for the candidate PR.
`adapter-tests.yml:12-16,43-63` runs adapter unit tests from a default candidate checkout, not the hook bash suite.
ShellCheck and harness conformance provide other checks. They do not establish a trusted hook-test baseline.
Workflow comments describe a required check. Remote ruleset requirements remain unknown.

### Conclusions and reproduction recipes

These recipes use disposable local copies and mocked forge responses. Never merge a real PR during reproduction.
Keep the active ops tree unchanged. Prepare candidate fixtures before any review-session mutation lock starts.
The recipes describe expected results from source analysis. They are not reported as executed exploit proofs.

#### W1: local gate code can come from the candidate

Applies to every local executable row above, including dispatcher, dependencies, marker controls, and protection hooks.

1. Export the recorded source into two disposable directories named `baseline` and `candidate`.
2. Use the corresponding existing hook test to obtain a blocked JSON payload and mocked forge responses.
3. Run the baseline hook against that payload. Record exit 2.
4. Replace only the candidate hook with a script that exits zero.
5. Invoke the candidate hook with the same payload. Record exit zero.
6. Resolve the settings wrapper to each directory using a disposable session pin.
7. Confirm that the wrapper selects that directory's dispatcher and sibling hook.

Use standalone exports for this recipe. A normal linked-worktree pin resolves back to the main checkout.
This shell example prepares a disposable copy and calls one gate without invoking a forge command:

```bash
probe_dir=$(mktemp -d)
git archive HEAD | tar -x -C "$probe_dir"
printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --repo example/demo"}}' > "$probe_dir/payload.json"
printf '#!/bin/bash\nexit 0\n' > "$probe_dir/.claude/hooks/block-unreviewed-merge.sh"
bash "$probe_dir/.claude/hooks/block-unreviewed-merge.sh" < "$probe_dir/payload.json"
printf 'candidate exit=%s\n' "$?"
```

The synthetic repo and PR are fixture values. The hook receives JSON. The shell never executes its embedded merge command.
For baseline denial, use the mocked missing-marker fixture in `test_block_unreviewed_merge.sh:296-304`.
Repeat the candidate invocation for each executable named in the table.

For merge gates, use the four corresponding regression suites listed under Validation.
For marker protections, use `test_protected_review_1839.sh` and `test_warn_review_marker_write.sh` fixtures.
For advisory warnings, compare stderr instead of requiring exit 2.
An individual gate bypass does not prove a complete merge bypass. Other gates can still block.

Proposed fix: execute settings, dispatchers, hooks, and dependency libraries from one independently approved baseline.
Keep that baseline outside candidate-controlled storage. Record its SHA with the review evidence.
Continue testing the candidate implementation separately. Fail closed when the trusted bundle is unavailable.

#### W2: candidate configuration can weaken gate coverage

The architecture and UI gates read path settings from the current directory's git top folder, not necessarily the ops tree.
In a managed-project clone, that folder is the project root.
`require-architecture-review.sh:201,224-225,272-273` selects that configuration.
`require-design-review-for-ui.sh:216-219,253,301-302` does likewise and distinguishes the project root from marker storage.
Project configuration can therefore disable either trigger while ops hooks remain unchanged.
Replacement keys are `design_paths` and `ui_paths`. Exclusion keys are `design_paths_exclude` and `ui_paths_exclude`.
An exclusion matching every changed design or UI file removes that gate's approval requirement.

1. Prepare an unchanged disposable ops tree and two disposable project clones with identical tracked files.
2. Mock forge responses with a design document matching `require-architecture-review.sh:214-221` and a UI file matching default patterns.
3. Leave architecture and design markers absent. Keep other approvals valid.
4. Invoke both ops-tree hooks from each project clone with the same mocked merge payload.
5. Confirm that both gates block before changing project configuration.
6. Set candidate project `design_paths` and `ui_paths` to `["^never-match-this-pr$"]` in `.claude/project-config.json`.
7. Repeat from that clone. Expect both unchanged hooks to return zero because neither trigger matches.
8. Restore default path settings by removing both replacement keys.
9. Set candidate project `design_paths_exclude` and `ui_paths_exclude` to `[".*"]`.
10. Repeat from that clone. Expect both hooks to return zero because exclusions remove all matching files.
11. Confirm that ops-tree hooks and configuration remain unchanged throughout both comparisons.

Use the sandbox helpers in `test_require_architecture_review.sh:95,154` and `test_require_design_review_for_ui.sh:116,175`.
The latter suite demonstrates replacement overrides at lines 260-266.
These proposed comparisons isolate project configuration from ops-tree enforcement code.

Separately, repeat the posted-review fixture with ops-tree `review_markers.require_posted_review` disabled.
`test_require_posted_review.sh:207-223` supplies enabled, disabled, missing-review, and forge-failure cases.
`_lib-read-config.sh:287-330` reads local defaults and overrides for that configuration path.
That loader does not describe the two gates' direct project-root path reads.
None of these configuration sources automatically selects the PR base.

Proposed fix: resolve enforcement configuration from an independently approved baseline for the governed project and ops tree.
Include `design_paths`, `ui_paths`, `design_paths_exclude`, `ui_paths_exclude`, portfolio roots, and posted-review requirements in that trust boundary.
Require separate approval before weaker settings take effect. Preserve head-derived changed-file inputs.
Keep marker storage separate from policy source selection. Fail closed when trusted configuration is unavailable.

#### W3: candidate guides and handbooks can change review policy

1. Prepare baseline and candidate policy trees.
2. Use a migration fixture containing `DROP COLUMN` on a column that the previous release reads.
3. Resolve the migration handbook from each tree using the documented public root.
4. Remove `ENFORCEMENT: blocking` from only the candidate handbook.
5. Compare the required verdict under `.claude/agents/code-reviewer.md:474-479`.
6. Repeat with a domain handbook whose candidate `paths` excludes the changed file.
7. Repeat policy resolution after adding a candidate `custom-templates/REVIEW.md` override.
8. Compare paths and content before requesting a reviewer run.

The enforcement change makes the handbook advisory under the documented algorithm.
An actual model verdict remains unverified. Other blocking rules can still reject the migration.
Candidate edits to agent, skill, workflow, discovery, or severity guides create the same source-selection risk.
A separate private handbook is unaffected unless the candidate controls its resolver configuration or storage.

Proposed fix: supply Rex with a manifest of trusted guide paths and content hashes from approved revisions.
Resolve public handbooks, private handbooks, and policy overrides before exposing the candidate checkout.
Review candidate policy changes as content. Apply them only after independent approval.
Preserve the existing trusted-base tier-script rule. Extend that rule to its caller and guide.

#### W4: CI can approve candidate-defined test policy

1. Export the source into a disposable candidate directory.
2. Add an unconditional failure to one hook test fixture there.
3. Run the original runner. Confirm that it reports failure.
4. Replace the candidate runner with a script that exits zero.
5. Run the workflow's suite command locally, without the network-dependent snapshot fetch.
6. Confirm that the command now returns zero without checking the failing test.
7. Restore the runner. Change the candidate tier selector to classify every change as docs-only.
8. Evaluate `tests.yml:171-173` with successful tier selection and a skipped matrix.
9. Repeat the comparison after replacing the candidate aggregation command with `true`.

For subpacks, replace the candidate `test_subpack_extraction.sh` command with a zero-exit fixture in the disposable copy.
For scaffold tests, use a known fault and a candidate `expect-fault.sh` that always succeeds.
These variants test the same candidate-controlled assertion boundary.
The pinned parser snapshots do not protect a runner that never asserts against them.

Proposed fix: require an independently managed workflow and a trusted runner for policy enforcement.
Obtain that workflow from protected configuration outside the candidate workflow definition.
Run trusted assertions against candidate hooks in a separate checkout with minimal permissions.
Retain candidate-added tests as supplemental coverage. Record base, head, runner, and policy SHAs.
Do not execute candidate code with privileged `pull_request_target` credentials.
Use event-specific checkout rules. A schedule alone does not protect the pre-merge decision.

## Validation

Ran 19 selected suites through `bash bin/run-hook-tests.sh --files <list>`.
Both invocations returned zero. The first took 185 seconds. The second took 36 seconds.

| Suite in `.claude/hooks/tests/` | Result |
|---|---|
| `test_block_unreviewed_merge.sh` | PASS |
| `test_block_merge_on_red_ci.sh` | PASS |
| `test_require_architecture_review.sh` | PASS |
| `test_require_design_review_for_ui.sh` | PASS |
| `test_protected_review_1839.sh` | PASS |
| `test_validate_rex_review_body.sh` | PASS |
| `test_require_posted_review.sh` | PASS |
| `test_warn_review_marker_write.sh` | PASS |
| `test_warn_unqualified_review_marker.sh` | PASS |
| `test_warn_stale_review_markers.sh` | PASS |
| `test_review_tier.sh` | PASS |
| `test_reviewer_scratch_clone_section.sh` | PASS |
| `test_short_delta_review.sh` | PASS |
| `test_block_protected_target_writes.sh` | PASS |
| `test_block_hook_disabling_config_change.sh` | PASS |
| `test_block_forged_menu_approval.sh` | PASS |
| `test_record_menu_approval.sh` | PASS |
| `test_resolve_ops_root_pin.sh` | PASS |
| `test_severity_reviews.sh` | PASS |

Original combined result: PASS=19, FAIL=0, SKIP=0.
The review-fix rerun selected the same 19 suites and took 636 seconds.
Its runner reported 17 passes and two 120-second timeouts, with no skips.
Direct retries without that cap passed `test_protected_review_1839.sh` and `test_block_protected_target_writes.sh`.
Those retries reported 362 and 747 passing cases, respectively, with zero failures.
Markdownlint-cli2, the writing-profile check, and `git diff --check` passed after the corrections.
Agent-file citations were checked against HEAD. The domain selector is at `.claude/agents/code-reviewer.md:450`.
These regression suites test current behavior. They do not establish independence from candidate-controlled policy.
No new test was added because this ticket changes only this investigation document.
Hosted CI, live Rex behavior, and live session reload behavior remain unverified.

## Acceptance criteria

| Criterion | Evidence delivered |
|---|---|
| Record each gate and review guide source. | The local, Rex, and CI tables identify sources and cite file lines. They distinguish base, ops tree, and candidate checkout. |
| List each self-judgment case with a reproduction. | W1-W4 cover executable code, configuration, review policy, and CI assertions. Each recipe states conditions and expected observations. |
| Propose fixes without unapproved follow-up tickets. | Each W1-W4 section proposes a fix. No ticket was filed. |

## Conclusion

Confidence is high for local file selection and the documented policy paths.
Confidence is conditional for actual harness loading and hosted event behavior.
A separate, unchanged ops tree protects managed-project reviews from head-only hook edits.
It does not protect architecture or UI triggers from project-clone path overrides or exclusions.
`design_paths_exclude` and `ui_paths_exclude` can remove every matching file while ops hooks remain unchanged.
A candidate ops tree does not provide that separation. The directory pin is not a revision pin.
The trusted-base tier script provides a useful pattern, but it does not protect the entire review policy chain.

## Follow-up actions

Proposals W1-W4 await owner approval. No follow-up ticket was filed.
Implementation requires separate scope and an approved trust-source design.
This investigation does not authorize a gate change or an issue closure.

## Metadata

| Field | Value |
|---|---|
| Live document | `docs/investigations/gate-load-source.md` |
| GitHub issue | me2resh/apexyard#2093 |
| Started | 2026-11-21 |
| Status | Findings recorded. Remediation proposals await owner approval. |
| Related AgDR | None. This document proposes fixes without adopting a design. |
