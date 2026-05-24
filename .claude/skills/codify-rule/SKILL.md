---
name: codify-rule
description: Turn a review comment that caught a Rex-miss into a draft handbook entry — Y/N gate, source-PR footer, bucket-routed.
argument-hint: "[--pr <N>] [--blocking] [<github-pr-comment-url>]"
allowed-tools: Bash, Read, Write
---

# /codify-rule — Codify a Rex-Miss Into a Handbook Entry

When a human reviewer (or Copilot, or any second-pass review) catches a bug Rex missed, run `/codify-rule` to turn that review comment into a draft handbook entry. The handbook layer then **compounds on Rex's actual misses** rather than only the rules an operator thought to write proactively.

The skill is **operator-curated, not auto-promoted**: every captured rule is previewed in full and gated on a Y/N approval before any file is written. The output file includes a `_Source:_` footer naming the PR + comment author + date so future readers can find the original miss this rule came from.

## Path resolution

This skill writes to the `handbooks/` tree (or `<private_repo>/custom-handbooks/` for split-portfolio adopters). Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
public_handbooks_root="$(_portfolio_root)/handbooks"
private_handbooks_root=$(portfolio_custom_handbooks_dir)
```

`portfolio_custom_handbooks_dir` returns `<ops_root>/custom-handbooks` by default for single-fork adopters; split-portfolio v2 adopters resolve to `<private_repo>/custom-handbooks` via the `portfolio.custom_handbooks_dir` config key. See `docs/multi-project.md` § "Private custom skills + handbooks".

## Usage

```
/codify-rule
/codify-rule --pr 296
/codify-rule https://github.com/me2resh/apexyard/pull/296#discussion_r123456789
/codify-rule --blocking
/codify-rule --pr 296 --blocking
```

## Process

### 1. Resolve the source PR

Three input paths, tried in order:

1. **Full GitHub PR-comment URL** in `$ARGUMENTS` (e.g. `https://github.com/me2resh/apexyard/pull/296#discussion_r123456789`) — parse the owner/repo, PR number, and comment ID; fetch the comment body via `gh api`.
2. **`--pr <N>`** in `$ARGUMENTS` — use that PR number; resolve owner/repo from the current git remote (`gh repo view --json nameWithOwner`).
3. **Otherwise** — find the open PR for the current branch via `gh pr view --json number,headRefName,headRepository`. If no open PR, ask:

   ```
   No open PR for the current branch and no --pr <N> given. Which PR
   should I codify a rule from? (pass --pr <N> or a full comment URL)
   ```

Capture three values for use downstream:

- `pr_number` — the PR this rule comes from
- `pr_owner_repo` — `owner/repo`
- `comment_url` — the canonical comment URL (or just the PR URL if a freeform comment was given)

### 2. Get the review-comment text

If a comment URL was passed in step 1, fetch the body via `gh api repos/<owner>/<repo>/pulls/comments/<comment-id>` (or `repos/.../issues/comments/<id>` for issue-comment shape — try both) and capture the `body` + `user.login` + `created_at` fields.

Otherwise, ask the operator to paste it:

```
Paste the review-comment text — the exact prose the human (or Copilot)
used to flag the miss. End with a blank line and Ctrl-D, or paste
inline:
```

Also ask for the comment author + date if the URL fetch wasn't possible:

```
Who left this comment? (GitHub username, e.g. @copilot, @alice)
What date? (YYYY-MM-DD, default: today)
```

### 3. Get the file:line context

Many review comments include the file:line they fired on (GitHub PR comments do; pasted prose may not). Try to extract it from the comment body via regex (`<path>:<lineno>` or GitHub-style `<path>#L<lineno>`). If not parseable, ask:

```
Which file did this fire on? Give me the path relative to the repo
root (e.g. scripts/github-emu-migration/migrate-org.ts) and the line
number if you have it. If the rule is path-independent, type `none`.
```

Capture two values:

- `file_path` — e.g. `scripts/github-emu-migration/migrate-org.ts`, or `none`
- `line_number` — e.g. `42`, or empty

### 4. Pick the handbook bucket

Show the four options and ask one question:

```
Which handbook bucket does this rule belong in?

  1. domain         — review knowledge about a specific problem domain
                      (GitHub EMU, Stripe webhooks, SAML claims, etc.)
                      Loads on PR-diff match via opt-in `paths:` frontmatter.

  2. architecture   — layering, dependency direction, design patterns.
                      Loads on every PR.

  3. general        — cross-cutting team-communication rules (commit
                      messages, comment density, naming).
                      Loads on every PR.

  4. language       — language-specific (TS strict-mode, Python type
                      hints, Go error shapes, etc.).
                      Loads when the PR diff touches that language.

Pick 1-4 (or type a hint like "domain" / "ts strict mode").
```

**Routing prompts per bucket:**

- **domain** → ask for the area slug:

  ```
  Domain area slug? Use kebab-case (e.g. `github-emu`, `stripe-webhooks`,
  `tenant-isolation`).
  ```

  Capture `area_slug`. Also propose a default `paths:` glob from the
  file_path's directory (e.g. file `scripts/github-emu-migration/migrate-org.ts`
  → propose `scripts/github-emu-migration/**`). Confirm with the operator:

  ```
  I'll pre-populate the `paths:` frontmatter with:
    - "scripts/github-emu-migration/**"
  Refine the globs (one per line, blank line to confirm), or press Enter
  to accept.
  ```

  If `file_path` was `none`, propose no `paths:` field (foundational
  always-load domain rule) and confirm.

- **architecture** → no extra prompts; write to `handbooks/architecture/<rule-slug>.md`.

- **general** → no extra prompts; write to `handbooks/general/<rule-slug>.md`.

- **language** → ask for the language slug:

  ```
  Language slug? Use the directory convention (`typescript`, `python`,
  `go`, `rust`, etc.). One word, lowercase.
  ```

  Capture `lang_slug`. Write to `handbooks/language/<lang>/<rule-slug>.md`.

### 5. Generate a rule slug + title

Ask the operator for both:

```
Short title for this handbook entry?
(e.g. "GitHub EMU private-fork access", "Stripe webhook signature
verification", "no console.log in production code")
```

Auto-generate the file slug from the title (lowercase, kebab-case, max
50 chars, trim stopwords). Show it for confirmation:

```
File slug: github-emu-private-fork-access.md
File path: handbooks/domain/github-emu/github-emu-private-fork-access.md
Adjust the slug, or press Enter to accept:
```

### 6. Draft the handbook entry — interactive section fill

The skill's job here is **to scaffold**, not to author. For each of the
five sections, prompt the operator with a leading question. Pre-fill
with what can be inferred from the review-comment text (the body is
usually rich enough to seed at least "The rule" and "Why").

Section-by-section prompts:

**a) The rule**

```
"The rule" — the concrete, actionable statement. Often a paraphrase of
the review comment itself. Aim for 1-3 lines.

Seed from the comment:
> {first 200 chars of comment body}

Type the rule, or press Enter to use the seed as-is:
```

**b) Why**

```
"Why" — the failure mode if this rule is ignored. What would have gone
wrong if Rex hadn't (or hadn't been told to) catch this?
```

**c) What Rex flags**

```
"What Rex flags" — the concrete patterns Rex looks for in the diff.
Be specific about file paths, code patterns, signal phrases. Vague
rules generate vague findings.

Seed from the file:line context:
> file: {file_path}{:line if present}

Type Rex's detection pattern (bullets are fine):
```

**d) Sample finding**

```
"Sample finding" — how Rex should phrase the finding in a review
comment. Format-by-example. Can be a paraphrase of the original
human-review comment.

Seed:
> {one-line version of the comment body}

Type the sample finding, or press Enter to use the seed:
```

**e) What's NOT a violation**

```
"What's NOT a violation" — the false-positive list. As load-bearing as
the rule itself. What should Rex SKIP that looks similar?
```

### 7. Assemble the full draft + preview

Build the full file content. The shape depends on the bucket:

**For domain handbooks (with `paths:` frontmatter):**

```markdown
---
paths:
  - "<glob 1>"
  - "<glob 2>"
---

{ENFORCEMENT_LINE}# Handbook: {Title}

**Scope:** PRs touching the {area_slug} domain.
**Enforcement:** {advisory|blocking}

## The rule

{rule text}

## Why

{why text}

## What Rex flags

{detection patterns}

## Sample finding

{sample finding text}

## What's NOT a violation

{false-positive list}

---

_Source: PR #{pr_number} comment by @{comment_author} on {comment_date}_
_See: {comment_url}_
```

**For domain handbooks without `paths:`** (foundational always-load):

```markdown
---
# no paths: field → always load
---

{ENFORCEMENT_LINE}# Handbook: {Title}

...
```

**For architecture / general / language** (no frontmatter — per the convention in `handbooks/README.md`):

```markdown
{ENFORCEMENT_LINE}# Handbook: {Title}

**Scope:** {derived from the bucket — e.g. "all PRs" for architecture/general; "PRs touching <lang> files" for language}.
**Enforcement:** {advisory|blocking}

## The rule
...
```

Where `{ENFORCEMENT_LINE}` is:

- empty string when the default `--blocking` flag was NOT passed (advisory is the default), OR
- the literal line `ENFORCEMENT: blocking\n\n` prepended to the file body (after the frontmatter block, before the H1) when `--blocking` was passed.

### 8. Show the full draft for approval (MANDATORY GATE)

Print the full file content to the operator with the resolved path, then ask:

```
Draft handbook entry:
---
{full file content}
---

Path: {resolved_handbook_path}
Bucket: {bucket}
Enforcement: {advisory|blocking}

Write this file? (yes / edit / no)
```

**Handle response:**

- **yes / looks good / go / Y** → proceed to step 9
- **edit / change X** → ask what to change (rule text, sample finding, paths globs, etc.); update the in-memory draft; re-show the full file; re-ask
- **no / cancel / abort** → abort with no file written:

  ```
  Cancelled. No handbook entry was written.
  ```

**No file is written until the operator explicitly says yes.** This is the load-bearing rule of the skill — auto-promotion would create handbook clutter and tune adopters out.

### 9. Resolve the write target — public vs private layer

If `portfolio_custom_handbooks_dir` resolves to a directory that exists AND is different from `<ops_root>/custom-handbooks` (i.e. the adopter has a split-portfolio private layer set up), offer the operator the choice:

```
A private custom-handbooks layer is configured at:
  {private_handbooks_root}

Where should this handbook entry land?
  1. Public — handbooks/{bucket}/{...}/{slug}.md (default; visible on the public fork)
  2. Private — {private_handbooks_root}/{bucket}/{...}/{slug}.md (split-portfolio private layer)

Pick 1 or 2 (Enter = public):
```

For single-fork adopters (no private layer), default to public with no prompt.

For domain handbooks, the path is `{root}/domain/{area_slug}/{slug}.md`.
For language handbooks, the path is `{root}/language/{lang_slug}/{slug}.md`.
For architecture / general handbooks, the path is `{root}/{bucket}/{slug}.md`.

### 10. Handle re-runs on existing slugs

If the target file already exists, offer three paths:

```
{resolved_handbook_path} already exists. What should I do?
  1. Append this as a new entry below the existing content (recommended
     if this is a different miss in the same area)
  2. Overwrite the existing file (destructive — only if this entry
     supersedes the old one)
  3. Cancel

Pick 1, 2, or 3:
```

For **append**: write a `\n\n---\n\n` separator + the new content (frontmatter is not duplicated; for domain handbooks, merge the `paths:` globs by union and dedupe).

For **overwrite**: simply replace the file.

For **cancel**: exit without writing.

### 11. Write the file

```bash
mkdir -p "$(dirname "$resolved_handbook_path")"
printf "%s" "$file_content" > "$resolved_handbook_path"
```

### 12. Return

Print a single block summarising the capture:

```
Handbook entry codified:

  Path:        {resolved_handbook_path}
  Bucket:      {bucket}
  Enforcement: {advisory|blocking}
  Source:      {pr_owner_repo}#{pr_number}, comment by @{comment_author} on {comment_date}

Rex will pick up this rule on the next PR review.

Next steps:
  1. Stage the file:   git add {resolved_handbook_path}
  2. Commit:           git commit -m "docs(#{pr_number}): handbook on {short-title}"
  3. Push + PR — the handbook entry is durable from the next review onwards.
```

## Rules

1. **Operator-approval gate is mandatory.** No file is written until the operator says yes in step 8. The skill is operator-curated, not auto-promoted.
2. **Source attribution is required.** Every entry ends with the `_Source: PR #N comment by @author on YYYY-MM-DD_` footer. Future readers should always be able to find the original miss this rule came from. This is the audit trail for "where did this rule come from?".
3. **`paths:` frontmatter is domain-only.** Other buckets stay frontmatter-free per `handbooks/README.md` § "File format" and the project's no-frontmatter convention. Adding frontmatter to architecture / general / language handbooks would silently disable Rex's load condition for those buckets.
4. **Default advisory; opt in to blocking.** The `--blocking` flag prepends the literal `ENFORCEMENT: blocking` marker. Pick blocking sparingly — a handbook that day-1 blocks every PR generates revolts and gets removed.
5. **One miss per invocation.** v1 captures one rule from one comment. Multi-handbook bulk capture from a single review is out of scope (file separate `/codify-rule` invocations).
6. **No mining of historical PRs.** That's Stage 3 (`/enrich-domain`) — a separate future ticket.

## Edge cases

- **The comment text is too vague to author a rule from.** Push back conversationally: "this comment doesn't seem specific enough to encode as a Rex pattern. Can you point me at a specific file:line, or paraphrase the rule as a single sentence?" If the operator can't, abort cleanly — better no handbook than a vague one that generates noise.
- **The miss is actually covered by an existing framework rule.** When generating the draft, scan `.claude/rules/*.md` for keyword matches (auth, secrets, AgDR, ticket-vocab). If a likely framework rule already covers this concern, surface it: "this looks similar to `.claude/rules/<file>.md`. Capture as a handbook anyway (more specific), or amend the framework rule?". Default to capturing the handbook.
- **The PR is on a private project that the operator doesn't want named upstream.** The skill writes to local files only — it doesn't post anywhere. The `_Source: PR #N_` footer names the PR number, not the project name; safe to ship even for split-portfolio adopters as long as the destination is the private layer.
- **The comment was left by a bot (Copilot, dependabot, semgrep-bot).** Treat bot comments the same as human comments — they're often the most useful signal. The `_Source:_` footer names the bot's GitHub login so future readers see the provenance.

## Out of scope (v1)

- **Automatic discovery** of "Rex-miss" candidates across recent merged PRs. That's `/enrich-domain` (Stage 3 of #293).
- **Cross-project rule propagation.** A handbook entry written in project A doesn't automatically apply to project B. The handbook layer is framework-level (per `handbooks/README.md` § "Out of scope (v1)"); revisit if multi-project adopters explicitly ask.
- **Conflict resolution** between the new entry and an existing rule in the same bucket. The skill appends or overwrites on the operator's say-so; semantic merging is out of scope.
- **Hooks that auto-run `/codify-rule`** on PR close. Operator-invoked only — auto-running would defeat the curation gate that's the whole point of the skill.
- **Multi-bucket capture** of one comment across, e.g. an architecture + domain pair. v1 picks one bucket per invocation.

## Why this exists

Stage 1 of #293 (PR #294, AgDR-0037) shipped the domain-handbooks bucket and the path-glob discovery foundation. That gives Rex a *place* to learn domain-specific review patterns — but the handbook layer only compounds if there's a cheap path from "Rex missed something a human caught" to "the next review benefits from that miss".

Without `/codify-rule`, the handbook layer stays at "rules an operator thought to write up-front" — a static slice. With it, the layer becomes a **learning surface** that compounds with every Rex-miss the operator chooses to codify.

Industry harness-engineering articulates this as the **steering loop**: "whenever an issue happens multiple times, the feedforward and feedback controls should be improved". `/codify-rule` is the operator-side hook into that loop. Stage 3 (`/enrich-domain`) automates the discovery side; this skill (Stage 2) handles the capture side. The two together close the loop.

See AgDR-0040 for the design rationale and trade-offs.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
