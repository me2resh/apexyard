# Heredoc-body stripping is an additive-question tool, never a gate pre-filter

> In the context of fixing me2resh/apexyard#1066 (git-command validators matching prose inside heredoc bodies), facing a choice between three parsing strategies and, across two security-review rounds, findings that the fix itself introduced two distinct bypasses, I decided to (a) strip heredoc bodies only for the "which ref / is this exempt" refinement question, never for the "is there a real git command here at all" gating question, (b) make the stripper itself two-pass and anchor-validated so it only ever removes CONFIRMED heredoc bodies, and (c) give `block-main-push.sh` an independent, heredoc-parsing-agnostic check that scans every push-shaped occurrence in the raw command and blocks if any names a protected branch — because (a) and (b) together stop a stripper bug from silencing a gate, but do not stop a decoy ref sitting in text the stripper correctly declines to touch from winning a first-match extraction. This AgDR states plainly, per the second review round's explicit demand, what is and is not guaranteed by this design, and records that the guarantee rests on caller discipline no test can enforce.

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

## The decoy-ref hijack — a second, narrower bug the first fix left open

Fixing the presence-check bypass (governance rule 2 below) does not fix everything wrong with using a first-match extractor. `strip_heredoc_bodies` is now deliberately conservative: it only strips a heredoc it can CONFIRM (anchored + terminated). For a heredoc it correctly DECLINES to touch — a backslash-escaped delimiter (`<<E\OF`), a dotted delimiter (`<<END.OF`), or no heredoc at all, just a quoted string — the body is, correctly, left completely visible. But "visible" cuts both ways: if that body happens to contain a plausible, NON-protected decoy ref, `extract_push_ref`'s first-match semantics return the decoy — a confident WRONG answer, not an empty one:

```bash
cat > /tmp/m.txt <<END.OF
see git push origin feature/GH-1-safe
END.OF
git push origin main
```

`extract_push_ref` returns `feature/GH-1-safe` (not protected) here. The fail-closed check from the first fix round (governance rule 3 below) only engages when heredoc-aware extraction returns EMPTY — it does not, and structurally cannot, catch a confident wrong answer. Meanwhile real bash terminates the heredoc at the line that actually equals `END.OF` and executes `git push origin main` for real. Same mechanism with `<<E\OF` (backslash-escaped delimiter) and with no heredoc syntax at all (`echo "see git push origin feature/GH-1-safe" && git push origin main`).

This is **pre-existing**, not a regression introduced by this PR — `dev`'s original, unfixed code exhibits the identical hijack on all three shapes, because it was never heredoc-aware to begin with. It is #1066's original "first match wins" bug, surviving precisely in the residual shapes the (now-correct) stripper is honest about being unable to confirm.

**Fix, deliberately independent of heredoc parsing**: `block-main-push.sh` now also scans the RAW command for EVERY push-shaped occurrence (`_extract_all_push_refs_core` in `_lib-extract-push-ref.sh`) and blocks immediately if ANY of them names a protected branch — before `is_tag_push` is even consulted, so a decoy `--tags` mention can't hide a real protected-branch push either. This does not touch the stripper, does not care whether a heredoc was confirmed or declined, and does not depend on getting heredoc-delimiter parsing right at all: a decoy sitting in text this parser can't confirm as a heredoc body is still just TEXT, and "does any push-shaped text in this command name a protected branch" is answerable without knowing anything about heredocs. Verified against all three decoy shapes plus a confirmed-heredoc control (`.claude/hooks/tests/test_heredoc_bypass_shapes.sh`, cases X1–X4), proven RED against the pre-fix code first.

This fix is scoped to `block-main-push.sh` only. `validate-branch-name.sh` shares the same `extract_push_ref` and is exposed to the identical first-match mechanism, but the consequence there is lower-severity (a non-conforming branch NAME might not get caught, versus a real push landing on a protected branch undetected) and is recorded as residue below rather than fixed in this round.

## Decision

Five changes across three review rounds, each closing a distinct gap the others leave open:

1. **`_lib-strip-heredoc.sh` is split into its own file** (moved out of `_lib-extract-push-ref.sh`) and its stripper is rewritten to be two-pass and conservative. A heredoc is only ever stripped when BOTH:
   - **Anchored**: everything after the delimiter word, on the same line, is empty, a `#` comment, or a plain output redirection (`>`, `>>`, an fd redirect like `2>`, or `&>`) — nothing else. A `<<` inside a quoted string, an arithmetic expression, or followed by `&&`/`||`/`;`/a pipe/another `<<` is never treated as a heredoc start.
   - **Terminated**: scanning forward from the candidate start, some later line — after tab-stripping for `<<-` — exactly equals the delimiter. If no such line is found anywhere in the rest of the command, nothing is stripped; the text from that point on is returned completely unchanged.

   Re-verified against all eight shapes: with this stripper, **none of them are ever stripped at all** — the (fixed) stripper declines every one of them, leaving the text byte-for-byte identical to the raw command. The legitimate heredoc shapes (the ticket's own repro, `<<-EOF`, `<<'EOF'`, `<<"EOF"`, a trailing redirect like `cat <<EOF > file`) are still stripped correctly.

2. **The presence check — "is there a real git push/commit here at all" — always runs against the RAW, unfiltered command.** Never against this file's output, regardless of how conservative the stripper is believed to be. `strip_heredoc_bodies` (and `extract_push_ref` / `is_tag_push`, which call it internally) may only be used to refine an ADDITIVE question — "given that a real operation is independently known to exist, which ref / is it exempt" — never to decide whether the gate should fire.

   Concretely: `validate-branch-name.sh` and `block-main-push.sh`'s `grep -qE 'git push'` / `'git commit'` presence checks, and both hooks' `cd`-target extraction for worktree resolution, operate on the raw `$COMMAND` throughout. `is_tag_push` and `extract_push_ref` are still called with the raw command too (they strip internally) — this is safe for `extract_push_ref` specifically because of point 3 below; **it is NOT safe for `is_tag_push` on its own**, which is why point 5 exists.

3. **Fail closed on disagreement, for the push ref specifically.** `_extract_push_ref_core` (the token-parsing logic, now exposed directly, no stripping) is run a second time against the RAW command as a comparison signal. If the heredoc-aware `extract_push_ref` finds no ref, but the raw-text core parser finds something ref-shaped, that disagreement means a heredoc may be hiding the real destination rather than this genuinely being a ref-less push — falling back to local-HEAD validation in that case could validate the wrong branch. Both hooks now BLOCK instead, with a message pointing at the ticket's own mitigation (split the heredoc-writing and the git command into separate Bash calls).

   **The sharper framing for why this specific check works, and where it stops working (supplied during code review, and better than this AgDR's earlier "additive vs subtractive" wording for this specific case):** a *missing* answer is additive-safe — the fail-closed check above exists precisely to catch it. A *wrong, non-empty* answer is different in kind: it is **substitutive, with no backstop**. In `block-main-push.sh`, a non-empty `PUSH_DST` *replaces* the local-state fallback outright — nothing downstream double-checks a non-empty value, so a confidently wrong ref decides which branch gets checked, full stop. This is exactly what makes the decoy-ref hijack (below) dangerous: for the shapes where the (fixed) stripper declines to strip, both the heredoc-aware parser and the raw-text parser **agree** on the same wrong, non-empty ref — there is no disagreement for point 3's check to catch, because the fail-closed comparison only fires on disagreement, and agreement-on-a-wrong-answer produces none.

   An earlier version of this AgDR claimed `is_tag_push` "does not need the equivalent treatment: stripping can only ever *remove* text, never manufacture a `--tags` mention that wasn't in the raw command, so the only failure direction is a false NEGATIVE." **That claim is false, and was verified false at the hook level, not just in theory.** The reasoning about stripping was correct as far as it went — stripping alone cannot invent a `--tags` mention — but it missed that for an UNCONFIRMED heredoc, stripping does not happen AT ALL (it correctly declines), so decoy prose that was already sitting in the raw command survives untouched and can match `is_tag_push`'s pattern directly. That is a genuine, verified false POSITIVE, not a false negative:

   ```bash
   cat > /tmp/m.txt <<END.OF
   we always use git push --tags for releases
   END.OF
   git commit -m "bad commit"
   ```

   `is_tag_push` returns TRUE here (the decoy line matches `\bgit\s+push\b.*\s--tags(\s|$)`), even though there is no real tag push anywhere in the command. Before this round, `block-main-push.sh` treated that TRUE as a script-level `exit 0` — which didn't just skip the push-branch-check (arguably fine, since it has no ref to protect here anyway), it skipped the **entirely unrelated commit-check section further down the same script**, letting a real `git commit` on a protected branch (`dev`) slip through with zero inspection. Verified: `rc=0` before the fix in this round, `rc=2` after.

4. **`block-main-push.sh` scans every push-shaped occurrence in the raw command, independent of heredoc parsing entirely, and blocks if any names a protected branch.** This is the fix for the decoy-ref hijack above. It is deliberately NOT built on top of `strip_heredoc_bodies` or `extract_push_ref` — it does not ask "is this a heredoc", "is it confirmed", or "which one is the real command"; it asks only "does any push-shaped piece of text in this raw command name a protected branch", which is answerable regardless of how good or bad heredoc-delimiter parsing is. This is what makes it a genuine backstop for point 3 rather than a variation on the same mechanism: point 3's fail-closed check can only fire when heredoc-aware extraction returns *empty* and disagrees with the raw parse; a decoy ref is precisely the case where both parsers agree on something else — confidently, wrongly, non-empty, with no disagreement to catch.

5. **`is_tag_push`'s verdict in `block-main-push.sh` no longer causes a script-level exit.** A `true` result now only skips the push-branch-check (which point 4's scan-all check has, by that point, already covered independently — so skipping it costs nothing); it never short-circuits the whole script, so the commit-check section always still runs regardless of what `is_tag_push` decided. This is a narrower, more surgical fix than redesigning `is_tag_push` itself: it does not stop `is_tag_push` from being fooled by decoy prose, it stops that being fooled from mattering for anything `is_tag_push` isn't actually about.

## Consequences — what is guaranteed, what is not, stated plainly

An earlier draft of this section said the documented residue has "no safety impact — only a minor UX one." **That was false, and it is exactly the sentence a future adopter would lean on.** The corrected version below says plainly what genuinely holds and what does not.

**What genuinely holds — this is the real fix, and it is load-bearing:**

- Presence checks (`grep -qE 'git push'` / `'git commit'` — the "should this hook look at this command at all" gate) never consult this file's stripped output, in either hook. That single rule is what stops a stripper bug (over-eating, under-eating, any future parsing mistake) from making a gate skip itself silently. This is the actual fix for the first review round's eight shapes, and it is a genuine, structural guarantee: the coupling between "stripper made a mistake" and "gate never asked the question" has been removed, not patched around.
- The ticket's original, deterministic repro is fixed: a heredoc-authored commit message that merely discusses `git push` no longer causes the wrong branch to be validated (the CONFIRMED-heredoc case; see X4 in the test suite).
- `block-main-push.sh` additionally scans every push-shaped occurrence in the raw command (decision point 4) and blocks if any names a protected branch — closing the decoy-ref hijack independent of whether heredoc-delimiter parsing succeeds at all.
- `is_tag_push`'s verdict in `block-main-push.sh` can no longer suppress an unrelated section of the script (decision point 5) — a decoy `--tags` mention can, at worst, skip the push-branch-check (already independently covered by decision point 4), never the commit-check.

**What does NOT hold — the residue that matters, stated without softening:**

- **For shapes the parser declines to strip (unconfirmed heredocs), a decoy ref in the unstripped body can still win a first-match extraction.** This is exactly #1066's original bug, still alive, in the exact place the stripper is honest about not being able to confirm. Decision point 4 closes this for `block-main-push.sh` (which has a protected-branch LIST to check every occurrence against). It does **not** close it for `validate-branch-name.sh`, which shares `extract_push_ref`'s first-match semantics and has no equivalent "scan everything" backstop — a non-conforming branch NAME hidden behind a conforming-looking decoy can still slip past the naming gate. Lower severity than a protected-branch bypass (a naming-convention miss, not an unreviewed push landing), but real, unfixed, and worth stating rather than implying it doesn't exist.
- **A new, deliberately-accepted false-block was introduced, in the safe direction, as a side effect of the point-4 fix.** `block-main-push.sh`'s "scan every occurrence" check operates on the RAW command, so a legitimate, well-formed heredoc that merely *discusses* pushing to a protected branch in prose — with no real push to it anywhere in the command — can now cause an otherwise-benign push to a different branch to be blocked. This is the same "over-block on prose" trade-off already accepted elsewhere in this document (see the commit-check narrowing below); it is recorded here rather than chased, per the same reasoning: the tolerated failure is occasional over-blocking on prose, never a silent bypass.
- **A second, distinct new false-block, on `validate-branch-name.sh`, caused by the fail-closed check itself (decision point 3) — verified, not a corner case with no real trigger:**

  ```bash
  cat > /tmp/m.txt <<EOF
  Remember: we should git push origin feature/GH-1-ok when ready.
  EOF
  git commit -F /tmp/m.txt
  ```

  There is no real `git push` anywhere in this command — just a commit, whose message happens to discuss one, inside a CONFIRMED (correctly-stripped) heredoc. `dev`'s original code returns `rc=0`: it extracts the SAME decoy ref (`feature/GH-1-ok`) from the raw text every time (it has no concept of "stripped" vs "raw"), and that decoy happens to be conforming-shaped, so it validates clean and passes. The current code returns `rc=2`: heredoc-aware extraction correctly finds no push (the body was properly stripped), so the fail-closed check compares against `_extract_push_ref_core` on the raw command, finds the same decoy, and — because that check triggers on *any* non-empty disagreement, not on whether the disagreeing value looks well-formed — blocks with "cannot safely determine the push destination," even though the decoy would have looked fine if naively validated. Good error message, safe direction, but it is a sub-case of what #1066 set out to fix: the promise holds when a real push follows the heredoc, not when none does at all.
- **Deliberate narrowing, unchanged from the first round**: `block-main-push.sh`'s commit-check has no "which ref" refinement step at all (it only checks the current branch), so it has nothing for heredoc-stripping to safely improve — its presence check runs against raw text unconditionally. A Bash call that writes a well-formed, legitimately-terminated heredoc merely *discussing* `git commit`, with no real commit anywhere in the command, will still BLOCK if the session happens to sit on a protected branch — reverting, for this one case, to `dev`'s pre-#1066 conservative behaviour.
- **The anchor+two-pass stripper recognises a handful of exotic heredoc-delimiter shapes as heredoc-*like* but never actually strips them**, because the real terminator can't be confidently computed or confirmed: backslash-escaped, multi-word-quoted, or dotted delimiters (`<<E\OF`, `<<'E O F'`, `<<END.OF`); two heredocs on one line (`cmd <<A <<B`); a here-string (`<<<`) combined with a heredoc on the same line. This has no impact on the presence-check guarantee above (which never depends on stripping succeeding), but — as the decoy-ref hijack section demonstrates — it is precisely where a decoy can still survive to be first-matched. It is not merely a UX cost; it is the boundary of what decision point 4 does and does not cover for the one hook it was applied to.
- **`is_tag_push`'s decoy-prose false positive (decision point 5's subject) is fixed for `block-main-push.sh` only, at the "don't let it exit the whole script" level — it is NOT fixed for `validate-branch-name.sh`, which has no equivalent second section to protect and no scan-all backstop for this function at all.** A decoy `--tags` mention in an unconfirmed heredoc (`cat > /tmp/m.txt <<END.OF\nwe always use git push --tags for releases\nEND.OF\ngit push origin bogus-branch`) still makes `validate-branch-name.sh`'s `is_tag_push` return true and `exit 0`, skipping validation of a real, non-conforming push destination — verified, `rc=0`, unfixed. Same severity class as the ref-hijack residue above (a naming-convention miss, not a protected-branch bypass), and left as residue for the same reason: `validate-branch-name.sh` was out of scope for the scan-all fix this round.
- **A genuinely ref-less push, sitting alongside heredoc prose that itself contains a ref-shaped push mention, now blocks where `dev` fell back to local HEAD.** E.g. a bare `git push` (relying on upstream tracking, no explicit ref) in the same command as a heredoc discussing "`git push origin some-branch`": the heredoc-aware parser correctly finds no ref for the real push, but the raw-text comparison (decision point 3) finds the decoy's ref-shaped text and disagrees — triggering the fail-closed block instead of falling through to `dev`'s local-HEAD check. Safe direction (over-blocking, not under-blocking), not chased, and of the same shape as the other residue items above: when the raw and heredoc-aware parsers disagree, this design blocks rather than guesses, even when the "real" case is a legitimate ref-less push.

**This safety rests on caller discipline, which no test can enforce.** Every guarantee above depends on every future caller of `strip_heredoc_bodies` / `extract_push_ref` / `is_tag_push` respecting the governance rule in `_lib-strip-heredoc.sh` — using them only for additive refinement, never as a gate's own presence pre-filter. A test suite can (and does, here) prove the CURRENT two call sites respect that rule. It cannot prove a future call site will. That is a property of code review and this document, not of `test_heredoc_bypass_shapes.sh`.

**Adopter condition for `verify-commit-refs.sh`'s `resolve_commit_workdir()` (#1073, queued).** `_lib-strip-heredoc.sh` was split into its own file specifically so this hook can adopt it. But `resolve_commit_workdir()` is not a drop-in case of "extract a ref, fall back if empty" — it resolves a *path*, which a gate then reads a branch FROM. The same bug class transplants directly: if stripping over-strips and the function's result comes back empty (or, by the decoy-ref analogy, a confident wrong path), the caller must **fail closed**, not silently fall back to the hook's own session cwd — falling back to session cwd in a worktree session is the exact false-negative shape #549/#727 exist to prevent, and falling back to session cwd on an AMBIGUOUS heredoc-affected result reintroduces a bypass in a new hook rather than closing one. Any PR adopting this helper must show the equivalent of decision points 2–3 (raw presence check, fail-closed on disagreement) for its own empty/ambiguous case before merging.

**Why sharing the helper is judged safe despite all of the above.** The security review that found the first-round bypass considered, and initially rejected, sharing `_lib-strip-heredoc.sh` across hooks — a shared subtractive filter with a bug is a bug shared by every consumer at once. That objection is withdrawn here because the coupling it worried about was removed *architecturally*, not patched over: after decision point 2, this file's stripped output can no longer reach a presence check in either existing consumer, by construction, not by convention alone backed by a comment. A future bug in the stripper therefore costs ref *precision* (an additive question, with a fallback) in whichever hook has one, never gate *existence* (a subtractive question, with no fallback) — provided the adopter condition above is honoured. That distinction, not the mere fact that the code is now reusable, is what makes sharing this file across hooks defensible.

## Artifacts

- me2resh/apexyard#1066 (original ticket)
- me2resh/apexyard#1075 (PR — first fix + security-review correction, this AgDR)
- `.claude/hooks/_lib-strip-heredoc.sh` (the stripper + its governance comment)
- `.claude/hooks/_lib-extract-push-ref.sh` (`_extract_push_ref_core`, `extract_push_ref`, `is_tag_push`)
- `.claude/hooks/tests/test_heredoc_bypass_shapes.sh` (all eight presence-check bypass shapes, the X1–X4 decoy-ref hijack cases, and the TAGDECOY script-exit case, each proven RED then GREEN)
- `.claude/hooks/tests/test_extract_push_ref_heredoc.sh`, `test_validate_branch_name_heredoc.sh`, `test_block_main_push_heredoc.sh` (the original ticket's repro + regressions)
- AgDR-0104 (trust-chain controls vs. backstops — the framing this decision explicitly does not try to defeat: it fails in the safe direction rather than claiming a text-matching parser can be made perfectly sound)
