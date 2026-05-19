# Rex domain handbooks — path-glob frontmatter

> In the context of Rex reviewing PRs against domain-specific codebases (e.g. GitHub EMU migration scripts, Stripe webhook handlers, SSO SAML integrations), facing the failure mode that Rex's review is grounded only in code + ticket + framework rules + adopter handbooks — and the existing handbook buckets (`architecture/`, `general/`, `language/`) don't fit domain rules cleanly — I decided to add a fourth bucket `handbooks/domain/<area>/` with opt-in `paths:` frontmatter to scope handbooks to PRs that touch the domain's code, to achieve domain-aware reviews that catch gotchas the surrounding context wouldn't surface, accepting that frontmatter introduces a (small) new parser surface in Rex's prompt.

## Context

### The failure mode

The Code Reviewer agent (Rex) reviews PRs using four sources of context: the code diff, the PR description, the linked ticket, and the adopter handbooks at `handbooks/{architecture,general,language/<lang>}/`. None of those sources includes **domain knowledge of the specific component the diff touches**.

Concrete example flagged by the operator (2026-05-19): Rex was reviewing a GitHub EMU (Enterprise Managed Users) migration script and missed several gotchas that GitHub Copilot caught later in the same review cycle. Specifically: EMU enterprises cannot access private forks of public repos via the user's source org, and the migration script needed a branch for that case. Nothing in the diff or the framework rules surfaced this — it's pure domain knowledge that you only learn by shipping EMU migrations.

The same shape recurs across domains the framework has no a-priori knowledge of: Stripe webhook signature verification (`Stripe-Signature` header + raw body), SAML claim shapes, tenant-isolation invariants in multi-tenant codebases, payment-reconciliation idempotency rules, etc.

### What we already have

The framework ships three handbook buckets, each with a fixed load condition:

| Bucket | Load condition |
|---|---|
| `handbooks/architecture/*.md` | Always (every PR) |
| `handbooks/general/*.md` | Always (every PR) |
| `handbooks/language/<lang>/*.md` | On file-extension match (PR touches `*.ts` → load `language/typescript/`) |

These work because they answer **how is the code structured / written / communicated** — questions whose load condition is naturally tied to the path-convention.

Domain rules don't have a clean extension-based trigger. EMU rules apply to whatever files implement EMU; Stripe-webhook rules apply to whatever files validate Stripe events. The directory name `domain/<area>/` says "this is about <area>", but the agent still needs to know *which files belong to <area>* in order to decide whether to load the handbook on a given PR.

### What we're not trying to solve

- Auto-fetching authoritative external docs at review time (GitHub's own EMU documentation, Stripe's API reference). Tempting for freshness but introduces a non-reproducibility surface in CI-class agents — review verdicts can swing based on what the fetched page contained that minute. Deferred unless an adopter explicitly asks.
- Programmatic enrichment of handbooks from recent PR streams. That's Stage 3 of the feature ticket — useful, but only after the path-glob discovery is proven.
- Per-team or per-project handbook overrides. Still deferred per `handbooks/README.md` § "Out of scope (v1)".

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| **A. Frontmatter `paths:` field on each handbook** (chosen) | Per-file granularity (foundational always-load handbooks AND path-triggered ones coexist in the same area dir); discovery stays path-mirroring (`<area>/` IS the targeting metadata at the directory level); the trigger is co-located with the rule, so authors maintain one file not two; consistent with how Claude Code skills already use frontmatter | Introduces a small YAML-parser surface in Rex's prompt (the other buckets are frontmatter-free); the `paths:` semantics are domain-bucket-specific and need to be documented separately |
| **B. Sidecar `paths.txt` per area dir** | No frontmatter parser; one path-list per area covers all handbooks under it | Loses per-handbook granularity (a foundational always-load rule and a path-scoped rule in the same area can't coexist); two files to keep in sync; less consistent with the rest of the framework's frontmatter-on-things-that-have-load-conditions convention |
| **C. Config table in `.claude/project-config.json`** | Centralised — operators see all path-mappings in one place | Distance between the rule (handbook file) and its load condition (config file) makes drift inevitable; adopters who edit the handbook frequently have to remember to update the config; doesn't fit the path-mirroring discovery convention used elsewhere |
| **D. Hard-code area→paths mapping in Rex's prompt** | Zero config — Rex "knows" `github-emu/` means `scripts/github-emu-migration/**` | Framework-side maintenance for every adopter's domains; defeats the point of adopter handbooks (the framework cannot know which paths a given adopter's domain lives at) |

## Decision

Chosen: **Option A — frontmatter `paths:` field on each handbook in `handbooks/domain/<area>/`**, because:

1. The trigger lives next to the rule. Future-readers see "this handbook fires when the diff matches X" without consulting a second file. Drift is bounded by the author's normal editing flow.
2. Per-handbook granularity. An area like `github-emu/` can have both a foundational always-load handbook (no `paths:` field → loads every PR) and a narrow path-scoped handbook (`paths: ['src/auth/emu/**']` → loads only when relevant). Option B can't express this without splitting into multiple sibling dirs.
3. Frontmatter is a single ~5-line block at the top of a 50-line file. The parser surface is small, the syntax is YAML (which the agent's Bash environment already handles via `python3 -c 'import yaml; ...'` or `awk`), and the convention is familiar to anyone who's read a static-site post.
4. Opt-in default. Handbooks without a `paths:` field load on every PR — same behaviour as the always-load buckets. So an adopter who writes a domain handbook without thinking about `paths:` gets sensible behaviour by accident.

## Consequences

### Positive

- Rex can now load domain-specific review notes scoped to PRs that touch the domain. The framework gains a fourth handbook bucket with no breaking change to the other three.
- Adopters extend Rex's domain awareness by writing a markdown file — same friction as the existing handbook buckets, no code changes required.
- The custom-handbooks layer (split-portfolio adopters at `<private>/custom-handbooks/domain/<area>/`) gets the same convention with no separate wiring.

### Negative

- Rex's prompt grows by ~15 lines covering the frontmatter parse + path-match step. This is a small but real per-review token cost.
- Domain handbooks introduce a fourth shape (frontmatter + body) alongside the three frontmatter-free buckets. New authors need to learn this is the only bucket with frontmatter. Mitigated by `handbooks/domain/README.md` calling it out explicitly.
- If an adopter's `paths:` globs are malformed (unterminated frontmatter, unparseable YAML, invalid glob syntax), Rex degrades to **always-load with a visible `⚠` warning** in the review output, not silent skip. The asymmetry is deliberate: over-loading visibly is recoverable (the operator sees the warning and fixes the YAML); under-loading silently is not (the handbook never fires and the operator never learns). The matcher's frontmatter-parse path applies this default at every degraded branch — missing `paths:` key, empty `paths: []`, unterminated frontmatter, no frontmatter at all — all fall through to `return True`. The one exception is `OSError` on `open()` (the candidate file vanished between the bash existence check and the Python read — a race condition), which returns `False`: treating the missing file as absent from the candidate list is more honest than pretending we loaded a handbook we couldn't actually read.

### Matcher invocation shape — batched, not per-handbook

The matcher is invoked **once per review** with all candidate handbooks passed as argv, not once per handbook. The naive shape (`for hb in handbooks; python3 match.py "$hb"; done`) would make the per-review Bash count grow O(N) in handbook count — and in sandboxed environments every `python3 ...` invocation surfaces a permission prompt. The batched shape keeps the count constant: one `python3 /tmp/match_handbooks.py "${HBS[@]}" < diff` regardless of how many handbooks the adopter has registered. The Python script reads handbook paths from `sys.argv[1:]` and the diff from `sys.stdin`, then prints loadable paths to stdout. The bash loop simply pipes that stdout into the same load path as the architecture/general/language buckets.

### Future work (tracked in the same feature ticket #293)

- **Stage 2: `/codify-rule` skill.** Turn a human review comment that caught a Rex-miss into a handbook entry. Operator approves Y/N per finding. The captured rule includes the source PR for traceability — so future readers see *why* this rule exists.
- **Stage 3: `/enrich-domain <area>` skill.** Walk recent merged PRs that touched the area; propose handbook additions Rex would have benefited from (new error messages, conditional branches, AgDR references). Operator-approved per finding.

Both stages are tracked in #293's ACs but implemented as separate follow-up tickets. Stage 1 (this AgDR) is the foundation that the enrichment skills layer on top of.

## Artifacts

- `handbooks/domain/README.md` — operator-facing convention doc
- `handbooks/README.md` — updated to mention the new bucket
- `.claude/agents/code-reviewer.md` § 8 — Rex's prompt with the fourth bucket + frontmatter-parse + path-match step
- PR me2resh/apexyard#294 — implementation
- Ticket me2resh/apexyard#293 — feature spec with the three-stage plan
