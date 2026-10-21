#!/bin/bash
# #1780 (AgDR-0262): quoted-heredoc routing and timing in the dispatcher.
# The #1772 redirect cases live in test_git_redirect_1772.sh.
# Fixture bodies are built in Python. They are never built by a Bash
# heredoc that names push or commit verbs (that is the bug under test).
set -eu
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
HOOKS="$ROOT/.claude/hooks"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d)
scratch=""
trap 'rm -rf "$TMP" "${scratch:-}"' EXIT

python3 - "$TMP" "$HOOKS" "$ROOT" <<'PY'
import collections, json, os, pathlib, re, shutil, subprocess, sys, tempfile, time

tmp, hooks, root = map(pathlib.Path, sys.argv[1:4])
pass_n = fail_n = 0
def ok(msg):
    global pass_n; pass_n += 1; print("PASS:", msg, flush=True)
def bad(msg):
    global fail_n; fail_n += 1; print("FAIL:", msg, flush=True)

# --- build fixtures without naming verbs on a parent shell command line ---
verb_push = "push"
verb_commit = "commit"
kw_chunk = (
    f"Review note: remember to run git {verb_push} after git {verb_commit}. "
    "Also see gh pr create and gh pr merge in the docs. "
)
kw_body = ""
while len(kw_body) < 16384:
    kw_body += kw_chunk
kw_body = kw_body[:16384]
plain_body = ("lorem ipsum dolor sit amet. " * 800)[:16384]

def heredoc_cmd(body, quoted=True):
    delim = "'EOF'" if quoted else "EOF"
    return f"cat > /tmp/x.md <<{delim}\n{body}\nEOF"

kw_cmd = heredoc_cmd(kw_body, quoted=True)
plain_cmd = heredoc_cmd(plain_body, quoted=True)
unquoted_cmd = heredoc_cmd(
    f"please git {verb_push} origin feature/GH-1805-x later", quoted=False
)
here_string_cmd = f'wc -l <<< "git {verb_push} origin feature/GH-1805-x"'

# Real push after cd + quoted heredoc (negative: gates must still fire).
real_push_cmd = (
    f"cd /tmp; cat > /tmp/x.md <<'EOF'\n"
    f"prose about git {verb_push} origin main\n"
    f"EOF\n"
    f"git {verb_push} origin feature/GH-1805-x"
)

(tmp / "kw.json").write_text(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": kw_cmd},
    "cwd": str(tmp),
}))
(tmp / "plain.json").write_text(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": plain_cmd},
    "cwd": str(tmp),
}))
(tmp / "real.json").write_text(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": real_push_cmd},
    "cwd": str(tmp),
}))
(tmp / "unquoted.json").write_text(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": unquoted_cmd},
    "cwd": str(tmp),
}))
(tmp / "herestring.json").write_text(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": here_string_cmd},
    "cwd": str(tmp),
}))

# Fail-before: archive the hooks tree at a pinned dev commit. The pin is the
# dev commit before #1780 (the #1835 squash). A squash merge keeps it on
# dev. HEREDOC_1780_BASE_REF overrides the pin.
FAIL_BEFORE_PIN = "defd0597094d80e72e366de76bf62127410fea98"
base_ref = os.environ.get("HEREDOC_1780_BASE_REF") or FAIL_BEFORE_PIN
fb_note = ""
have = subprocess.run(
    ["git", "-C", str(root), "rev-parse", "--verify", "--quiet",
     base_ref + "^{commit}"],
    check=False, capture_output=True, text=True,
)
base_hooks = None
if have.returncode != 0:
    # Shallow CI clones can miss the pinned commit.
    fb_note = f"pinned base {base_ref} is not in this clone"
else:
    # Inside tmp, so the shell EXIT trap removes it.
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="heredoc-1780-base-", dir=str(tmp)))
    archive = subprocess.check_output(
        ["git", "archive", base_ref, ".claude/hooks"], cwd=root
    )
    subprocess.run(["tar", "-x", "-C", str(scratch)], input=archive, check=True)
    base_hooks = scratch / ".claude/hooks"
    disp = base_hooks / "dispatch-bash.sh"
    if not disp.is_file():
        fb_note = "no base dispatch-bash.sh"
    elif "_lib-strip-heredoc.sh" in disp.read_text():
        # The base already has the fix, so it cannot show the old timeout.
        fb_note = f"base {base_ref} already strips quoted heredocs"

def run_dispatch(hooks_dir, payload_path, locale="en_US.UTF-8", timeout=20):
    env = dict(os.environ)
    env["LC_ALL"] = locale
    env["PATH"] = str(tmp / "bin") + os.pathsep + env.get("PATH", "")
    p = subprocess.Popen(
        ["/bin/bash", str(hooks_dir / "dispatch-bash.sh")],
        stdin=open(payload_path, "r"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=str(tmp),
        env=env,
        start_new_session=True,
    )
    try:
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out + err, None
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, 9)
        out, err = p.communicate()
        return 124, (out or "") + (err or ""), "timeout"

# Stub always-on hooks. Keep real push/commit gates so timing and routing
# exercise git_visit_invocations. Real _lib-* files stay from src_hooks.
def make_dispatch_tree(src_hooks, label, stub_gates=False):
    dest = tmp / label
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src_hooks, dest)
    always = [
        "block-protected-target-writes.sh",
        "block-ambient-tracker-repo.sh", "block-privileged-escalation.sh",
        "require-skill-for-issue-create.sh", "require-orbit-slice-for-ticket.sh",
        "require-migration-ticket.sh", "require-active-ticket.sh",
        "warn-review-marker-write.sh", "warn-isolated-build-risk.sh",
        "block-reviewer-repo-mutation.sh", "block-reviewer-ci-wait.sh",
        "block-forged-menu-approval.sh", "block-git-add-all.sh",
        "suggest-ticket-template.sh", "validate-issue-structure.sh",
        "block-private-refs-in-public-repos.sh", "validate-pr-create.sh",
        "require-agdr-for-arch-pr.sh", "nudge-control-adversarial-test.sh",
        "block-unreviewed-merge.sh", "require-design-review-for-ui.sh",
        "block-merge-on-red-ci.sh", "require-architecture-review.sh",
        "detect-role-trigger.sh",
    ]
    gates = [
        "block-main-push.sh", "validate-branch-name.sh", "pre-push-gate.sh",
        "block-agent-routing-drift.sh", "check-secrets.sh",
        "block-onboarding-in-git.sh", "verify-commit-refs.sh",
        "validate-commit-format.sh", "require-agdr-for-arch-changes.sh",
        "warn-bootstrap-scope.sh",
    ]
    # Always-on stubs must exit 0 without requiring DISPATCH_LOG (timing runs).
    always_stub = '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n'
    gate_stub = (
        '#!/usr/bin/env bash\nset -euo pipefail\ncat >/dev/null\n'
        'printf \'%s\\n\' "$(basename "$0")" >> "${DISPATCH_LOG:?}"\n'
    )
    for name in always:
        path = dest / name
        path.write_text(always_stub)
        path.chmod(0o755)
    if stub_gates:
        for name in gates:
            path = dest / name
            path.write_text(gate_stub)
            path.chmod(0o755)
    return dest

(tmp / "bin").mkdir(exist_ok=True)
bash_link = tmp / "bin" / "bash"
if not bash_link.exists():
    bash_link.symlink_to("/bin/bash")

# Timing trees keep real push/commit gates. Routing trees stub the gates
# so DISPATCH_LOG shows which groups ran.
new_time = make_dispatch_tree(hooks, "new-time", stub_gates=False)
new_route = make_dispatch_tree(hooks, "new-route", stub_gates=True)

# Fail-before: 16KB keyword body times out or exceeds 3s / falsely blocks.
if fb_note:
    print(f"NOTE: skip fail-before: {fb_note}", flush=True)
else:
    base_time = make_dispatch_tree(base_hooks, "base-time", stub_gates=False)
    t0 = time.perf_counter()
    rc, out, note = run_dispatch(base_time, tmp / "kw.json", "en_US.UTF-8", timeout=25)
    base_dt = time.perf_counter() - t0
    base_bad = (rc == 124) or (base_dt > 3.0) or (rc == 2)
    if base_bad:
        ok(f"fail-before kw 16KB base_dt={base_dt:.3f}s rc={rc} note={note}")
    else:
        bad(f"fail-before expected slow/block; base_dt={base_dt:.3f}s rc={rc} out={out[:200]!r}")

# After-fix timing under UTF-8 and C (real gates; prose must not block).
# One warm-up run, then three timed runs. Every timed sample must be <= 3s.
for locale in ("en_US.UTF-8", "C"):
    run_dispatch(new_time, tmp / "kw.json", locale, timeout=20)
    times = []
    last_rc = 0
    out = ""
    timed_ok = True
    for _ in range(3):
        t0 = time.perf_counter()
        rc, out, note = run_dispatch(new_time, tmp / "kw.json", locale, timeout=20)
        last_rc = rc
        dt = time.perf_counter() - t0
        times.append(dt)
        if note == "timeout" or dt > 3.0 or rc != 0:
            timed_ok = False
            break
    if timed_ok:
        ok(f"kw 16KB {locale} times={['%.3f'%t for t in times]} max={max(times):.3f}s rc={last_rc}")
    else:
        bad(f"kw 16KB {locale} times={['%.3f'%t for t in times]} rc={last_rc} (want each <=3s, rc=0) out={(out or '')[:240]!r}")

# Prose mention must not route push gates (log has no block-main-push).
log = tmp / "log-prose"
log.write_text("")
env = dict(os.environ, DISPATCH_LOG=str(log), PATH=str(tmp / "bin") + os.pathsep + os.environ.get("PATH", ""))
subprocess.run(
    ["/bin/bash", str(new_route / "dispatch-bash.sh")],
    input=(tmp / "kw.json").read_text(),
    text=True,
    capture_output=True,
    cwd=str(tmp),
    env=env,
    check=False,
)
log_txt = log.read_text()
if "block-main-push.sh" in log_txt or "check-secrets.sh" in log_txt:
    bad("prose quoted heredoc must not route push/commit gates")
else:
    ok("prose quoted heredoc does not route push/commit gates")

# Negative: real push after cd + heredoc reaches every push gate.
log = tmp / "log-real"
log.write_text("")
env["DISPATCH_LOG"] = str(log)
subprocess.run(
    ["/bin/bash", str(new_route / "dispatch-bash.sh")],
    input=(tmp / "real.json").read_text(),
    text=True,
    capture_output=True,
    cwd=str(tmp),
    env=env,
    check=False,
)
log_txt = log.read_text()
needed = [
    "block-main-push.sh", "validate-branch-name.sh", "pre-push-gate.sh",
    "block-agent-routing-drift.sh",
]
missing = [n for n in needed if n not in log_txt]
if missing:
    bad("real push after heredoc missing gates: " + ",".join(missing))
else:
    ok("real push after cd+heredoc reaches push gates")

# Unquoted heredoc: still routes (current checks) when body names the verb.
log = tmp / "log-unquoted"
log.write_text("")
env["DISPATCH_LOG"] = str(log)
subprocess.run(
    ["/bin/bash", str(new_route / "dispatch-bash.sh")],
    input=(tmp / "unquoted.json").read_text(),
    text=True,
    capture_output=True,
    cwd=str(tmp),
    env=env,
    check=False,
)
if "block-main-push.sh" in log.read_text():
    ok("unquoted heredoc still routes push gates")
else:
    bad("unquoted heredoc still routes push gates")

# Here-string: still routes.
log = tmp / "log-hs"
log.write_text("")
env["DISPATCH_LOG"] = str(log)
subprocess.run(
    ["/bin/bash", str(new_route / "dispatch-bash.sh")],
    input=(tmp / "herestring.json").read_text(),
    text=True,
    capture_output=True,
    cwd=str(tmp),
    env=env,
    check=False,
)
if "block-main-push.sh" in log.read_text():
    ok("here-string still routes push gates")
else:
    bad("here-string still routes push gates")

# A quoted body that a shell, eval or source runs is code, not data.
# Each shape must still reach the push gates (#1805 rebase onto #1804 r4).
real_push = f"git {verb_push} origin feature/GH-1805-x"
runner_shapes = [
    ("fed-bash", f"bash <<'EOF'\ncd /tmp && {real_push}\nEOF"),
    ("fed-sh-s", f"/bin/sh -s <<'EOF'\n{real_push}\nEOF"),
    ("eval-subst", f"eval \"$(cat <<'EOF'\n{real_push}\nEOF\n)\""),
    ("eval-var", f"x=$(cat <<'EOF'\n{real_push}\nEOF\n); eval \"$x\""),
    ("source-stdin", f"source /dev/stdin <<'EOF'\n{real_push}\nEOF"),
    ("dot-stdin", f". /dev/stdin <<'EOF'\n{real_push}\nEOF"),
]
runner_bad = []
for label, cmd in runner_shapes:
    payload = tmp / f"runner-{label}.json"
    payload.write_text(json.dumps({
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "cwd": str(tmp),
    }))
    log = tmp / f"log-runner-{label}"
    log.write_text("")
    env["DISPATCH_LOG"] = str(log)
    subprocess.run(
        ["/bin/bash", str(new_route / "dispatch-bash.sh")],
        input=payload.read_text(),
        text=True,
        capture_output=True,
        cwd=str(tmp),
        env=env,
        check=False,
    )
    if "block-main-push.sh" not in log.read_text():
        runner_bad.append(label)
if runner_bad:
    bad("quoted body run by a shell/eval/source must route push gates: " + ",".join(runner_bad))
else:
    ok(f"quoted body run by a shell/eval/source routes push gates ({len(runner_shapes)} shapes)")

# #1805 B1 (CEO decision 2026-10-20): quoted mode strips a body only for an
# allow-listed data sink. Every other receiver keeps the raw command, so the
# push gates still see the body. Placeholder shapes, one per class.
w_sys = "sys" + "tem"
w_dot = "."
b1_shapes = [
    ("other-shell-tcsh", f"tcsh <<'EOF'\n{real_push}\nEOF"),
    ("other-shell-csh-s", f"/bin/csh -s <<'EOF'\n{real_push}\nEOF"),
    ("other-shell-fish", f"fish <<'EOF'\n{real_push}\nEOF"),
    ("interp-python", f"python3 - <<'EOF'\nimport os\nos.{w_sys}('{real_push}')\nEOF"),
    ("interp-perl", f"perl <<'EOF'\n{w_sys}('{real_push}');\nEOF"),
    ("interp-ruby", f"ruby <<'EOF'\n{w_sys}('{real_push}')\nEOF"),
    ("interp-node", f"node <<'EOF'\nrequire('child_process').execSync('{real_push}')\nEOF"),
    ("dot-in-if-then", f"if true; then {w_dot} /dev/stdin <<'EOF'\n{real_push}\nEOF\nfi"),
    ("dot-in-while-do", f"while true; do {w_dot} /dev/stdin <<'EOF'\n{real_push}\nEOF\nbreak; done"),
    ("backslash-dot", f"\\{w_dot} /dev/stdin <<'EOF'\n{real_push}\nEOF"),
    ("quoted-dot", f"'{w_dot}' /dev/stdin <<'EOF'\n{real_push}\nEOF"),
    ("shell-var-s", f"\"$SHELL\" -s <<'EOF'\n{real_push}\nEOF"),
    ("backslash-split-shell", f"ba\\sh <<'EOF'\n{real_push}\nEOF"),
    ("quote-split-shell", f"b''ash <<'EOF'\n{real_push}\nEOF"),
    ("script-written-then-run", f"cat > /tmp/s1805.sh <<'EOF'\n{real_push}\nEOF\nbash /tmp/s1805.sh"),
    ("script-written-then-exec", f"cat > /tmp/s1805.sh <<'EOF'\n{real_push}\nEOF\nchmod +x /tmp/s1805.sh && /tmp/s1805.sh"),
    ("tee-then-run", f"tee /tmp/s1805.sh <<'EOF'\n{real_push}\nEOF\nsh /tmp/s1805.sh"),
    ("pipe-into-shell", f"cat <<'EOF' | sh\n{real_push}\nEOF"),
    ("group-piped", f"{{ cat <<'EOF'\n{real_push}\nEOF\n}} | bash"),
    ("function-cat", f"cat() {{ bash; }}; cat <<'EOF'\n{real_push}\nEOF"),
    ("xargs", f"xargs -0 bash -c <<'EOF'\n{real_push}\nEOF"),
    ("env-wrapper", f"env bash <<'EOF'\n{real_push}\nEOF"),
]
b1_bad = []
for label, cmd in b1_shapes:
    payload = tmp / f"b1-{label}.json"
    payload.write_text(json.dumps({
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "cwd": str(tmp),
    }))
    log = tmp / f"log-b1-{label}"
    log.write_text("")
    env["DISPATCH_LOG"] = str(log)
    subprocess.run(
        ["/bin/bash", str(new_route / "dispatch-bash.sh")],
        input=payload.read_text(),
        text=True,
        capture_output=True,
        cwd=str(tmp),
        env=env,
        check=False,
    )
    if "block-main-push.sh" not in log.read_text():
        b1_bad.append(label)
if b1_bad:
    bad("non-sink receiver must route push gates: " + ",".join(b1_bad))
else:
    ok(f"non-sink receivers route push gates ({len(b1_shapes)} shapes)")

# Allow-listed data sinks: a prose body that names a push does not route the
# push gates. Each sink has a block twin that must still route them.
prose = f"Review note: run {real_push} after the merge."
w_gh = "g" + "h"
sink_pairs = [
    ("cat-redirect",
     f"cat > /tmp/r1805.md <<'EOF'\n{prose}\nEOF",
     f"cat > /tmp/r1805.md <<'EOF'\n{real_push}\nEOF\nsh /tmp/r1805.md"),
    ("cat-append",
     f"cat >> /tmp/r1805.md <<'EOF'\n{prose}\nEOF",
     f"cat >> /tmp/r1805.md <<'EOF'\n{real_push}\nEOF\n. /tmp/r1805.md"),
    ("cat-pipe-tee",
     f"cat <<'EOF' | tee -a /tmp/r1805.md\n{prose}\nEOF",
     f"cat <<'EOF' | tee /tmp/r1805.md | sh\n{real_push}\nEOF"),
    ("tee-file",
     f"tee /tmp/a1805.md <<'EOF'\n{prose}\nEOF",
     f"tee >(sh) <<'EOF'\n{real_push}\nEOF"),
    ("host-body-file",
     f"{w_gh} pr comment 1 --body-file - <<'EOF'\n{prose}\nEOF",
     f"{w_gh} pr comment 1 --body-file - <<'EOF'\n{real_push}\nEOF\n{w_gh} pr view 1 --json body -q .body | sh"),
    ("host-dash-F",
     f"{w_gh} issue comment 1 -F - <<'EOF'\n{prose}\nEOF",
     f"{w_gh} alias-x 1 -F - <<'EOF'\n{real_push}\nEOF"),
    ("git-commit-F",
     f"git {verb_commit} -F - <<'EOF'\nfeat(#1805): note\n\n{prose}\nEOF",
     f"git -c core.editor=sh {verb_commit} -e -F - <<'EOF'\n{real_push}\nEOF"),
    ("git-notes-F",
     f"git notes add -F - <<'EOF'\n{prose}\nEOF",
     f"git notes edit <<'EOF'\n{real_push}\nEOF"),
]
sink_bad = []
for label, allow_cmd, twin_cmd in sink_pairs:
    for kind, cmd in (("allow", allow_cmd), ("twin", twin_cmd)):
        payload = tmp / f"sink-{label}-{kind}.json"
        payload.write_text(json.dumps({
            "tool_name": "Bash",
            "tool_input": {"command": cmd},
            "cwd": str(tmp),
        }))
        log = tmp / f"log-sink-{label}-{kind}"
        log.write_text("")
        env["DISPATCH_LOG"] = str(log)
        subprocess.run(
            ["/bin/bash", str(new_route / "dispatch-bash.sh")],
            input=payload.read_text(),
            text=True,
            capture_output=True,
            cwd=str(tmp),
            env=env,
            check=False,
        )
        routed = "block-main-push.sh" in log.read_text()
        if (kind == "allow" and routed) or (kind == "twin" and not routed):
            sink_bad.append(f"{label}-{kind}")
if sink_bad:
    bad("data-sink allow / twin routing: " + ",".join(sink_bad))
else:
    ok(f"data sinks strip prose and block twins route ({len(sink_pairs)} pairs)")

# Allow twin: runner words only inside the quoted prose body do not route.
twin_cmd = (
    "cat > /tmp/notes.md <<'EOF'\n"
    f"run bash or sh, then eval and source, then {real_push}\n"
    "EOF"
)
(tmp / "runner-twin.json").write_text(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": twin_cmd},
    "cwd": str(tmp),
}))
log = tmp / "log-runner-twin"
log.write_text("")
env["DISPATCH_LOG"] = str(log)
subprocess.run(
    ["/bin/bash", str(new_route / "dispatch-bash.sh")],
    input=(tmp / "runner-twin.json").read_text(),
    text=True,
    capture_output=True,
    cwd=str(tmp),
    env=env,
    check=False,
)
if "block-main-push.sh" in log.read_text():
    bad("runner words inside quoted prose must not route push gates")
else:
    ok("runner words inside quoted prose do not route push gates")

# #1829 B1: an earlier heredoc on the start line whose delimiter the
# pattern does not match (a digit or an escaped name). The text between the
# two `<<` must not be lost. A1: a cat or tee target in a hooks directory
# keeps the raw command. Each case must route its gate; the allow twin not.
real_commit = f"git {verb_commit} -m wip"
q = "'"
def route_log(cmd, tag):
    (tmp / f"{tag}.json").write_text(json.dumps({
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "cwd": str(tmp),
    }))
    lg = tmp / f"log-{tag}"
    lg.write_text("")
    env["DISPATCH_LOG"] = str(lg)
    subprocess.run(
        ["/bin/bash", str(new_route / "dispatch-bash.sh")],
        input=(tmp / f"{tag}.json").read_text(),
        text=True,
        capture_output=True,
        cwd=str(tmp),
        env=env,
        check=False,
    )
    return lg.read_text()
hid_shapes = [
    ("digit-push", f"cat <<1; {real_push}; cat <<{q}EOF{q}\n1\nhello\nEOF", "block-main-push.sh"),
    ("escaped-push", f"cat <<\\X; {real_push}; cat <<{q}EOF{q}\nX\nhello\nEOF", "block-main-push.sh"),
    ("digit-commit", f"cat <<1; {real_commit}; cat <<{q}EOF{q}\n1\nhello\nEOF", "validate-commit-format.sh"),
    ("escaped-commit", f"cat <<\\X; {real_commit}; cat <<{q}EOF{q}\nX\nhello\nEOF", "validate-commit-format.sh"),
    ("husky-target", f"cat > .husky/pre-push <<{q}EOF{q}\n{real_push}\nEOF", "block-main-push.sh"),
    ("githooks-tee", f"tee .githooks/pre-push <<{q}EOF{q}\n{real_push}\nEOF", "block-main-push.sh"),
    # N1: a later command reads the written file by an implicit name.
    ("make", f"cat > Makefile <<{q}EOF{q}\nall:\n\t{real_push}\nEOF\nmake", "block-main-push.sh"),
    ("npm", f"cat > package.json <<{q}EOF{q}\n{{\"scripts\": {{\"test\": \"{real_push}\"}}}}\nEOF\nnpm test", "block-main-push.sh"),
    ("zshenv", f"cat >> ~/.zshenv <<{q}EOF{q}\n{real_push}\nEOF\nzsh -c true", "block-main-push.sh"),
    ("tee-make", f"tee Makefile <<{q}EOF{q}\nall:\n\t{real_push}\nEOF\nmake all", "block-main-push.sh"),
    ("bashrc", f"cat >> ~/.bashrc <<{q}EOF{q}\n{real_push}\nEOF\nbash -i", "block-main-push.sh"),
    ("githooks-commit", f"cat > .githooks/pre-commit <<{q}EOF{q}\n{real_push}\nEOF\n{real_commit}", "block-main-push.sh"),
    ("husky-commit", f"cat > .husky/pre-commit <<{q}EOF{q}\n{real_push}\nEOF\n{real_commit}", "block-main-push.sh"),
]
hid_bad = [lb for lb, cmd, gate in hid_shapes if gate not in route_log(cmd, f"hid-{lb}")]
if hid_bad:
    bad("earlier heredoc / hooks target must route gates: " + ",".join(hid_bad))
else:
    ok(f"earlier heredoc and hooks targets route gates ({len(hid_shapes)} shapes)")
# CEO decision, 2026-10-20: strip only for a single-command data sink.
# Allow twins: one sink and nothing else in the command.
hid_allows = [
    ("one-sink", f"cat <<{q}A{q} > /tmp/h1829.md\n{prose}\nA"),
    ("cat-notes", f"cat > notes.md <<{q}EOF{q}\n{prose}\nEOF"),
    ("gh-comment", f"{w_gh} pr comment 1829 --body-file - <<{q}EOF{q}\n{prose}\nEOF"),
    ("commit-F", f"git {verb_commit} -F - <<{q}EOF{q}\nfix(#1829): note\n\n{prose}\nEOF"),
]
allow_bad = [lb for lb, cmd in hid_allows if "block-main-push.sh" in route_log(cmd, f"hid-allow-{lb}")]
if allow_bad:
    bad("allow twins must not route push gates: " + ",".join(allow_bad))
else:
    ok(f"allow twins do not route push gates ({len(hid_allows)} shapes)")

# #1829 B1b: a line continuation splits an earlier heredoc operator over
# two lines. Bash removes the backslash-newline, so `<\<newline><1` is
# `<<1`, and the push or commit after its terminator runs. The stripper
# must keep the raw command. The allow twins have no continuation in the
# visible text (a backslash at the end of a body line is data).
bs = "\\"
cont_shapes = [
    ("cont-push", f"cat <{bs}\n<1\ncat <<{q}EOF{q}\n1\n{real_push}\nEOF", "block-main-push.sh"),
    ("cont-commit", f"cat <{bs}\n<1\ncat <<{q}EOF{q}\n1\n{real_commit}\nEOF", "validate-commit-format.sh"),
    ("cont-logical-line", f"cat <<1 {bs}\n<<{q}EOF{q}\n{real_push}\n1\nhello\nEOF", "block-main-push.sh"),
    ("cont-before-sink", f"cat {bs}\n> /tmp/c1829.md <<{q}EOF{q}\n{real_push}\nEOF", "block-main-push.sh"),
]
cont_bad = [lb for lb, cmd, gate in cont_shapes if gate not in route_log(cmd, f"b1b-{lb}")]
if cont_bad:
    bad("line continuation before a stripped heredoc must route gates: " + ",".join(cont_bad))
else:
    ok(f"line continuation before a stripped heredoc routes gates ({len(cont_shapes)} shapes)")
cont_allows = [
    ("no-continuation", f"cat <<{q}EOF{q} > /tmp/c1829.md\n{prose}\nEOF"),
    ("body-backslash", f"cat > /tmp/c1829.md <<{q}EOF{q}\nline one {bs}\n{prose}\nEOF"),
]
cont_allow_bad = [lb for lb, cmd in cont_allows if "block-main-push.sh" in route_log(cmd, f"b1b-allow-{lb}")]
if cont_allow_bad:
    bad("sinks with no visible continuation must not route push gates: " + ",".join(cont_allow_bad))
else:
    ok(f"sinks with no visible continuation do not route push gates ({len(cont_allows)} shapes)")

# #1829 A3: the hooks-path check reads the target's repo and the current
# repo, expands a leading `~`, and keeps the raw command when a configured
# hooks path does not resolve. Fixture repos live in tmp. Git config is
# hermetic: an empty global file and no system file.
a3 = tmp / "a3"
a3_home = a3 / "home"
(a3_home / "hk").mkdir(parents=True)
a3_gcfg = a3 / "gitconfig"
a3_gcfg.write_text("")
a3_env = dict(env, HOME=str(a3_home), GIT_CONFIG_GLOBAL=str(a3_gcfg), GIT_CONFIG_NOSYSTEM="1")
def a3_repo(name, hooks_path, mkdir_hooks=None):
    r = a3 / name
    subprocess.run(["git", "init", "-q", str(r)], check=True, env=a3_env)
    subprocess.run(["git", "-C", str(r), "config", "core.hooksPath", hooks_path], check=True, env=a3_env)
    if mkdir_hooks:
        (r / mkdir_hooks).mkdir(parents=True, exist_ok=True)
    return r
def route_log_in(cmd, tag, cwd, extra=None):
    (tmp / f"{tag}.json").write_text(json.dumps({
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "cwd": str(cwd),
    }))
    lg = tmp / f"log-{tag}"
    lg.write_text("")
    e = dict(a3_env, DISPATCH_LOG=str(lg), **(extra or {}))
    subprocess.run(
        ["/bin/bash", str(new_route / "dispatch-bash.sh")],
        input=(tmp / f"{tag}.json").read_text(),
        text=True,
        capture_output=True,
        cwd=str(cwd),
        env=e,
        check=False,
    )
    return lg.read_text()
r_tilde = a3_repo("tilde", "~/hk")
r_missing = a3_repo("missing", "no-such-hooks")
r_ok = a3_repo("resolved", "hk-dir", mkdir_hooks="hk-dir")
hk_target = a3_home / "hk" / "pre-commit"
a3_blocks = [
    # The current repo's hooks path is `~/hk`. The target is inside it.
    ("tilde-cwd", f"cat > {hk_target} <<{q}EOF{q}\n{real_push}\nEOF", r_tilde),
    # The current repo's hooks path does not resolve.
    ("missing-cwd", f"cat > /tmp/a1829.md <<{q}EOF{q}\n{prose}\nEOF", r_missing),
    # The target's repo has a hooks path that does not resolve.
    ("missing-target", f"cat > {r_missing}/note.md <<{q}EOF{q}\n{prose}\nEOF", r_ok),
]
a3_bad = [lb for lb, cmd, cwd in a3_blocks if "block-main-push.sh" not in route_log_in(cmd, f"a3-{lb}", cwd)]
if a3_bad:
    bad("hooks path in the target or current repo must keep the raw command: " + ",".join(a3_bad))
else:
    ok(f"hooks path in the target or current repo keeps the raw command ({len(a3_blocks)} shapes)")
a3_allow = route_log_in(f"cat > note.md <<{q}EOF{q}\n{prose}\nEOF", "a3-allow", r_ok)
if "block-main-push.sh" in a3_allow:
    bad("resolved hooks path outside the target must not route push gates")
else:
    ok("resolved hooks path outside the target does not route push gates")

# Single-command rule (CEO decision, 2026-10-20). Each shape is a sink with
# something more in the command, or a sink form that is not on the list.
# The prose body names a push, so the raw command must route the push gates.
narrow_shapes = [
    ("body-file-rm", f"cat > /tmp/b1829.md <<{q}EOF{q}\n{prose}\nEOF\n{w_gh} pr comment 1 --body-file /tmp/b1829.md\nrm /tmp/b1829.md"),
    ("commit-F-rm", f"cat > /tmp/m1829.txt <<{q}EOF{q}\n{prose}\nEOF\ngit {verb_commit} -F /tmp/m1829.txt && rm /tmp/m1829.txt"),
    ("cd-before", f"cd /tmp && cat > notes.md <<{q}EOF{q}\n{prose}\nEOF"),
    ("semicolon-after", f"cat > notes.md <<{q}EOF{q}; true\n{prose}\nEOF"),
    ("assignment-prefix", f"X=1 cat > notes.md <<{q}EOF{q}\n{prose}\nEOF"),
    ("second-heredoc", f"cat > a.md <<{q}EOF{q}\n{prose}\nEOF\ncat > b.md <<{q}EOF{q}\n{prose}\nEOF"),
    ("subshell", f"(cat > notes.md <<{q}EOF{q}\n{prose}\nEOF\n)"),
    ("group", f"{{ cat > notes.md <<{q}EOF{q}\n{prose}\nEOF\n}}"),
    ("substitution-arg", f"{w_gh} pr create --title \"$(id)\" --body-file - <<{q}EOF{q}\n{prose}\nEOF"),
    ("cat-alone", f"cat <<{q}EOF{q}\n{prose}\nEOF"),
    ("cat-noclobber", f"cat >| notes.md <<{q}EOF{q}\n{prose}\nEOF"),
    ("tee-two-files", f"tee a.md b.md <<{q}EOF{q}\n{prose}\nEOF"),
    ("tee-devnull", f"tee a.md <<{q}EOF{q} >/dev/null\n{prose}\nEOF"),
    ("gh-api-input", f"{w_gh} api repos/o/r/issues/1/comments --input - <<{q}EOF{q}\n{prose}\nEOF"),
    ("gh-editor", f"{w_gh} pr comment 1 --editor --body-file - <<{q}EOF{q}\n{prose}\nEOF"),
    ("git-dash-C", f"git -C /tmp {verb_commit} -F - <<{q}EOF{q}\n{prose}\nEOF"),
    ("git-dash-c", f"git -c core.editor=true {verb_commit} -F - <<{q}EOF{q}\n{prose}\nEOF"),
    ("git-edit", f"git {verb_commit} -e -F - <<{q}EOF{q}\n{prose}\nEOF"),
    ("symlink-target", f"cat > link1829.md <<{q}EOF{q}\n{prose}\nEOF"),
]
(tmp / "link1829.md").symlink_to(tmp / "elsewhere.md")
narrow_bad = [lb for lb, cmd in narrow_shapes if "block-main-push.sh" not in route_log(cmd, f"narrow-{lb}")]
if narrow_bad:
    bad("a sink with more in the command must keep the raw command: " + ",".join(narrow_bad))
else:
    ok(f"a sink with more in the command keeps the raw command ({len(narrow_shapes)} shapes)")

# #1829 N2: a single sink that writes a config file that git or gh reads by
# an implicit name keeps the raw command: a home-directory dot file or dot
# directory (this includes $HOME/.config) or $XDG_CONFIG_HOME.
(a3_home / ".config" / "git").mkdir(parents=True)
(a3_home / ".config" / "gh").mkdir(parents=True)
a3_xdg = a3 / "xdg"
(a3_xdg / "gh").mkdir(parents=True)
w_editor = "edi" + "tor"
n2_shapes = [
    ("git-config", f"cat > {a3_home}/.config/git/config <<{q}EOF{q}\n[core]\n\t{w_editor} = {real_push}\nEOF", {}),
    ("gh-config", f"cat > {a3_home}/.config/gh/config.yml <<{q}EOF{q}\nbrowser: sh -c '{real_push}'\nEOF", {}),
    ("gitconfig", f"cat >> {a3_home}/.gitconfig <<{q}EOF{q}\n[core]\n\t{w_editor} = {real_push}\nEOF", {}),
    ("bashrc", f"tee -a {a3_home}/.bashrc <<{q}EOF{q}\n{real_push}\nEOF", {}),
    ("xdg-gh", f"cat > {a3_xdg}/gh/config.yml <<{q}EOF{q}\nbrowser: sh -c '{real_push}'\nEOF", {"XDG_CONFIG_HOME": str(a3_xdg)}),
    ("config-then-commit", f"cat > {a3_home}/.config/git/config <<{q}EOF{q}\n[core]\n\t{w_editor} = {real_push}\nEOF\ngit {verb_commit}", {}),
]
n2_bad = [lb for lb, cmd, ex in n2_shapes if "block-main-push.sh" not in route_log_in(cmd, f"n2-{lb}", r_ok, ex)]
if n2_bad:
    bad("a sink that writes a home config file must keep the raw command: " + ",".join(n2_bad))
else:
    ok(f"a sink that writes a home config file keeps the raw command ({len(n2_shapes)} shapes)")
n2_allow = route_log_in(f"cat > {a3_home}/notes.md <<{q}EOF{q}\n{prose}\nEOF", "n2-allow", r_ok)
if "block-main-push.sh" in n2_allow:
    bad("a plain file in the home directory must not route push gates")
else:
    ok("a plain file in the home directory does not route push gates")

# Review-body class (#1805, seen after #1804 merged): a quoted heredoc body
# holds an unresolvable cd and a git verb that is not a builtin (an alias
# candidate) in prose. In the original body, the verb word was
# "hash-object" with its closing backtick. The alias check must not scan
# that body. The block twin runs the same words outside the heredoc, so the
# alias check still cannot resolve the repo.
w_git = "g" + "it"
w_cd = "c" + "d"
w_hash = "hash" + "-object"
w_verb = "zf" + "rob"
w_out = '"$' + 'OUT"'
review_body = (
    f"Line 143 is `paths=$({w_cd} {w_out} && find . -print)`.\n"
    f"The reviewer hook blocked `{w_git} {w_hash}` on an export.\n"
    f"Then run {w_git} {w_verb} on the snapshot.\n"
)
alias_allow_cmd = f"cat > /tmp/review-1805.md <<'EOF'\n{review_body}EOF"
alias_block_cmd = f"{w_cd} {w_out} && {w_git} {w_verb}"

def dispatch_route(tree, cmd, tag):
    payload = tmp / f"{tag}.json"
    payload.write_text(json.dumps({
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "cwd": str(tmp),
    }))
    log = tmp / f"log-{tag}"
    log.write_text("")
    env["DISPATCH_LOG"] = str(log)
    p = subprocess.run(
        ["/bin/bash", str(tree / "dispatch-bash.sh")],
        input=payload.read_text(),
        text=True,
        capture_output=True,
        cwd=str(tmp),
        env=env,
        check=False,
    )
    return p.returncode, p.stdout + p.stderr

rc, out = dispatch_route(new_route, alias_allow_cmd, "alias-allow")
if rc == 0 and "BLOCKED" not in out:
    ok("quoted review body with cd and git verbs in prose is allowed")
else:
    bad(f"quoted review body with cd and git verbs in prose is allowed; rc={rc} out={out[:240]!r}")
rc, out = dispatch_route(new_route, alias_block_cmd, "alias-block")
if rc == 2 and "cannot resolve the repository for this git alias" in out:
    ok("same cd and git verb outside the heredoc still block")
else:
    bad(f"same cd and git verb outside the heredoc still block; rc={rc} out={out[:240]!r}")
if fb_note:
    print(f"NOTE: skip fail-before (review body): {fb_note}", flush=True)
else:
    base_route = make_dispatch_tree(base_hooks, "base-route", stub_gates=True)
    rc, out = dispatch_route(base_route, alias_allow_cmd, "alias-allow-base")
    if rc == 2 and "git alias" in out:
        ok("fail-before: base blocks the quoted review body")
    else:
        bad(f"fail-before: base blocks the quoted review body; rc={rc} out={out[:240]!r}")

# #1829 B4: the start line, marker included, must split into words that
# show one heredoc operator outside quotes and one quoted delimiter word
# with matching quotes. An unbalanced marker quote, a mismatched pair, or
# an operator inside a quoted argument keeps the raw command, so the push
# line after it reaches the push gates. Each class has an allow twin.
dq = '"'
b4_blocks = [
    ("unbalanced-comment", f"git {verb_commit} -F - -m x{q}y <<{q}EOF #{q}\n{real_push}\n{q}EOF"),
    ("unbalanced-redirect", f"git {verb_commit} -F - --trailer x{q}y <<{q}EOF >{q}\n{real_push}\n{q}EOF"),
    ("mismatched-dq-sq", f"git {verb_commit} -F - --trailer {dq}k <<{q}EOF{dq} >{q}\n{real_push}\nEOF{q}"),
    ("mismatched-sq-dq", f"git {verb_commit} -F - --trailer {q}k <<{dq}EOF{q} >{dq}\n{real_push}\nEOF{dq}"),
    ("in-arg-sq", f"git {verb_commit} -F - --trailer {q}k <<{q}EOF{q} >{q}\n{real_push}\nEOF"),
    ("in-arg-dq", f"git {verb_commit} -F - --trailer {dq}k <<{dq}EOF{dq} >{dq}\n{real_push}\nEOF"),
    ("in-arg-tee", f"tee -a {q}<<{q}EOF{q}{q}\n{real_push}\nEOF"),
    ("partly-quoted", f"cat > /tmp/b4-1780.md <<E{q}OF{q}\n{real_push}\nEOF"),
    ("quote-then-word", f"cat > /tmp/b4-1780.md <<{q}E{q}OF\n{real_push}\nEOF"),
]
b4_allows = [
    ("sq", f"cat > /tmp/b4-1780.md <<{q}EOF{q}\n{prose}\nEOF"),
    ("dq", f"cat > /tmp/b4-1780.md <<{dq}EOF{dq}\n{prose}\nEOF"),
    ("dash-tab", f"cat > /tmp/b4-1780.md <<-{q}EOF{q}\n\t{prose}\n\tEOF"),
    ("space-before-word", f"cat > /tmp/b4-1780.md << {q}EOF{q}\n{prose}\nEOF"),
    ("quoted-arg-sq", f"git {verb_commit} -F - --trailer {q}k: v{q} <<{q}EOF{q}\nfix(#1780): note\n\n{prose}\nEOF"),
    ("quoted-arg-dq", f"git {verb_commit} --trailer {dq}k: v{dq} -F - <<{dq}EOF{dq}\nfix(#1780): note\n\n{prose}\nEOF"),
    ("tee-append", f"tee -a /tmp/b4-1780.md <<{q}EOF{q}\n{prose}\nEOF"),
    ("operator-first", f"cat <<{q}EOF{q} > /tmp/b4-1780.md\n{prose}\nEOF"),
    ("glued-redirect", f"cat >/tmp/b4-1780.md <<{q}EOF{q}\n{prose}\nEOF"),
]
def strip_quoted(cmd):
    p = subprocess.run(
        ["/bin/bash", "-c", '. "$1"; strip_heredoc_bodies "$2" quoted', "_",
         str(hooks / "_lib-strip-heredoc.sh"), cmd],
        capture_output=True, text=True, cwd=str(tmp), check=False,
    )
    return p.returncode, p.stdout
b4_route_bad = [lb for lb, cmd in b4_blocks if "block-main-push.sh" not in route_log(cmd, f"b4-{lb}")]
if b4_route_bad:
    bad("B4 marker shapes must route push gates: " + ",".join(b4_route_bad))
else:
    ok(f"B4 marker shapes route push gates ({len(b4_blocks)} shapes)")
b4_raw_bad = []
for lb, cmd in b4_blocks:
    rc, out = strip_quoted(cmd)
    if rc != 0 or out.rstrip("\n") != cmd.rstrip("\n"):
        b4_raw_bad.append(lb)
if b4_raw_bad:
    bad("B4 marker shapes must keep the raw command in the stripper: " + ",".join(b4_raw_bad))
else:
    ok(f"B4 marker shapes keep the raw command in the stripper ({len(b4_blocks)} shapes)")
b4_allow_bad = [lb for lb, cmd in b4_allows if "block-main-push.sh" in route_log(cmd, f"b4-allow-{lb}")]
if b4_allow_bad:
    bad("B4 allow twins must not route push gates: " + ",".join(b4_allow_bad))
else:
    ok(f"B4 allow twins do not route push gates ({len(b4_allows)} shapes)")

# #1844 S1: many anchored quoted markers with no terminator. In quoted mode
# the stripper returns the raw command at the second visible line that
# holds text, so the scan is linear. The block twin adds a real push at the
# end; it must still route the push gates.
many_markers = "\n".join([f"cat <<{q}EOF{q}"] * 2000)
t0 = time.perf_counter()
rc, out = dispatch_route(new_route, many_markers, "s1-markers")
s1_dt = time.perf_counter() - t0
if rc == 0 and s1_dt <= 15.0:
    ok(f"2000 unterminated quoted markers dt={s1_dt:.3f}s rc={rc}")
else:
    bad(f"2000 unterminated quoted markers dt={s1_dt:.3f}s rc={rc} (want <=15s, rc=0) out={out[:240]!r}")
if "block-main-push.sh" in route_log(many_markers + "\n" + real_push, "s1-markers-push"):
    ok("2000 unterminated quoted markers then a real push routes push gates")
else:
    bad("2000 unterminated quoted markers then a real push must route push gates")

# Timing on the full hook tree: the always-on hooks are real too. A long
# quoted heredoc of prose that names push and commit verbs must finish well
# inside the dispatcher time limit (75 s in settings.json).
full_tree = tmp / "new-full"
if full_tree.exists():
    shutil.rmtree(full_tree)
shutil.copytree(hooks, full_tree)
t0 = time.perf_counter()
rc, out, note = run_dispatch(full_tree, tmp / "kw.json", "en_US.UTF-8", timeout=40)
full_dt = time.perf_counter() - t0
if note != "timeout" and full_dt <= 20.0 and "push destination" not in out:
    ok(f"kw 16KB full hook tree dt={full_dt:.3f}s rc={rc}")
else:
    bad(f"kw 16KB full hook tree dt={full_dt:.3f}s rc={rc} note={note} out={(out or '')[:240]!r}")

print(f"TOTAL {pass_n} passed; {fail_n} failed", flush=True)
# Stash counts for the outer bash wrapper
(tmp / "counts").write_text(f"{pass_n} {fail_n}\n")
sys.exit(1 if fail_n else 0)
PY
rc=$?
if [ -f "$TMP/counts" ]; then
  read -r PASS FAIL < "$TMP/counts" || true
fi
echo "OUTER TOTAL ${PASS:-?} passed; ${FAIL:-?} failed (python rc=$rc)"
[ "$rc" -eq 0 ]
