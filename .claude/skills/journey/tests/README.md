# /journey smoke test

Standalone Python script that renders the canonical fixture YAML to HTML using
the algorithm documented in `../SKILL.md`. Lets us verify on every change that:

- the YAML schema is parseable
- BFS layout produces sane box positions
- the HTML output is self-contained (no external CSS / JS / fonts)
- modals and boxes are emitted for every page
- transition labels render

This is a v1 smoke test, not a comprehensive renderer. The skill itself runs
inside Claude Code's environment and writes HTML directly via `Write`; this
script exists so a human or CI job can confirm the algorithm hasn't regressed.

## Run

From the apexyard fork root:

```bash
python3 .claude/skills/journey/tests/render_smoke.py
```

Defaults to:

| Input | Output |
|-------|--------|
| `.claude/skills/journey/fixtures/sample-checkout.yaml` | `/tmp/sample-checkout.html` |

Or pass explicit paths:

```bash
python3 .claude/skills/journey/tests/render_smoke.py path/to/journey.yaml /tmp/out.html
```

Exit code: `0` on success, `1` on any validation or rendering failure. The
script prints `OK: rendered N pages, M transitions to <path>` on success.

## Browser check

After running, open the output in your browser to verify modals open and close:

```bash
open /tmp/sample-checkout.html        # macOS
xdg-open /tmp/sample-checkout.html    # Linux
```

Expected behaviour:

- Three boxes (Cart, Payment, Confirmation) connected by two arrows
- Click any box → modal opens with the page's contents, transitions in/out
- Press Escape, click the backdrop, or click the × button → modal closes
- Tab navigates between boxes; Enter / Space opens the focused box's modal

Tested in Chrome, Safari, and Firefox on macOS — all three render the journey
identically and handle modals correctly.

## Dependencies

PyYAML if available; falls back to a minimal YAML subset parser sufficient for
the fixture if PyYAML is absent. No other runtime dependencies — vanilla Python
3.8+.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
