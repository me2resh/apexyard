---
name: security-review
description: Security-focused PR review for vulnerabilities and best practices. Invokes the Security Reviewer agent (Hakim).
disable-model-invocation: false
argument-hint: "<pr-number> [repo]"
allowed-tools: Bash, Read, Grep, Glob
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /security-review: Security Review

Review a pull request specifically for security vulnerabilities and best practices.

## LSP-aware (optional, recommended)

This skill performs semantic code navigation: it finds definitions, follows references, and traces handlers across modules.
With LSP enabled (`ENABLE_LSP_TOOL=1` + per-language plugin per `docs/getting-started.md`), queries cost ~3-15× fewer tokens than grep + Read.
Without LSP, use grep + Read automatically. LSP adds optional speed without a new failure mode.

Per-language LSP plugins live in Claude Code's marketplace.
Install once. The skill detects the active language and dispatches automatically.

## Activated agent + role

When `/security-review` runs:

1. **Primary reviewer**: the **Security Reviewer agent (Hakim)** at [`.claude/agents/security-reviewer.md`](../../agents/security-reviewer.md) runs the automated security checklist.
2. **Human approval gate**: activate the **[Security Auditor](../../../roles/security/security-auditor.md)** role for PRs touching auth, crypto, secrets, user data, or PII. Also activate this role whenever the user explicitly invokes `/security-review`.
3. **Strategic calls**: **Hakim** owns threat modelling, compliance analysis, and novel attack surfaces (the [Security Auditor](../../../roles/security/security-auditor.md) § "Security posture", AgDR-0301). The **[Penetration Tester](../../../roles/security/penetration-tester.md)** (Hamza) reviews each threat model that Hakim writes, so Hakim does not review its own threat model. CRITICAL and HIGH findings the change introduced or worsened block the PR. Pre-existing findings follow the remediation SLA (AgDR-0313). A CRITICAL finding the change introduced or worsened blocks the release. For HIGH findings, Hakim recommends that the human approver block the release. Hakim also recommends this for any finding he judges release-blocking. Risk acceptance, exceptions to security requirements, and lifting a release block go to the human approver.
4. **For active testing**: the **[Penetration Tester](../../../roles/security/penetration-tester.md)**: exploit discovery, API security review, pre-release security sign-off.

See [`.claude/rules/role-triggers.md`](../../rules/role-triggers.md) for the full activation protocol.

## Usage

```
/security-review 42
/security-review 42 your-org/your-repo
```

## When to Use

Invoke for PRs that touch:

- Authentication / authorisation
- User input handling
- API endpoints
- Data storage
- Third-party integrations
- Cryptography or secrets

## Review bar for gate PRs (me2resh/apexyard#1845, AgDR-0267)

The shell-text gates are guardrails against honest mistakes, not a security boundary. Hakim applies this bar:

The bar narrows one case only. On a PR that changes `.claude/hooks/**`, a crafted command that the shell-text scan does not catch is advisory. This case includes an exotic shape that `dev` blocks and the head does not.

Every other blocker stays:

- kinds 1, 3 and 4 of the Blocking-Severity Bar (AgDR-0172)
- a gate that fails open on its own error, timeout or bad input
- a hook change that runs code from command text, a cloned repository or other untrusted input
- the checks that `.claude/agents/code-reviewer.md` § "Blocking-Severity Bar" keeps blocking. These are the Acceptance Criteria check, the AgDR check, the Glossary requirement, a handbook marked `ENFORCEMENT: blocking`, and rail 1 of `.claude/rules/right-size-ceremony.md`.

A regression on an ordinary command is kind 1. An ordinary command is one that an agent or a human types. A false block counts. A slowdown above the 2 s target in AgDR-0267 § "Cost budget" counts when `dev` is below it.

A deleted or weakened paired test for a shape that `dev` already blocks is a correctness finding (kind 3).

An exotic bypass shape is advisory. Name its class only, never the exact command. List the class for epic me2resh/apexyard#1846. Do not hunt for new shape classes. Check the delta, the earlier findings, and ordinary commands against `dev`.

The orchestrator adds each listed class to the epic. The full bar is in `.claude/agents/security-reviewer.md` § "Review bar for gate PRs" and in [AgDR-0267](../../../docs/agdr/AgDR-0267-shell-text-gates-are-guardrails.md).

## Running tests in a scratch clone

Hakim may need to run tests or attack probes against the PR head, outside this repository's working tree. Use a plain `git clone` into a literal scratch path. Or export with `git archive <ref> | tar -x -C <scratchpad>` into this session's scratchpad. A sanctioned review needs no ticket for that write. The agent file states the path rule. If a hook blocks a command, stop that step. Report the exact command, the hook, and its message to the orchestrator. Never rephrase, split, encode, or disguise a command to get past a hook. Full pattern: `.claude/agents/security-reviewer.md` § "Running tests in a scratch clone".

The reviewer mutation lock blocks `git clone`, `git fetch`, and `git checkout` while the active-reviewer marker exists. Prepare the scratch clone and fetch the PR head before step 0 arms the marker.

## Process

### 0. Write the active-reviewer marker (REQUIRED: me2resh/apexyard#843)

Before spawning the Security Reviewer agent, write the active-reviewer session marker.
It records this review as sanctioned.
It also suppresses `warn-review-marker-write.sh`'s advisory warning on the `*-security.approved` write, like `/code-review`'s rex marker.
Since #1026, that hook warns and never blocks (AgDR-0111).
Scope the marker to THIS Claude Code session (me2resh/apexyard#1376).
Resolve its path through `active_reviewer_marker_path`.
Never write the bare `.claude/session/active-reviewer` path directly.
At skill entry:

```bash
# Ops root: pin first, then walk up (docs/skills/shared/ops-root.md).
ops_root=$(p="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID:-}"; r=""; [ -z "${APEXYARD_OPS_DISABLE_PIN:-}" ] && [ -f "$p" ] && IFS= read -r r < "$p"; [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] || { r="$PWD"; while [ -n "$r" ] && [ ! -f "$r/.claude/hooks/_lib-ops-root.sh" ]; do r=${r%/*}; done; }; [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] && . "$r/.claude/hooks/_lib-ops-root.sh" && resolve_ops_root) || ops_root=$(git rev-parse --show-toplevel)
. "$ops_root/.claude/hooks/_lib-review-markers.sh"
active_marker=$(active_reviewer_marker_path "$ops_root" "" "<owner/repo>" "<pr>" "security")
mkdir -p "$(dirname "$active_marker")"
printf '%s\n' "<owner/repo>#<pr>:security" > "$active_marker"
```

On skill exit, after posting the review, clear the marker.
Shell variables do not persist across separate Bash tool calls.
Thus, resolve `ops_root` and `active_marker` again during the exit step.
Do not reuse the step-0 variable. It would silently be empty in a later call and make `rm -f` a no-op:

```bash
# Ops root: pin first, then walk up (docs/skills/shared/ops-root.md).
ops_root=$(p="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID:-}"; r=""; [ -z "${APEXYARD_OPS_DISABLE_PIN:-}" ] && [ -f "$p" ] && IFS= read -r r < "$p"; [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] || { r="$PWD"; while [ -n "$r" ] && [ ! -f "$r/.claude/hooks/_lib-ops-root.sh" ]; do r=${r%/*}; done; }; [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] && . "$r/.claude/hooks/_lib-ops-root.sh" && resolve_ops_root) || ops_root=$(git rev-parse --show-toplevel)
. "$ops_root/.claude/hooks/_lib-review-markers.sh"
active_marker=$(active_reviewer_marker_path "$ops_root" "" "<owner/repo>" "<pr>" "security")
rm -f "$active_marker"
```

The marker uses session, repo, PR, and review kind as its key (me2resh/apexyard#1649). Each review writes and clears only its own file, so reviews run at the same time. The mutation lock applies to review agents only. The orchestrator and build agents can keep working. Use the same `<owner/repo>`, `<pr>` and kind in the write step and the exit step. Spawn the reviewer with the Agent tool and `subagent_type: security-reviewer`. Never use `general-purpose`: the lock finds a review agent by that type.

Nothing mechanically stops a build-class sub-agent writing the same file. This marker is legitimate only after a real, independent review. See `.claude/hooks/warn-review-marker-write.sh` and `.claude/rules/pr-workflow.md` § "Build agents cannot self-review".

### 0a. Never hand the reviewer a marker path (me2resh/apexyard#1144)

**The spawn prompt for Hakim MUST NOT contain a literal marker path.** Say
*"write your approval marker on an APPROVED verdict"*. Say nothing about where.

Hakim already resolves the correct path through `review_marker_path`.
It uses the repo-qualified `<owner>__<repo>__<pr>-security.approved` form from AgDR-0060, which is the exact path the gates read.
A path in the prompt overrides that correct resolution.
The agent follows the supplied instruction and writes the bare-number `<pr>-security.approved` marker instead.
**No gate reads that path**. No on-disk marker lookup has a bare-number fallback.

This failure silently permits an apparent approval.
`ls .claude/session/reviews/` shows a file that looks valid to a human. Only the merge attempt reveals the failure.
Moving the file into place at that point is marker forging.
[`pr-workflow.md`](../../rules/pr-workflow.md) § "Build agents cannot self-review" prohibits that behaviour.
Always recover by deleting the gate-invisible file and repeating a real review.

`warn-unqualified-review-marker.sh` warns when a bare-number marker appears. Its warning is advisory and never blocks.
The merge gates identify the near-miss in their refusal message.
Prevent both problems: do not pass a path.

## Security Checklist

> Baseline: OWASP Top 10 (2025). Supply-chain failures are now #3. Use OWASP ASVS 5.0 as the verification baseline for these checks.

### Secrets & Credentials

- No hardcoded secrets, API keys, or passwords
- Environment variables for sensitive data
- No secrets in logs or error messages

### Injection Prevention

- Parameterised queries (no SQL injection)
- No command injection
- No template injection

### XSS Prevention

- User input sanitised before rendering
- No unsafe `dangerouslySetInnerHTML`
- No `eval()` with user input

### Authentication & Authorisation

- Auth checks on protected routes
- Authorisation verified before data access
- Secure session management

### Data Protection

- Sensitive data encrypted
- No PII in URLs or query strings
- Proper validation and sanitisation

### API Security

- Rate limiting considered
- Input validation on endpoints
- No stack traces exposed
- CORS configured correctly

## Severity Levels

Security levels describe risk separately from finding tags.
CRITICAL and HIGH findings introduced or worsened by the change are Important and retain their blocking actions.
Apply this exact security SLA contract:

```text
A Pre-existing security finding does not block the PR. It gets a ticket due on its first-seen date plus its SLA (`.security.remediation_sla_days`: CRITICAL 7 days, HIGH 30 days, MEDIUM 90 days, LOW no SLA). It blocks a release only after the SLA is breached. The review names the severity, the SLA and the due date. Tracking: me2resh/apexyard#2109.
```

| Level | Action |
|-------|--------|
| CRITICAL | Block PR immediately when the change introduced or worsened it |
| HIGH | Block PR, require fix, when the change introduced or worsened it |
| MEDIUM | Warn, recommend fix |
| LOW | Informational |

## Output

Give each finding exactly one tag: `Important`, `Nit`, or `Pre-existing`.
Only `Important` findings can cause `CHANGES REQUESTED` under the applicable blocking rules.
`Nit` and `Pre-existing` findings never block the PR.
Each `Pre-existing` finding includes base evidence and a suggested ticket title.
Follow [Review severity](../../../templates/REVIEW.md) and the agent's Output Format.
Keep all other security rules and independent gates in effect.

Posts a GitHub review with:

- Commit SHA
- Security checklist results
- Issues with severity
- Verdict

Invokes: Security Reviewer Agent (Hakim)

**Review body path (#1840, AgDR-0266).** Hakim writes the review body with the Write tool to the sanctioned body path, then posts that file with `tracker_review_submit <owner/repo> <pr> comment <body_file>`. The path is `<ops-root>/.claude/session/reviews/bodies/<owner>__<repo>__<pr>-security.md`. `review_body_path <owner/repo> <pr> security <ops-root>` in `_lib-review-markers.sh` prints it. Git ignores the folder. `limit-reviewer-writes.sh` lets a review agent write only in this folder. It blocks a reviewer Write to a repository file, a hook, a settings file or a review marker. Hakim does not write the body with a Bash heredoc, because the Bash gates read quoted command text in the body as commands.

## Persist the run + render trend

After the Security Reviewer agent posts the review, persist a structured artefact via the shared audit-history lib.
Post through the tracker-agnostic `tracker_review_submit` (gh PR / glab MR / custom host, #763), not a hardcoded `gh pr review`.
Persistence makes the security-review trend across PRs visible.
See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

### 1. Resolve project name + score + verdict

`<project-name>` is the project's registered name in `apexyard.projects.yaml`, derived from the PR's repo. If the registry does not contain the project, use the basename of the repo and tell the operator to `/handover` it for cross-machine trend continuity.

Compute a single headline score from the severity distribution of the findings in the review:

```
score = max(0, 100 - 25*critical - 10*high - 3*medium - 1*low)
```

Compute the audit-history verdict by the worst-severity rule.
This metric does not set the PR verdict. Apply the finding tags to the PR verdict.

| Worst severity present | Verdict |
|---|---|
| critical or high       | `fail` |
| medium only            | `conditional` |
| low only / none        | `pass` |

### 2. Build payload + body, persist via the lib

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-audit-history.sh"

# Lowercase severity in the payload: the lib's stats derivation expects
# critical / high / medium / low / info. The visible review on the PR
# can use whatever capitalisation reads best.
payload=$(mktemp); cat > "$payload" <<'EOF'
{
  "schema_version": 1,
  "findings": [
    {"id": "F1", "severity": "critical", "status": "open", "summary": "Unsanitised user input in SQL"},
    {"id": "F2", "severity": "high",     "status": "open", "summary": "JWT signature not verified"}
  ]
}
EOF

# Body: a markdown summary of the security review for this PR, formatted
# per templates/audits/security-review.md. Include the diff scope, findings
# table, dependency vulnerabilities, secrets-scan results, and recommendations.
body=$(mktemp); cat > "$body" <<'EOF'
## Scope

PR <number>; reviewed `<branch>..main` (X files, Y +/- lines).

## Findings

| # | Tag | Severity | OWASP class | Finding | File:Line | Status |
|---|---|---|---|---|---|---|
| F1 | Important | critical | A03 Injection | Unsanitised user input concatenated into SQL | `src/users.ts:42` | open |
| F2 | Important | high | A07 Auth failure | JWT signature not verified | `src/auth.ts:18` | open |

## Dependency vulnerabilities

(... output of `npm audit` or `pip audit` for critical+high ...)

## Secrets scan

(... checks per templates/audits/security-review.md ...)

## Recommendations

1. F1: fix injection vector before merge
2. F2: verify JWT signatures
EOF

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
audit_run_persist "<project-name>" "security-review" "$ts" "fail" 50 "$body" < "$payload"
rm -f "$payload" "$body"
```

### 3. Render the trend section

```bash
audit_render_trend "<project-name>" "security-review" 5
```

- < 2 prior runs → silent (no trend section). Do not append anything.
- ≥ 2 prior runs → prints a markdown trend block (heading + table + ASCII chart of `score` over time) to stdout. Append it to this run's MD artefact so the PR-by-PR security trend is visible.

### 4. Opt-in commit (history-tracked marker)

By default, Git ignores the dimension's runs/ JSON files. The lib applies a `.gitignore` based on the presence of the marker:

```bash
# Opt in to commit security-review history for this project
touch projects/<name>/audits/security-review/.audit-history-tracked
```

Commit the MD artefacts at `<dim_dir>/<ts>.md` regardless. They provide a durable human-readable record of every PR's security review.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*


### SLA tracker handoff

The tracker issue is the record. Its creation date is the first-seen date.
A fingerprint identifies the same finding across reviews.
Use `.claude/hooks/_lib-sla.sh` to compute fingerprints:

```bash
source .claude/hooks/_lib-sla.sh
sla_fingerprint dependency '<package>' '<advisory ID>'
sla_fingerprint code '<rule>' '<repository-relative file>' '<function>'
```

Use exact scanner identifiers and case. Exclude versions, line numbers, and PR identifiers.
Use repository-relative paths without `./`. Use `<module>` for code outside a function.
The helper hashes a compact JSON array with SHA-256.

1. Reproduce each finding on the PR base commit.
2. Record the base SHA, path, and matching advisory or code evidence.
3. Without base proof, treat the finding as new and block the PR.
4. Include `Fingerprint: <fp>` and `Base proof: <short evidence>` on each Pre-existing line.
5. Search with `sla_find_open <repo> <fp>`.
6. On a match, report `tracked in #N, due YYYY-MM-DD` from the issue.
7. Preserve the issue's severity, SLA, first-seen date, and due date.
8. On no match, hand the fingerprint, severity, title, and proof to the orchestrator.

Only the orchestrator calls `sla_track <repo> <fp> <severity> <title> <base-proof>`.
Hakim and the PR author never file the SLA issue.
The orchestrator serializes calls per repository and returns the issue reference before the final review.
Never retry a failed create automatically. Search the tracker and reconcile the result first.
A pending due date indicates incomplete creation. Finalize that issue from its creation date without creating another issue.
Tracker errors leave the handoff unresolved. Do not report a successful search or completed tracking.
LOW records use `SLA days: none` and `Due: none`.

Write CRITICAL, HIGH, and MEDIUM findings on one line:

```text
- Pre-existing: <finding>. Suggested ticket title: <title>. Severity: HIGH. SLA: 30 days. Due: YYYY-MM-DD. Fingerprint: <fp> | Base proof: <base SHA, path, matching evidence> | tracked in #N, due YYYY-MM-DD
```

Run `check-review-body.sh --security` before submitting the review.
The validator checks fields. Hakim must verify that the base evidence supports the classification.
An overdue proven finding remains Pre-existing. The release check enforces its deadline.
