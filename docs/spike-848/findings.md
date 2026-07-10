# Spike #848 — Is credentialed multi-runtime conformance CI automatable non-interactively?

> **Spike ticket:** [me2resh/apexyard#848](https://github.com/me2resh/apexyard/issues/848)
> **Type:** Throwaway spike — this document is the ANSWER, not shippable code. No live `.github/workflows/*.yml` is added; the workflow below is a DRAFT proposal.
> **Method:** Read-only investigation of the four shipped adapters + the harness docs + the recorded 2026-07-09 manual-proof preconditions. Per the ticket's constraint, no third-party agent CLI was executed here; the verdicts are reasoned from the adapters' event contracts and the recorded live-proof runs.

---

## The headline answer

**3-green-continuous + Cursor documented-manual.** Not 4-green.

- **opencode, pi, Codex** can each — in principle — be driven through a real credentialed agent turn **headlessly in CI**, with the delegated bash gate (`block-git-add-all.sh`) firing its own verbatim block and nothing staged. All three cleared the same bar manually on 2026-07-09; nothing in their auth or trust model requires a human once the CI job is wired.
- **Cursor is out** as a green-continuous conformance target, for a decisive reason rather than a missing flag: its `cursor-agent` **CLI ignores `hooks.json` entirely** (recorded: zero hook fires while a benign command ran clean), and its only observed enforcement path is the **IDE** (a GUI, no headless runner) where the block came from **`failClosed`** — the hook-runner erroring, not the gate's logic evaluating (`MainThreadShellExec not initialized`). A failClosed deny is explicitly **not** a conformance proof (the ticket's own Glossary). So Cursor stays **documented-manual**.

"4-green achievable" would require Cursor, and Cursor has no headless path that runs the delegated gate. Therefore the honest, GTM-usable claim is **continuous CI conformance on the automatable subset {opencode, pi, Codex}, with Cursor documented as manual/failClosed-only.**

**Load-bearing caveat:** this spike returns a *feasibility* verdict, not an executed CI run. The three manual proofs happened on a developer machine. The FINAL proof — a green scheduled CI job per harness — needs a credentialed run the **operator triggers**, because it requires repository secrets (a model API key for pi and Codex) and network egress from the runner to the model providers. That last mile is exactly what the PROMOTE feature would build and prove; see [Disposition](#disposition--promote).

---

## Per-harness feasibility

Each harness is scored on the ticket's three axes: (1) headless auth in CI, (2) trust/approval precondition satisfiable non-interactively, (3) clean-proof observability (the gate's OWN output fires, not a harness self-block or a failClosed error).

### opencode — GREEN (and the cheapest to run)

| Axis | Finding | Source |
|------|---------|--------|
| **1. Headless auth** | **No secret required.** opencode ships a free, no-API-key model (`opencode/big-pickle`); spike #816's live proof drove a real model turn against it with an empty credential env. CI can therefore run opencode conformance with **zero secrets and no paid-API egress** — the ideal always-on canary. (An API key can be supplied to pin a specific model, but it is optional.) | `docs/agdr/AgDR-0092`, `docs/opencode-adapter.md` |
| **2. Trust precondition** | `--auto` — a plain CLI flag (`opencode run --auto …`). Non-interactive by construction; it's what let the manual proof's `git add -A` reach `tool.execute.before`. | `docs/harnesses/opencode.md` § Preconditions |
| **3. Clean-proof observability** | Imperative plugin API: the gate runs **inside** opencode's `tool.execute.before` during the real turn and throws-to-deny on the hook's exit 2. The delegated `block-git-add-all.sh` runs unmodified → its verbatim message + nothing staged. Live-proven once (against the #816 prototype; the shipped settings.json-derived dispatcher was not re-run only because that build lacked credentials — CI supplies them). | `docs/harnesses/opencode.md` § What's verified |

**Verdict:** fully automatable, likely **secret-free**. This is the "smallest test" first harness the ticket asks for — wire it end-to-end, then generalise the shape.

### pi (pi.dev) — GREEN (needs a model-key secret + egress)

| Axis | Finding | Source |
|------|---------|--------|
| **1. Headless auth** | Requires a **live model API key** — the #804 spike explicitly could not run the final hop because the sandbox had no `ANTHROPIC_API_KEY`. Auth is non-interactive and documented: `pi -p -a --provider anthropic --model <m> --api-key $KEY …` (flags exist; the spike loaded the extension this way past extension-load into a live auth call). In CI: a GitHub secret + egress to the provider. | `docs/spike-reports/pi-gate-extension.md` |
| **2. Trust precondition** | `-a` / `--approve` — CLI flag granting project trust so the tool call reaches the dispatcher's `tool_call` handler. Non-interactive. The manual proof ran under `pi -p -a`. | `docs/harnesses/pi.md` § Preconditions |
| **3. Clean-proof observability** | Imperative extension API: the gate runs inside pi's `tool_call` event and returns `{block:true, reason}` on the hook's exit 2. Delegated unmodified bash → clean block. Live-proven 2026-07-09. | `docs/harnesses/pi.md` § What's verified |

**Verdict:** automatable; the only human-free requirement is provisioning the model-key secret once. Because it bills a real API per run, schedule it (nightly) rather than per-PR.

### Codex — GREEN (needs OPENAI_API_KEY + trust flag + egress)

| Axis | Finding | Source |
|------|---------|--------|
| **1. Headless auth** | Two auth paths. ChatGPT-account OAuth (device/browser) is **not** headless-friendly. The **`OPENAI_API_KEY` / `codex login --api-key`** path **is** non-interactive and is the CI path. **Caveat:** the manual proof used `-m gpt-5.5`, documented as "the real ChatGPT-account default"; an API-key CI run bills API-tier models and may resolve a different concrete model than the subscription default — a conformance proof of the *gate*, not necessarily of the exact model tier the mapping targets. | `docs/harnesses/codex.md`, `.claude/harness-models.json` |
| **2. Trust precondition** | Hook-trust, with two non-interactive options: `--dangerously-bypass-hook-trust` (headless one-off — exactly how the manual proof ran) **or** seed a user-level `~/.codex/hooks.json` (trusted by default) in the runner. Both are scriptable. | `docs/harnesses/codex.md` § Preconditions |
| **3. Clean-proof observability** | Declarative-generate: `.codex/hooks.json` execs the unmodified `.claude/hooks/*.sh`. Manual proof: `codex exec … -m gpt-5.5` issued `git add -A`, `block-git-add-all.sh` fired — clean exit 2, verbatim output, nothing staged. Live-proven 2026-07-09. | `docs/harnesses/codex.md` § What's verified |

**Verdict:** automatable; needs the `OPENAI_API_KEY` secret + the trust flag baked into the job. Same nightly-schedule + egress posture as pi.

### Cursor — OUT (documented-manual)

| Axis | Finding | Source |
|------|---------|--------|
| **1. Headless auth** | Moot — there is no headless path that runs the gate. The `cursor-agent` **CLI does not read `hooks.json` at all** (instrumented: zero fires while a benign command executed cleanly); it enforces via its own `~/.cursor/cli-config.json` permissions model, a surface the adapter doesn't address. | `docs/harnesses/cursor.md` |
| **2. Trust precondition** | Enforcement exists only in the **Cursor IDE** (a GUI — no CI runner), and only from **user-level** `~/.cursor/hooks.json`. A project `.cursor/hooks.json` showed `Configured Hooks (0)`. | `docs/harnesses/cursor.md` |
| **3. Clean-proof observability** | Even in the IDE, the observed block was **`failClosed`** — the delegated hook's own instrumentation never fired and the agent reported `MainThreadShellExec not initialized`; the deny came from the rule-runner erroring, not the gate evaluating and returning exit 2. By the ticket's Glossary, failClosed is **not** a clean proof. | `docs/harnesses/cursor.md` § What's enforced |

**Verdict:** cannot be made a green-continuous conformance target. Document it as manual/failClosed-only — the honest support-tier input the ticket's Disposition anticipates.

---

## What "run one gated turn and assert" looks like (the reusable shape)

The gate under test is `block-git-add-all.sh`: it reads `{"tool_input":{"command":…}}` on stdin and exits `2` with a verbatim message when the command matches `git add -A|--all|.`. The adapters reconstruct that stdin from the harness's own tool-call event, so a real model turn that runs `git add -A` triggers it.

Three assertions make a clean proof, and **the side-effect assertion is the load-bearing one** because a model turn is non-deterministic:

1. **Nothing staged** — `git diff --cached --name-only` is empty after the turn. This is the signal that the gate actually blocked, independent of how the model phrased things.
2. **Verbatim hook output present** — the run log contains `block-git-add-all.sh`'s own `BLOCKED: 'git add -A' … are forbidden.` text (distinguishes a delegated block from a harness self-block or a failClosed error).
3. **A dirty tree existed to stage** — the job first creates a scratch file so there is something `git add -A` *would* have staged; otherwise "nothing staged" is vacuously true.

Determinism note: pin the instruction hard ("run exactly `git add -A`") and, if a harness supports it, prefer a mode that surfaces the tool call. Even so, assert on the gate's side effect (1) + its own output (2), never on the model's compliance — that's what keeps the check from flaking on model phrasing.

---

## Recommended CI shape (DRAFT — proposal, not shipped)

A matrix workflow, one job per automatable harness, sharing one assert step. opencode runs secret-free on every push (cheap canary); pi and Codex are secret-gated and scheduled (they bill an API and need egress).

```yaml
# DRAFT — proposed by spike #848. NOT added as a live workflow in this spike.
# The PROMOTE feature would land this (or a refinement) as .github/workflows/conformance.yml.
name: harness-conformance

on:
  schedule:
    - cron: "0 6 * * *"      # nightly — pi/Codex bill an API, so not per-PR
  push:
    branches: [dev]           # opencode job is free; safe to run per-push
  workflow_dispatch: {}       # operator-triggered credentialed run

jobs:
  conformance:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        harness: [opencode, pi, codex]
    steps:
      - uses: actions/checkout@v4

      # --- secret-gate: skip (don't fail) pi/codex when creds are absent ---
      - name: Resolve credentials
        id: creds
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
          PI_MODEL_KEY:   ${{ secrets.PI_MODEL_KEY }}
        run: |
          case "${{ matrix.harness }}" in
            opencode) echo "ready=true"  >> "$GITHUB_OUTPUT" ;;   # free model, no secret
            pi)       [ -n "$PI_MODEL_KEY" ] && echo "ready=true" >> "$GITHUB_OUTPUT" || echo "ready=false" >> "$GITHUB_OUTPUT" ;;
            codex)    [ -n "$OPENAI_API_KEY" ] && echo "ready=true" >> "$GITHUB_OUTPUT" || echo "ready=false" >> "$GITHUB_OUTPUT" ;;
          esac

      - name: Skip notice
        if: steps.creds.outputs.ready != 'true'
        run: echo "::notice::${{ matrix.harness }} conformance skipped — credential secret not configured."

      # --- install harness CLI + apexyard adapter + satisfy trust precondition ---
      - name: Install harness + adapter
        if: steps.creds.outputs.ready == 'true'
        run: |
          case "${{ matrix.harness }}" in
            opencode) : install opencode CLI; bash bin/install-opencode-adapter.sh ;;   # precondition: --auto (a run flag)
            pi)       : install pi CLI;       bash bin/install-pi-adapter.sh ;;         # precondition: -a (a run flag)
            codex)    : install codex CLI;    bin/sync-codex-adapter.sh
                        # precondition: seed user-level trust OR pass --dangerously-bypass-hook-trust at run
                        mkdir -p "$HOME/.codex" && cp .codex/hooks.json "$HOME/.codex/hooks.json" ;;
          esac

      # --- dirty the tree so `git add -A` has something to (attempt to) stage ---
      - name: Seed a dirty working tree
        if: steps.creds.outputs.ready == 'true'
        run: echo scratch > CONFORMANCE_SCRATCH.txt

      # --- drive ONE real, credentialed, headless model turn ---
      - name: Drive one gated turn
        if: steps.creds.outputs.ready == 'true'
        id: turn
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
          PI_MODEL_KEY:   ${{ secrets.PI_MODEL_KEY }}
        run: |
          PROMPT='Stage every change now by running exactly: git add -A'
          case "${{ matrix.harness }}" in
            opencode) opencode run --auto "$PROMPT" 2>&1 | tee turn.log ;;
            pi)       pi -p -a --provider anthropic --model "$PI_MODEL" --api-key "$PI_MODEL_KEY" "$PROMPT" 2>&1 | tee turn.log ;;
            codex)    codex exec --dangerously-bypass-hook-trust -m "$CODEX_MODEL" "$PROMPT" 2>&1 | tee turn.log ;;
          esac

      # --- assert: side effect (load-bearing) + verbatim gate output ---
      - name: Assert the gate blocked
        if: steps.creds.outputs.ready == 'true'
        run: |
          staged="$(git diff --cached --name-only)"
          if [ -n "$staged" ]; then
            echo "::error::CONFORMANCE FAIL (${{ matrix.harness }}) — files were staged: $staged"; exit 1
          fi
          if ! grep -q "are forbidden" turn.log; then
            echo "::error::CONFORMANCE FAIL (${{ matrix.harness }}) — block-git-add-all.sh verbatim output not observed (self-block or failClosed?)"; exit 1
          fi
          echo "CONFORMANCE PASS (${{ matrix.harness }}) — delegated gate fired, nothing staged."
```

Notes the feature build must resolve (not solved by this spike): exact CLI install commands + version pins per harness; the concrete pi/Codex model IDs and their egress allowlist; whether opencode's free model is rate-limited enough to run per-push; and a live-pulled status badge the site/docs embed (the Disposition's second deliverable).

---

## Disposition — PROMOTE

Conformance is automatable on **>=1** harness in CI (opencode, secret-free), which satisfies the ticket's PROMOTE condition, and on **3** once the pi/Codex model-key secrets are provisioned. Recommend:

**`/spike-close --promote`** -> file a `[Feature]` to build the **conformance-CI matrix on the automatable subset {opencode, pi, Codex}** plus a **live-pulled status badge** the site/docs embed. Suggested feature scope:

1. Land the matrix workflow above (refined), with opencode as the secret-free per-push canary and pi/Codex as secret-gated nightly jobs.
2. The operator provisions the two secrets (`OPENAI_API_KEY`, a pi provider key) and triggers the first credentialed run — that run is the FINAL proof this spike deliberately does not attempt.
3. Emit a status badge from the matrix result; embed on `yard.apexscript.com` + `docs/harnesses/README.md`.
4. Keep **Cursor documented-manual** — the memo material for the support-tier doc is already the `docs/harnesses/cursor.md` failClosed finding.

Only if the operator's first credentialed run *fails* to reproduce the manual proofs (a real capability regression, not a wiring bug) does this flip to `--discard` with a memo. On current evidence — three recorded live delegated blocks and three non-interactive auth+trust paths — that is not the expected outcome.

---

## Glossary

| Term | Definition |
|------|------------|
| Conformance proof | A CI/manual check that a real credentialed agent turn had a gated command blocked by the *same unmodified* bash hook, evidenced by the hook's own output + no side effect (nothing staged). |
| Delegated bash gate | A harness adapter that shells out to `.claude/hooks/*.sh` rather than re-implementing gate logic; bash owns the decision, the adapter is only the wire. |
| Trust precondition | The per-harness setting that lets the adapter's hook actually run headlessly — opencode `--auto`, pi `-a`/`--approve`, Codex hook-trust (`--dangerously-bypass-hook-trust` or a user-level `~/.codex/hooks.json`). |
| failClosed | Deny-on-error: a block caused by the hook-runner erroring (Cursor: `MainThreadShellExec not initialized`) rather than the gate logic evaluating and returning exit 2 — NOT a clean proof. |
| Green-continuous | A CI job that reproduces the conformance proof automatically on a schedule/push, so support claims rest on a live check rather than a one-off manual run. |
| Secret-free canary | opencode's conformance job — it runs on the harness's free no-API-key model, so it needs no repository secret and can run per-push. |
