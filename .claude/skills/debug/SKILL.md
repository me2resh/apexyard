---
name: debug
description: Hypothesis-driven debugging — architecture-first reading + evidence-before-fix. For bugs that resisted naïve fix attempts.
disable-model-invocation: false
argument-hint: "[symptom summary]"
effort: medium
---

# /debug — Structured Debug Methodology

Most "stuck" debug sessions look the same: pattern-match on the symptom, propose a fix, ship it, find a different symptom, repeat. Each cycle costs a deploy + a CEO approval + the user's patience. This skill enforces the discipline that prevents the loop:

1. **Capture the symptom precisely** — the exact URL, the exact response, the exact step that fails.
2. **Read the architecture before guessing** — map every layer the request touches.
3. **Form a hypothesis ladder** — 3–5 candidate causes ordered by probability, each with an explicit evidence test.
4. **Gather evidence first, fix second** — never ship a fix without a verification step that would have caught the wrong hypothesis.
5. **Verify the fix against the original evidence** — re-run the symptom check, not just the unit tests.

The cost of one extra `curl`, one extra `Read`, one extra "what does the server actually return?" — is one minute. The cost of one wrong fix that ships, deploys, blocks the user, and then has to be diagnosed again is hours.

## When to invoke

Trigger this skill when **any** of the following is true:

- A previous fix attempt didn't resolve the symptom
- The symptom involves multiple layers (CDN, framework, backend, auth, network)
- Pattern-matching on the symptom produces more than one plausible cause
- The CEO has had to point out the bug exists more than once

If the cause is genuinely obvious (typo in a string, off-by-one in a loop), don't invoke this — just fix it. The skill is for the cases where you're tempted to guess.

## Process

### Step 1 — Capture the symptom

Write down, in this exact shape:

```
URL / endpoint:    <exact URL or command>
Action:            <what the user did>
Expected:          <what should have happened>
Observed:          <what actually happened>
Repro recipe:      <minimal steps that reproduce>
Surface evidence:  <screenshot URL, console output, response headers, logs>
```

If any field is "I'm not sure" — STOP and gather it before going further. Hypotheses built on a fuzzy symptom are guesses dressed up.

The minimum surface-evidence bar is stack-specific — see the appendix matching the bug's stack at the bottom of this skill (Web, Desktop). If your stack isn't listed, fall back to the general principle: capture what the system actually does at the moment of failure, not what it should do.

### Step 2 — Map the architecture

Before forming hypotheses, **read the relevant files**. Don't reason about what the code probably does; check.

The architecture-surface table is stack-specific — see the appendix at the bottom matching the bug's context. The general rule is: walk every layer the failing operation touches, from the user input down to the persistence/external boundary, and read the file that handles each layer's responsibility.

**Do not skip this step.** This is where the actual bug usually lives. Most "tricky" bugs are tricky because the agent reasoned about an imagined architecture instead of reading the real one.

### Step 3 — Hypothesis ladder

List 3–5 candidate causes, ordered by probability. For each, write the **specific evidence** that would prove or disprove it.

Format:

```
H1 (most likely):  <one-sentence cause>
   Evidence to confirm:    <command or observation that proves it>
   Evidence to refute:     <command or observation that proves it isn't this>

H2:  <one-sentence cause>
   Evidence to confirm:    ...
   Evidence to refute:     ...

H3:  ...
```

If you can't write a confirm-or-refute test for a hypothesis, it's not a hypothesis — it's a vibe. Replace it with one you can test, or drop it.

Common anti-pattern: "It might be a cache issue" — too vague. Replace with: "Browser has a cached 301 redirect for `/auth/callback` → `/auth/callback/` from a previous deploy state. Confirm by reproing in incognito; refute if the symptom persists in incognito."

### Step 4 — Gather evidence

Run the confirm test for H1 first. If it confirms → go to step 5. If it refutes → run the refute test, then move to H2.

The evidence-tests cookbook is stack-specific — see the appendix at the bottom matching the bug's context (Web, Desktop). Each table maps common hypothesis classes to the specific command or observation that confirms or refutes them.

**Critical**: the evidence test must be specific enough that "the test passed" actually rules out the hypothesis. "It looked right when I tested" doesn't count.

### Step 5 — Implement the fix

Only after step 4 confirms a hypothesis. The fix should:

- Target the verified mechanism, not adjacent code that "looks suspicious"
- Be the smallest change that addresses the confirmed root cause
- NOT bundle "while I'm here" improvements (those are separate PRs)

If you're tempted to fix two things in the same PR because "they're related" — split. The wrong-diagnosis cost is N times higher when multiple changes are in flight.

### Step 6 — Verify the fix against the original evidence

Re-run the **same evidence command** you used in step 4. If the original test was `curl -I https://staging.x.com/auth/callback/`, run that exact command again. Confirm:

- The status code changed in the expected direction
- The expected content is now served
- No new error appears in the chain

Unit tests passing is necessary but not sufficient — they verify code correctness, not feature correctness. A fix that passes tests but doesn't change the curl output didn't actually fix anything.

### Step 7 — Watch for compounding issues

After a fix lands, the next symptom often hides a second-order bug. Don't declare victory until:

- The user confirms the original repro recipe now works end-to-end
- No new error appears in browser DevTools / server logs
- The fix has been tested in **two distinct contexts** (different machine, different account, different browser) — the same-session cache can mask both successes AND failures

If the user reports a new symptom right after your fix, **do not treat it as a separate bug**. It's almost always a compounding issue from the same root cause or your fix's side effect. Re-enter step 1 with the new symptom.

## Output shape

A debug session run through this skill produces a single concise report:

```
DEBUG REPORT — <symptom summary> @ <date>

## Symptom
<filled in from step 1>

## Architecture surface
<bullet list of layers traversed in step 2 — file paths only, no narrative>

## Hypothesis ladder
H1 (chosen): <hypothesis> — confirmed by <evidence>
H2: <hypothesis> — refuted by <evidence>
H3: <hypothesis> — not tested (refuted by H1 confirmation)

## Fix
<file path>:<line>: <one-line summary of the change>

## Verification
<command run, before-output, after-output>

## Open follow-ups
<anything noticed that's NOT this bug but should be tracked>
```

Keep it under 30 lines. The discipline matters more than the documentation.

## Anti-patterns this skill prevents

| Anti-pattern | Example from real debug session |
|---|---|
| Hypothesis-then-fix without evidence | "Looks like a trailing-slash issue, let me set `trailingSlash: true`" — without verifying that `/auth/callback.html` was the file actually being requested |
| Pattern-match on URL shape | "URL ends with `/`, must be a trailing-slash routing problem" — without reading the SPA-fallback code that's the real handler |
| Multiple parallel fixes | Three sequential PRs chasing the same symptom because each was based on a different guess (no evidence test in between cycles) |
| Skipping the architecture read | Six round trips into "what does the server return?" before reading `not-found.tsx` for the first time |
| Declaring victory on unit-test pass | "All 101 tests pass" — but the actual repro still 404s in the browser |
| Treating compounding symptoms as separate bugs | "OK that fixed the 404, now there's a redirect loop" → file new ticket → repeat. Usually it's the same root cause |

## Relationship to other skills

| Skill | Use when |
|---|---|
| `/debug` (this skill) | A bug is resisting fixes; you need methodology |
| `/decide` | Picking between options that all work — different decision class |
| `/threat-model` / `/security-review` | The bug class is "is this exploitable?" not "why doesn't it work?" |
| `/code-review` (Rex agent) | Reviewing a finished PR, not investigating a live symptom |
| `/launch-check` | Auditing readiness across dimensions; not triaging a single bug |

## When NOT to use this skill

- **Simple bugs**: typos, missing imports, obvious off-by-ones. The methodology overhead exceeds the gain.
- **Greenfield exploration**: you're learning the codebase, not debugging a regression.
- **Architectural decisions**: use `/decide` and write an AgDR; debugging is for "it doesn't work", not "which approach should we take".
- **Performance investigation**: similar discipline, but the toolkit is different (profiles, traces, flamegraphs). A separate `/perf-debug` skill could be filed if the gap matters.

## Stack appendices

Each appendix carries the stack-specific surface-evidence requirements (step 1), architecture-surface map (step 2), and evidence-tests cookbook (step 4). The body of the skill stays methodology-only so it doesn't bloat as more stacks land.

### Web appendix

**Minimum surface evidence (step 1).** Don't proceed without these:

- `curl -I` of the failing URL — response status + Location header
- Browser DevTools Network tab redirect chain — every status code and Location header from the user action to the visible failure
- Browser DevTools Console — any errors, including the stack trace
- The exact URL in the address bar at the moment of failure (often differs from what the user typed — note both)

**Architecture-surface map (step 2).** Read the file at every layer the request touches:

| Layer | What to read | What you're looking for |
|---|---|---|
| Browser routing | The page component for the URL path | Component logic, redirects, error boundaries |
| App framework | `next.config.*`, `nuxt.config.*`, `vite.config.*` | Build mode (SSR/SSG/SPA), trailingSlash, basePath |
| App router fallback | `not-found.*`, `404.*`, custom error pages | Whether the app catches 404s itself and re-routes (this was the missed layer in the originating session) |
| CDN | `infrastructure/**/cdn/**/*.tf`, CloudFront/Vercel/Netlify config | Custom error responses, rewrites, redirect rules |
| Origin | S3 bucket policy, web host index document | What gets served when the path doesn't exist literally |
| API client | The shared `fetch` wrapper / api-client.ts | Auth-header injection, 401-redirect, retry logic |
| Backend handler | The handler the page calls | What status codes it returns and when |
| Auth | The auth provider's config + the token-validation code | Where session reads happen and what triggers a redirect |

**Evidence-tests cookbook (step 4).**

| Hypothesis class | Evidence test |
|---|---|
| Server returns wrong status | `curl -I <url>` and read the HTTP code + Location header |
| File missing from origin | `aws s3 ls s3://bucket/<path>` (or platform-equivalent) |
| CDN cache stale | `curl -I` and check `x-cache: Hit/Miss/Error from cloudfront`; force cache miss with a query-string buster |
| Redirect loop | `curl -L --max-redirs 10 -v` and read the redirect chain |
| Wrong content served | `curl <url>` and grep for distinctive strings (something only the expected page has, something only the unexpected page has) |
| Client-side error | Browser DevTools console — actual error message and stack trace |
| Missing route in route table | `grep` for the route name in the router config / route manifest |
| Auth header missing | Browser DevTools network tab → request headers → `Authorization` |
| Token not stored | DevTools → Application → Local Storage / Session Storage — check the keys the auth lib uses |
| Env var unset at build | Read the build log for the relevant `NEXT_PUBLIC_*` / `VITE_*` value |
| CORS rejection | Network tab shows preflight `OPTIONS` returning 4xx, or response missing `Access-Control-Allow-*` headers |
| State lost between tabs | Reproduce in a single tab end-to-end vs. the original flow that crossed tabs |

### Desktop appendix

Covers Electron / Tauri (web tech in a native shell) and native (Swift/Cocoa, .NET/Win32, GTK/Qt). For Electron and Tauri, the renderer process is essentially a web app — use the Web appendix for renderer-side bugs and this appendix for everything that crosses the native boundary.

**Minimum surface evidence (step 1).** Don't proceed without these:

- The exact reproduce sequence (which window, which menu item, which IPC call)
- Crash log if the app crashed (Console.app → Crash Reports on macOS, Event Viewer → Application on Windows, `journalctl --user` on Linux)
- App's own log file — most desktop apps log to a known path (`~/Library/Logs/<App>` on macOS, `%APPDATA%\<App>\logs` on Windows, `~/.local/state/<App>/` or stdout on Linux)
- Build/version info — `<App>.app/Contents/Info.plist` (macOS), `<App>.exe` properties (Windows), so you know what code is actually running
- For sandbox / permission issues: the entitlements (macOS: `codesign -d --entitlements - <App>.app`) or manifest capabilities (Windows AppX)

**Architecture-surface map (step 2).** Read the file at every layer the failing operation touches:

| Layer | What to read | What you're looking for |
|---|---|---|
| App entry point | `main.ts` (Electron), `src-tauri/src/main.rs` (Tauri), `AppDelegate.swift` (macOS), `Program.cs` / `App.xaml.cs` (Windows) | Initialization order, lifecycle hooks (`willFinishLaunching`, `applicationDidFinishLaunching`) |
| Window / view | The window creation code (Electron `BrowserWindow`, Tauri `tauri::Builder`, native window controllers) | preload scripts, `webPreferences`, content security policy, navigation guards |
| IPC bridge | Electron `ipcMain` / `ipcRenderer` handlers, Tauri commands (`#[tauri::command]`), native XPC / COM definitions | Channel names, message shape, error propagation, async vs sync |
| Renderer / UI thread | The component the user interacted with | Same as web for Electron/Tauri; AppKit/SwiftUI/WinUI/Qt view code for native |
| Native modules | `package.json` `dependencies` for `*-native`, `node-gyp` builds, `.dylib` / `.dll` / `.so` paths | Whether the binary is signed, ABI-compatible, present at runtime |
| App lifecycle | `app.on('ready')`, `app.on('quit')`, etc. | Resource cleanup, save-on-quit, sleep/wake behavior |
| File-system / sandbox | macOS App Sandbox container path (`~/Library/Containers/<bundle-id>/`), Windows AppData paths, entitlements / capabilities | Whether the app can actually read/write the path it's hitting |
| Auto-updater | Squirrel.Mac / Squirrel.Windows / Sparkle / Tauri updater configuration | Update feed URL, signature key, update phase the failure happens in |
| Crash reporter | Sentry / Bugsnag SDK init, OS crash-dump configuration | Whether crashes are even being captured |
| Network | Same as web — use the Web appendix for HTTPS calls; add the platform's network proxy if relevant (Charles, Proxyman, Wireshark) | |
| Code signing / notarization | macOS `codesign -dv <App>.app`, `spctl -a -vv <App>.app`, Windows `signtool verify /pa <exe>` | Signature validity, notarization status (macOS Gatekeeper) |

**Evidence-tests cookbook (step 4).**

| Hypothesis class | Evidence test |
|---|---|
| Crash on launch | Console.app (macOS) / Event Viewer (Windows) / `journalctl --user -e` (Linux), filtered by app bundle id; look for `Termination Reason`, `Exception Type`, signal name |
| App won't open at all | macOS: `spctl -a -vv <App>.app` (Gatekeeper), `codesign -dv <App>.app` (signature); Windows: SmartScreen prompt, signature on .exe properties |
| Sandbox-denied file access | macOS: tail `~/Library/Logs/DiagnosticReports/Sandbox-*` and `log stream --predicate 'subsystem == "com.apple.sandbox"'`; check `codesign -d --entitlements - <App>.app` for the right entitlement |
| Native module won't load | macOS: `otool -L <binary>` (missing dylibs, wrong arch); Windows: Dependency Walker / `dumpbin /dependents`; Linux: `ldd <binary>` |
| IPC message lost | Add a log on both ends (main + renderer or host + extension); compare timestamps; check channel names match exactly |
| Auto-update fails | Read updater logs (Squirrel: `~/Library/Caches/Squirrel/Logs/`, Sparkle: app's own logs, Tauri: same); verify code-signing key matches between current app and update bundle |
| Hang on quit | macOS: `sample <pid> 5 -file /tmp/sample.txt` then read for stuck threads; Windows: WinDbg attach + `~*kn` for thread stacks |
| Memory leak | Instruments (macOS Allocations / Leaks template); Windows perfmon; live `Activity Monitor` / Task Manager during repro |
| Wrong version installed | `<App>.app/Contents/Info.plist` `CFBundleShortVersionString`; Windows: file properties → Details → Product version. Compare to expected build artifact |
| Network call fails inside the app but works in browser | Charles/Proxyman: route the app through a proxy and inspect TLS handshake; suspect ATS (App Transport Security) on macOS / cert store on Windows |
| Renderer JS error in Electron/Tauri | Open DevTools in the running app (Electron: `Cmd+Opt+I` if enabled, Tauri: `tauri dev`); use the Web appendix tests from there |
| Native crash with `EXC_BAD_ACCESS` / `0xC0000005` | Symbolicated crash log (`atos` on macOS, WinDbg `!analyze -v` on Windows); look at the thread that crashed for stack trace |
| Permission prompt skipped | macOS: TCC database (`tccutil reset <service> <bundle-id>` to re-prompt); Windows: capabilities in app manifest |
| Different behavior in dev vs packaged | Compare entitlements + signing between `npm run dev` build and `npm run package` build; the dev build often has wider entitlements implicitly |

## Notes for skill maintainers

The methodology body is portable across stacks. The appendices are where stack-specific knowledge accumulates.

When to add a new appendix:

- A debug session in a new stack class (mobile, backend service, CLI tool, data pipeline) produces a useful evidence-tests pattern
- The user reports the existing appendices don't cover their stack and the gap is concrete

When updating an existing appendix:

- New evidence-test pattern proven useful in a real session — append to the cookbook table and mention the originating session in the commit message
- A row points at deprecated tooling — replace with the current best tool, don't keep both

Don't add an appendix until you have a real session's worth of patterns to seed it. A speculative "Mobile" appendix with three half-formed rows is worse than no Mobile appendix.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
