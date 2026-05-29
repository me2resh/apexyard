# Local model routing — agents via LiteLLM proxy + Ollama

Route specific Claude Code sub-agents through a locally-running Ollama instance instead of the Claude API. Useful when you want to keep prompts off any cloud API for bounded sub-tasks (ticket triage, data-analyst sketches, exploratory rephrasing).

This is **opt-in**. The default `agent-routing.yaml` shape is empty; absence of an `endpoint:` field keeps every agent on its framework default. Nothing in this setup changes the out-of-box experience.

> **Read this first:** [Spike #195 — local-model routing measurement + recommendation](spikes/local-model-routing.md). The TL;DR is *"NO-GO as designed, partial GO for synthesis-style sub-tasks; not for everything."* This guide ships the routing mechanism #438 asks for, but the spike's conclusions about tool-call reliability, cold-start latency, and "no silent fallback" all still apply.

## Before you start — the one manual step

`ANTHROPIC_BASE_URL` is set in your shell **before** Claude Code launches. SessionStart hooks (which is where `apply-agent-routing.sh` runs) execute in child shells and **cannot** change Claude's process env. So even after the SessionStart banner reports `applied N agent-routing override(s)`, the routing is INACTIVE until you do this:

```bash
# Add ONE of these to ~/.zshrc, ~/.bashrc, or your equivalent shell profile.
# The session-env file is written by apply-agent-routing.sh on each
# SessionStart and contains the resolved ANTHROPIC_BASE_URL for the
# first-declared reachable endpoint in agent-routing.yaml.

ops_root="${APEXYARD_OPS_ROOT:-$HOME/projects/apexyard}"   # or your fork's path
session_env="${ops_root}/.claude/session/agent-env/__session__.env"
[ -f "$session_env" ] && . "$session_env" && export ANTHROPIC_BASE_URL
```

Open a fresh terminal and launch Claude Code from it. On every SessionStart, the apply hook checks whether `$ANTHROPIC_BASE_URL` in the current process matches what `__session__.env` says it should be — if not, the banner now emits a one-line `⚠ routing INACTIVE` warning naming the gap. No silent failure.

If you'd rather not edit your shell profile, the alternative is to `export ANTHROPIC_BASE_URL=http://localhost:4000` manually in every terminal before `claude`. That works too; it's just the same step done by hand each time.

## 1. Install Ollama

| OS | One-liner |
|----|-----------|
| macOS | `brew install ollama` (then `ollama serve` runs as a launchd service) |
| Linux | `curl -fsSL https://ollama.com/install.sh \| sh` |
| Windows | Download from <https://ollama.com/download> |

Verify:

```bash
ollama --version
ollama list   # empty after fresh install
```

## 2. Pull an agent-grade model

Tool-call reliability is the load-bearing risk for routing agents through a local model. The `qwen2.5-coder` family ships with strong tool-call behaviour and is what we'd start with for ticket-manager / data-analyst-style structured-output work. Picking a model that fits *your* hardware matters more than picking the highest-MTEB one — the model must hold tools sanely on the workloads you'll actually run, not just on benchmarks.

| Model | Disk | RAM at load (Q4) | Notes |
|-------|------|------------------|-------|
| `qwen2.5-coder:14b` | ~9 GB | ~10 GB | Recommended starting point — strong tool-call reliability |
| `qwen2.5-coder:7b` | ~4.5 GB | ~6 GB | Works on most laptops; tool-call slightly weaker |
| `llama3.1:8b` | ~5 GB | ~6 GB | Generalist; less reliable on structured outputs |
| `deepseek-coder-v2:16b` | ~10 GB | ~12 GB | Code-oriented; needs M-series Pro or 14+ GB GPU |
| `mistral-small3:24b` | ~13 GB | ~18 GB | Strongest of the four; M-series Max territory |

Pull whichever fits:

```bash
ollama pull qwen2.5-coder:14b
ollama list
```

First call to a freshly-pulled model has **~9–10s cold-start latency** (measured in spike #195). Subsequent calls within the `OLLAMA_KEEP_ALIVE` window are warm.

## 3. Install + configure LiteLLM proxy

Claude Code expects an Anthropic-shaped HTTP API. LiteLLM is a thin proxy that translates Anthropic Messages requests into Ollama's native format. Install it as a Python tool:

```bash
pip install 'litellm[proxy]'
```

Create `~/.config/litellm/config.yaml` (or wherever your proxy config lives):

```yaml
model_list:
  - model_name: ollama/qwen2.5-coder:14b
    litellm_params:
      model: ollama/qwen2.5-coder:14b
      api_base: http://localhost:11434

  - model_name: ollama/llama3.1:8b
    litellm_params:
      model: ollama/llama3.1:8b
      api_base: http://localhost:11434
```

Start the proxy on port 4000:

```bash
litellm --config ~/.config/litellm/config.yaml --port 4000
```

Sanity check:

```bash
curl -s http://localhost:4000/v1/models | head -5
```

You should see the two models from the config. Leave the proxy running in a separate terminal (or as a launchd / systemd unit if you'd rather not babysit it).

## 4. Configure `agent-routing.yaml`

In your portfolio's `agent-routing.yaml` (or the fork-local copy in single-fork mode), add the agents you want to route:

```yaml
version: 1
agents:
  ticket-manager:
    model: ollama/qwen2.5-coder:14b
    endpoint: http://localhost:4000
    env:
      OLLAMA_KEEP_ALIVE: "30m"
```

Restart Claude Code. The `apply-agent-routing.sh` SessionStart hook will:

1. Probe `http://localhost:4000/v1/models` with a 2s timeout. If the proxy is down → emit a warning, skip the endpoint override, fall through to the model rewrite only.
2. Query `http://localhost:4000/api/tags` for `qwen2.5-coder:14b`. If the model isn't pulled → emit `⚠ agent-routing: ticket-manager — model qwen2.5-coder:14b not in local Ollama; run: ollama pull qwen2.5-coder:14b`. The override still applies; Ollama may pull on first call with the cold-start cost.
3. Rewrite `.claude/agents/ticket-manager.md` frontmatter so `model: ollama/qwen2.5-coder:14b`.
4. Write `.claude/session/agent-env/ticket-manager.env` with `ANTHROPIC_BASE_URL=http://localhost:4000` (informational in v1 — see constraints below).
5. Write `.claude/session/agent-env/__session__.env` with the same `ANTHROPIC_BASE_URL`. This is the session-wide variable Claude Code actually reads at startup.
6. Emit a one-line banner: `ApexYard: applied 1 agent-routing override(s) from agent-routing.yaml [1 Ollama, 0 warning(s)]`.

The `block-agent-routing-drift.sh` pre-commit/pre-push hooks will refuse to let the rewritten frontmatter escape to the public framework remote — adopter routing choices stay local.

## 5. Verify it's actually routing

Open a new Claude Code session in your apexyard fork. Trigger a ticket-manager invocation (e.g. `/task something-trivial`). Watch the LiteLLM proxy log — you should see an inbound POST to `/v1/messages` and a corresponding outbound call to Ollama's `/api/chat`.

If the routing didn't take effect, check in this order:

1. `cat .claude/session/agent-env/__session__.env` — does it contain `ANTHROPIC_BASE_URL=http://localhost:4000`?
2. `echo $ANTHROPIC_BASE_URL` — has the env file been sourced by your shell profile? (You may need to add `. .claude/session/agent-env/__session__.env` to your `.zshrc`/`.bashrc`.)
3. Was the LiteLLM proxy reachable when Claude Code started? (Check the SessionStart banner — `0 warning(s)` means the reachability check passed.)
4. `grep model .claude/agents/ticket-manager.md` — has the model frontmatter been rewritten?

## Constraints (read these before relying on local routing for anything important)

- **Single endpoint per session.** v1 sets `ANTHROPIC_BASE_URL` once at SessionStart. All agents share it. You can't have ticket-manager route to local Ollama while code-reviewer stays on Claude — that's a v2 concern, gated on Claude Code surfacing per-agent invocation env scoping (see [AgDR-0050 § Axis 5](agdr/AgDR-0050-agent-runtime-overhaul.md)). If you declare multiple distinct endpoints, the first wins and a warning is emitted.

- **Cold-start ~9–10s.** Measured in spike #195. The first call after `ollama serve` boot (or after `OLLAMA_KEEP_ALIVE` expires) pays full model-load cost. Subsequent calls within the keep-alive window are warm.

- **No silent fallback to Claude.** A downed LiteLLM proxy or Ollama service means the routed agent fails — the framework will NOT silently route to the Claude API instead. This is deliberate: silent fallback obscures whether you're actually getting local-routing semantics, and the spike memo specifically warned against it.

- **Tool-call reliability is model-dependent.** Even the recommended `qwen2.5-coder:14b` will occasionally drop tool calls under load. Run on a sub-task you can tolerate failing before pinning it as your primary path. Pure prose-synthesis tasks (e.g. inbox summary) are more forgiving than tool-call-heavy ones (e.g. ticket triage with `gh` API calls).

- **Hardware sizing.** As a rough guide: M-series Macs with ≥ 32 GB unified memory comfortably run any 14B model warm; ≥ 16 GB handles 7B models; below 16 GB will swap on the larger ones. Linux + discrete GPU: VRAM is the binding constraint, not system RAM.

- **`OLLAMA_KEEP_ALIVE`.** The env-var setting on the agent entry (`env: { OLLAMA_KEEP_ALIVE: "30m" }`) keeps the model resident in Ollama's process for 30 minutes after the last request. Tune to your usage pattern — too short and you pay cold-start on every session; too long and idle memory stays pinned.

## Disabling local routing

Delete the `endpoint:` line from the agent entry (or comment out the whole agent block). Restart Claude Code. The SessionStart hook rewrites the agent frontmatter back to the framework default and removes the session env file. No re-install required.

## What this guide is *not*

- Not a guide for routing the apexyard-search MCP server's embedding calls through Ollama. That's a separate concern with separate config; not in scope here.
- Not a recommendation that you *should* run local models for production agents. The spike memo's conclusion stands: route a bounded sub-task to a local model when (a) you have an offline-or-private-data constraint, or (b) you've measured that the quality is acceptable for that specific sub-task. Don't route everything.
