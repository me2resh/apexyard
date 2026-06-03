# Cursor agent performance (ApexYard ops repo)

Operators using **Cursor** on an ApexYard fork (especially with many `workspace/<name>/` clones) should follow this checklist so agents stay fast and token use stays bounded.

## One-time setup

1. **Keep `.cursorignore` at the ops-repo root** — the framework ships it from `templates/cursorignore`. It excludes the entire `workspace/` tree (all current and future clones). Commit it; do not delete it after `/update`.
2. **Reload Cursor** after adding or changing `.cursorignore` (Command Palette → **Developer: Reload Window**) so the index rebuilds.
3. **Split-portfolio v2:** if `workspace/` lives in your **private portfolio repo**, copy the same `templates/cursorignore` to that repo root as `.cursorignore` and commit there. The public ops fork’s file does not apply to a sibling directory.
4. **Trim Cursor context:** disable global skill packs you do not use (gstack, impeccable, etc.). Fewer injected skills → less per-turn token burn unrelated to disk size.

## Daily workflow

| Task | Open in Cursor |
|------|----------------|
| Portfolio ops (`/inbox`, `/tasks`, registry, `projects/`) | ApexYard **ops repo root** |
| Edit one app’s code, tests, CI | `workspace/<name>/` as **workspace root** (File → Open Folder) |

Staying at the ops root while editing app code pulls the whole portfolio index back into scope unless you excluded `workspace/` — which is why `.cursorignore` exists.

## Adding projects (scales automatically)

- `/handover` or `git clone … workspace/<new-name>/` — **no Cursor config change.** Anything under `workspace/` remains ignored.
- Only exception: you intentionally removed `workspace/` from `.cursorignore` to index one clone from the ops root — restore the line when done.

## SessionStart reminder

`check-cursorignore.sh` prints a one-line banner when `.cursorignore` is missing or does not exclude `workspace/`. Fix with:

```bash
cp templates/cursorignore .cursorignore
git add .cursorignore
```

## Claude Code note

Claude Code does not use `.cursorignore`. The same gitignore + “open the clone when coding” discipline still applies; LSP cold-start caveats are in `docs/getting-started.md`.

## Related

- `workspace/README.md` — why gitignore ≠ Cursor index
- `docs/multi-project.md` — portfolio layout and split-portfolio `workspace/`
