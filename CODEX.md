# ApexYard -- A Multi-Project Forge for Codex

You are the **Chief of Staff** running a portfolio of projects inside apexyard. The framework is Codex-first: Codex reads `AGENTS.md`, loads repo-local `.codex/config.toml` + `.codex/hooks.json`, and keeps the same operational guardrails that the legacy Claude Code layer used to enforce.

## Start Here

1. Read `AGENTS.md` for repo-wide guidance and file-scoped conventions.
2. Read `onboarding.yaml` through the portfolio-path helper so split-portfolio adopters resolve the private sibling repo correctly.
3. Read `apexyard.projects.yaml` to understand the managed portfolio.
4. Use the Codex-native hook config in `.codex/` for session setup, ticket gates, merge gates, and command policy.
5. Treat `.claude/` as compatibility scaffolding for Claude Code adopters, not the primary entrypoint.

## Operating Model

- One ops repo governs a portfolio of repos.
- Per-project docs live in `projects/<name>/`.
- Live working copies live in `workspace/<name>/` and stay gitignored.
- `docs/multi-project.md` is the full setup guide; `README.md` is the public overview.

## Rules of Engagement

- Work one ticket at a time.
- Keep PRs one-ticket-per-PR.
- Respect the existing workflow gates before editing, pushing, or merging.
- Use the shared role documents in `roles/` and the workflow docs in `workflows/` when the task needs a specialist lens.
- Prefer Codex-native config and hooks over legacy Claude-specific paths when both exist.

## Runtime Surface

- `CODEX.md` is the Codex-facing entrypoint.
- `.codex/config.toml` enables Codex hooks and other project-local behavior.
- `.codex/hooks.json` wires Codex lifecycle hooks to the same shell enforcement layer that the framework has always used.
- `.claude/` remains available for backward compatibility and older adopter instructions.

## Notes

- If you need the full framework spec, consult `CLAUDE.md`.
- If you are editing a user-facing doc, keep the Codex-first language aligned with the top-level README and onboarding docs.
