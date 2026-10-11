---
id: AgDR-0227
timestamp: 2026-10-11T07:10:00Z
agent: claude
model: claude-opus-5-5
trigger: user-prompt
status: executed
---

# Location of fork-only Claude Code plugins

> In the context of the `apexyard-status` band (#1541), which reads the state of an ops fork, facing the AgDR-0049 rule that marketplace sub-packs contain no framework-distinctive elements, I decided to keep fork-only plugins in `plugins/<name>/` and list them by relative path in the root `.claude-plugin/marketplace.json`, separate from the `marketplace/` funnel packs, to achieve an install that reads the plugin from the fork folder itself, accepting a second plugin location in the repository and a catalog that is useful only inside an ops fork.

## Context

- AgDR-0049 puts the funnel sub-packs in `marketplace/<pack>/`. A release-tag script extracts them from upstream. A smoke test makes sure that they contain no framework-distinctive paths, because people install them into projects that have no ApexYard fork.
- The `apexyard-status` plugin reads `.claude/session/` files, the session pin and the review-marker names of AgDR-0060. It does nothing outside an ops fork. It breaks the AgDR-0049 rule by design.
- The root `.claude-plugin/marketplace.json` already exists. It lists the `orbit` plugin from its own repository.
- Claude Code reads a plugin from the marketplace folder when the marketplace is a local folder and the entry is a relative path. Then `/reload-plugins` loads a new version after `/update`, with no reinstall and no copy.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. `plugins/<name>/` at the repository root, listed by relative path in the root `.claude-plugin/marketplace.json` (chosen) | Plugin is read from the fork folder, so `/update` plus `/reload-plugins` updates it. Clear split: `marketplace/` holds the funnel packs, `plugins/` holds fork-only plugins. One catalog for all ApexYard plugins | A second plugin folder at the root. The catalog lists a plugin that works only inside an ops fork |
| B. Add the plugin to `marketplace/` as a third pack | One plugin folder | Breaks the AgDR-0049 invariant and its smoke test. The extraction script would ship a plugin that does nothing outside a fork |
| C. A separate repository for the plugin | Independent versions | The plugin and the fork state it reads drift apart. An install copies the plugin, so `/update` does not update it |
| D. `.claude/plugins/<name>/` inside the framework `.claude/` folder | Keeps Claude Code files together | Claude Code discovery can read nested `.claude/` content. AgDR-0049 rejected the same layout for this reason |

## Decision

Chosen: **A**, because a fork-only plugin must change together with the fork state it reads. A relative-path entry in a local-folder marketplace lets Claude Code read the plugin from the fork. The funnel packs stay clean: the AgDR-0049 rule applies to `marketplace/` and does not apply to `plugins/`.

Rules for fork-only plugins:

1. A fork-only plugin lives in `plugins/<name>/` and has its own `.claude-plugin/plugin.json`.
2. The root `.claude-plugin/marketplace.json` lists it with `"source": "./plugins/<name>"`.
3. The plugin is optional. The committed `.claude/settings.json` does not enable it. An operator installs it with `--scope local`, which writes only to the uncommitted `.claude/settings.local.json`.
4. A fork-only plugin is display only. It reads files and never writes them. It can run read-only commands, such as a framework resolver, `ps`, or a read-only `gh` query. It never calls a write endpoint. It never replaces a shell hook. All gates stay in `.claude/hooks/`.
5. The extraction script and the AgDR-0049 smoke test do not read `plugins/`.

## Consequences

- An operator installs the band from the ops-fork root with two commands: `claude plugin marketplace add ./ --scope local` and `claude plugin install apexyard-status@apexyard --scope local`. `/setup` asks one yes/no question and runs them.
- The CLI refuses a bare `.` as a marketplace source in Claude Code 2.1.296. The commands use `./`.
- Change to #1541 (owner decision, 2026-10-11): #1541 ruled out network calls. The owner allowed one network call. Reason: review markers stay after a PR merges or closes outside `/approve-merge`, so a band that counts markers only shows stale `/approve-merge` requests. More than 40 such markers existed in one fork. The band now runs one read-only `gh pr list --state open` for each repo that has a candidate, at most once every 2 minutes, with a 5-second time limit, and keeps the result in memory. A PR waits only when it is open and its head is the commit in the Rex marker. If `gh` fails, the band counts from the markers and shows `(offline)`.
- The plugin hook API is early access. If a Claude Code release changes it, the band disappears. No gate is affected.
- A later fork-only plugin follows the same five rules. A plugin that also works outside a fork goes through AgDR-0049 instead.

## Artifacts

- me2resh/apexyard#1541
- `plugins/apexyard-status/`
- `.claude-plugin/marketplace.json`
