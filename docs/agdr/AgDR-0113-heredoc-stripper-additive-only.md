# Heredoc-body stripping is an additive-question tool, never a gate pre-filter

> In the context of fixing me2resh/apexyard#1066 (git-command validators matching prose inside heredoc bodies), facing a choice between three parsing strategies and, on first attempt, a security-review finding that the fix itself introduced a bypass, I decided to (a) strip heredoc bodies only for the "which ref / is this exempt" refinement question, never for the "is there a real git command here at all" gating question, and (b) make the stripper itself two-pass and anchor-validated so it only ever removes CONFIRMED heredoc bodies — to close the original false-positive bug without opening a false-negative (bypass) in its place, accepting that a handful of exotic heredoc-delimiter shapes are recognised as heredoc-like but deliberately left un-stripped (safe, not a UX nicety).

## Context

`validate-branch-name.sh` and `block-main-push.sh` both need to know, from a raw Bash tool-call string, whether a `git push` / `git commit` is really happening and (for push) which branch is the destination. The naive approach — grep the whole command string for `git push` / `git commit` and pull the first ref-shaped token after it — breaks when the command also contains a heredoc: this repo's own commit messages and PR/review bodies routinely *discuss* git behaviour in prose (`git push`, `--tags`, `<<EOF`, C++'s `<<` operator), and a heredoc body is exactly where that prose lives.

The ticket's own repro is the clean, deterministic case:

```bash
cat > /tmp/m.txt <<EOF
The previous commit claimed terminal `git push` still runs the checks because
bin/run-pre-push-checks.sh hardcodes them.
EOF
git commit -F /tmp/m.txt
git push upstream fix/GH-1031-untrack-project-config-json
```

The first "git push"-shaped text anywhere in the raw string is inside the heredoc body ("`git push` still runs the checks"), so a naive scanner extracts `still` as the branch name and blocks a correctly-named push. `block-main-push.sh`'s commit-check has the mirror bug: it treats the mere substring "git commit" anywhere in the command as evidence a commit is happening, so a heredoc that only *discusses* a commit falsely blocks on a protected branch even though nothing is being committed.

## Options considered

The ticket's investigation notes listed three directions:

| Option | Pros | Cons |
|--------|------|------|
| **A. Strip heredoc bodies (and quoted strings) before matching** | Directly targets the repro; keeps the existing worktree-safe text-scan capability (#194/#547) intact | Narrower fixes elsewhere (per-statement scanning) still need the same heredoc-awareness as a prerequisite, so this isn't really competing with B — see below |
| **B. Validate per-statement / only the command's last statement** | Sounds simpler | Doesn't remove the ambiguity, it relocates it — a per-statement scanner still has to recognise a heredoc BODY line isn't a statement at all before it can skip it. And "only the last statement" breaks the existing commit-then-push compound check (block-main-push.sh must block a commit on a protected branch even when a push follows it) |
| **C. Narrow the text scan to the worktree case it was built for** | Reduces the scan's blast radius | Doesn't fix the ticket's own repro, which isn't a worktree scenario at all — it's a plain, single-checkout commit+push. Narrowing *when* the scan runs doesn't stop it *misreading heredoc prose on the calls where it still has to run* |

**Chosen: Option A** — strip heredoc bodies, refined below. B and C were rejected for the reasons in the table; neither closes the ticket's actual repro, and B in particular has to solve the same sub-problem A does, just less directly.

## The bug in the first implementation, and the second decision it forced

The first version of Option A (me2resh/apexyard#1075, the PR this ticket produced) stripped heredoc bodies with a single-pass scanner — any line containing `<<` followed by a word-shaped token was treated as a heredoc start, and everything after it was dropped until a matching terminator line was found (or, if none was found, until the command ended). Both hooks then ran their **presence checks** (`grep -qE 'git push'` / `'git commit'` — the boolean "should this hook even look at this command" gate) against that stripped text.

A security review of that PR found this was a bypass, not just an incomplete fix. Verified by stubbing `git` on `PATH` and confirming the push genuinely executes, eight distinct shapes made the single-pass stripper eat the real command:

| Shape | Why the single-pass stripper ate the real command |
|-------|------------------------------------------------------|
| Unterminated heredoc (`cat <<EOF` with no closing `EOF` line) | No terminator ever found → old design dropped the remainder of the command, including a real `git push` on a later line |
| Backslash-escaped delimiter (`<<E\OF`) | The old regex parsed the terminator as `E` (stopping at the backslash); the real closing line `EOF` never matches `E`, so it's effectively unterminated |
| Multi-word quoted delimiter (`<<'E O F'`) | The old regex can't capture a delimiter containing spaces; it parsed a stray leading quote into the terminator, which then never matches |
| Dotted delimiter (`<<END.OF`) | The identifier regex stops at the `.`; the parsed terminator (`END`) never matches the real line (`END.OF`) |
| `<<EOF` inside a quoted string, no real heredoc at all (`echo "docs say use cat <<EOF here" && git push origin main`) | The old design had no concept of "what follows this delimiter word on the same line" — any word-shaped token after `<<` was accepted as a heredoc start regardless of context |
| Commit message merely mentioning `<<EOF` (two separate lines, no chaining) | Same root cause as above, applied across a line boundary |
| Two heredocs on one line (`cat <<A <<B`) | The old design only recognised the first `<<` on a line and had no anchor check, so it entered heredoc mode on the first candidate and then, encountering the second literal `<<` on a subsequent line by itself, entered a SECOND heredoc whose terminator (`X`) never appeared — eating the real push that followed |
| C++ `operator<<` / shift usage in a quoted commit message (`git commit -m "use a << b shift"`) | Same root cause as the quoted-string case above |

Both `validate-branch-name.sh:33` and `block-main-push.sh:87` ran their presence check against the stripped (over-eaten) text, so for all eight shapes the gate silently exited 0 and the real push ran unvalidated.

### The framing that fixes it: additive vs. subtractive

The security review's core insight, which this AgDR adopts as governance for the whole file (`_lib-strip-heredoc.sh`) and everything that sources it:

> `extract_push_ref` is an **additive extractor** — it tries to answer "what is the ref"; a bug yields a wrong answer, and the caller still has real content (the raw command, an independent local-state fallback) to check against. Failure is local and visible.
>
> `strip_heredoc_bodies` is a **subtractive pre-filter on gate input** — it decides what a caller is even ALLOWED to see. A bug here produces *no question being asked at all*, silently and fail-open across every consumer simultaneously.

Concentrating the first kind of function (a shared, well-tested `extract_push_ref`) buys safety — one bug fixed once benefits every caller. Concentrating the second kind turns one parser mistake into a bypass across every gate that trusts it, which is exactly what the table above demonstrates across two gates (with a third, `verify-commit-refs.sh`'s `resolve_commit_workdir()` from #1073, a natural future adopter of the same kind of raw-command-text parsing).

## Decision

Two changes, both required, neither sufficient alone:

1. **`_lib-strip-heredoc.sh` is split into its own file** (moved out of `_lib-extract-push-ref.sh`) and its stripper is rewritten to be two-pass and conservative. A heredoc is only ever stripped when BOTH:
   - **Anchored**: everything after the delimiter word, on the same line, is empty, a `#` comment, or a plain output redirection (`>`, `>>`, an fd redirect like `2>`, or `&>`) — nothing else. A `<<` inside a quoted string, an arithmetic expression, or followed by `&&`/`||`/`;`/a pipe/another `<<` is never treated as a heredoc start.
   - **Terminated**: scanning forward from the candidate start, some later line — after tab-stripping for `<<-` — exactly equals the delimiter. If no such line is found anywhere in the rest of the command, nothing is stripped; the text from that point on is returned completely unchanged.

   Re-verified against all eight shapes: with this stripper, **none of them are ever stripped at all** — the (fixed) stripper declines every one of them, leaving the text byte-for-byte identical to the raw command. The legitimate heredoc shapes (the ticket's own repro, `<<-EOF`, `<<'EOF'`, `<<"EOF"`, a trailing redirect like `cat <<EOF > file`) are still stripped correctly.

2. **The presence check — "is there a real git push/commit here at all" — always runs against the RAW, unfiltered command.** Never against this file's output, regardless of how conservative the stripper is believed to be. `strip_heredoc_bodies` (and `extract_push_ref` / `is_tag_push`, which call it internally) may only be used to refine an ADDITIVE question — "given that a real operation is independently known to exist, which ref / is it exempt" — never to decide whether the gate should fire.

   Concretely: `validate-branch-name.sh` and `block-main-push.sh`'s `grep -qE 'git push'` / `'git commit'` presence checks, and both hooks' `cd`-target extraction for worktree resolution, operate on the raw `$COMMAND` throughout. `is_tag_push` and `extract_push_ref` are still called with the raw command too (they strip internally) — this is safe specifically because of point 3 below.

3. **Fail closed on disagreement, for the push ref specifically.** `_extract_push_ref_core` (the token-parsing logic, now exposed directly, no stripping) is run a second time against the RAW command as a comparison signal. If the heredoc-aware `extract_push_ref` finds no ref, but the raw-text core parser finds something ref-shaped, that disagreement means a heredoc may be hiding the real destination rather than this genuinely being a ref-less push — falling back to local-HEAD validation in that case could validate the wrong branch. Both hooks now BLOCK instead, with a message pointing at the ticket's own mitigation (split the heredoc-writing and the git command into separate Bash calls).

   `is_tag_push` does not need the equivalent treatment: stripping can only ever *remove* text, never manufacture a `--tags` mention that wasn't in the raw command, so the only failure direction is a false NEGATIVE (over-stripping hides a real `--tags`, and the caller proceeds to validate a legitimate tag push as an ordinary branch push — a false block, not a bypass).

## Consequences

- The ticket's original, deterministic repro is fixed: a heredoc-authored commit message that merely discusses `git push` no longer causes the wrong branch to be validated.
- The eight bypass shapes are closed: every one of them now BLOCKS (verified — see `.claude/hooks/tests/test_heredoc_bypass_shapes.sh`, proven RED against the vulnerable code first).
- **Deliberate narrowing accepted**: `block-main-push.sh`'s commit-check has no "which ref" refinement step at all (it only checks the current branch), so it has nothing for heredoc-stripping to safely improve — its presence check runs against raw text unconditionally. This means a Bash call that writes a well-formed, legitimately-terminated heredoc merely *discussing* `git commit`, with no real commit in the command at all, will still BLOCK if the session happens to sit on a protected branch — reverting, for this one narrow case, to `dev`'s pre-#1066 conservative behaviour. This is accepted as the correct trade-off: the alternative (trusting stripped text for this specific presence check) is exactly the class of bug this AgDR exists to close.
- **Known residue — safe, not a UX nicety-gap that matters for safety**: the anchor+two-pass design means a handful of exotic heredoc-delimiter shapes are recognised as heredoc-*like* (they contain `<<`) but never actually stripped, because they can't be confidently confirmed:
  - Backslash-escaped, multi-word-quoted, or dotted delimiters (`<<E\OF`, `<<'E O F'`, `<<END.OF`) — the exact real terminator can't be computed by this parser, so it's never found, and the heredoc is (correctly, safely) left unstripped.
  - Two heredocs on one line (`cmd <<A <<B`) — not specially parsed; the anchor check rejects the first candidate (since `<<B` follows it), so no heredoc is recognised on that line at all.
  - A here-string (`<<<`) combined with a heredoc on the same line — not specially handled.

  None of these create a safety gap, because presence checks never consult this function's output (rule 2 above) — the only cost is that a **legitimate** use of one of these exotic shapes doesn't get the "prose is hidden from the presence check" nicety either. Given how rare these shapes are in practice (nobody writing commit messages via heredoc uses a backslash-escaped or two-heredocs-on-one-line delimiter), this is judged an acceptable, explicitly-documented trade for closing a real bypass.
- **Generalises beyond this PR.** `_lib-strip-heredoc.sh` is a standalone file specifically so `verify-commit-refs.sh`'s `resolve_commit_workdir()` (added in #1073, which parses `git -C <path>` / `cd <path> &&` out of the same kind of raw command text) can adopt it as a follow-up. Any future adopter MUST follow the same governance rule: use it only for additive refinement, never as a gate's own presence pre-filter.

## Artifacts

- me2resh/apexyard#1066 (original ticket)
- me2resh/apexyard#1075 (PR — first fix + security-review correction, this AgDR)
- `.claude/hooks/_lib-strip-heredoc.sh` (the stripper + its governance comment)
- `.claude/hooks/_lib-extract-push-ref.sh` (`_extract_push_ref_core`, `extract_push_ref`, `is_tag_push`)
- `.claude/hooks/tests/test_heredoc_bypass_shapes.sh` (all eight bypass shapes, proven RED then GREEN)
- `.claude/hooks/tests/test_extract_push_ref_heredoc.sh`, `test_validate_branch_name_heredoc.sh`, `test_block_main_push_heredoc.sh` (the original ticket's repro + regressions)
- AgDR-0104 (trust-chain controls vs. backstops — the framing this decision explicitly does not try to defeat: it fails in the safe direction rather than claiming a text-matching parser can be made perfectly sound)
