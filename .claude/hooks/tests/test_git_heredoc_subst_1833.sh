#!/bin/bash
# #1833 (AgDR-0270): a commit message passed as `"$(cat <<'X' ... X\n)"`.
# The stripper accepts it as one data sink. The gate visitor parses the
# stripped text, so the 16 KB body does not reach the cd chain or the alias
# check of each gate. Any other substitution keeps the raw command.
# Fixture bodies are built in Python. They are never built by a Bash
# heredoc that names push or commit verbs.
set -eu
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
HOOKS="$ROOT/.claude/hooks"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

set +e
python3 - "$TMP" "$HOOKS" "$ROOT" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, time

tmp, hooks, root = map(pathlib.Path, sys.argv[1:4])
pass_n = fail_n = 0
def ok(msg):
    global pass_n; pass_n += 1; print("PASS:", msg, flush=True)
def bad(msg):
    global fail_n; fail_n += 1; print("FAIL:", msg, flush=True)

vp, vc = "pu" + "sh", "com" + "mit"
chunk = f"Review note: run git {vp} after git {vc}, then git {vp} again. "
body = ""
while len(body) < 16384:
    body += chunk
body = body[:16384]
q, dq = "'", '"'
real_push = f"git {vp} origin main"

def subst(head, opener, inner_body, close=')"', term="EOF"):
    return f"{head}{opener}\n{inner_body}\n{term}\n{close}"

allow_cmd = subst(f"git {vc} -m ", f"{dq}$(cat <<{q}EOF{q}", f"chore: note\n\n{body}")
allows = [
    ("message-long", subst(f"git {vc} --message ", f"{dq}$(cat <<{q}EOF{q}", f"chore: x\n\n{real_push}")),
    ("dq-delimiter", subst(f"git {vc} -m ", f"{dq}$(cat <<{dq}EOF{dq}", f"chore: x\n\n{real_push}")),
    ("dash-tab", subst(f"git {vc} -m ", f"{dq}$(cat <<-{q}EOF{q}", f"\tchore: x\n\t{real_push}", term="\tEOF")),
    ("all-flag", subst(f"git {vc} -a -m ", f"{dq}$(cat <<{q}EOF{q}", f"chore: x\n\n{real_push}")),
]
# Block twins: each one keeps the raw command, so the body push is seen.
blocks = [
    ("bash-runner", subst(f"git {vc} -m ", f"{dq}$(bash <<{q}EOF{q}", real_push)),
    ("sh-runner", subst(f"git {vc} -m ", f"{dq}$(sh <<{q}EOF{q}", real_push)),
    ("cat-pipe-sh", subst(f"git {vc} -m ", f"{dq}$(cat <<{q}EOF{q} | sh", real_push)),
    ("unquoted-delim", subst(f"git {vc} -m ", f"{dq}$(cat <<EOF", real_push)),
    ("eval", subst("eval ", f"{dq}$(cat <<{q}EOF{q}", real_push)),
    ("not-commit", subst(f"git {vp} -m ", f"{dq}$(cat <<{q}EOF{q}", real_push)),
    ("reuse-msg-C", subst(f"git {vc} -C ", f"{dq}$(cat <<{q}EOF{q}", real_push)),
    ("edit-flag", subst(f"git {vc} -e -m ", f"{dq}$(cat <<{q}EOF{q}", real_push)),
    ("template", subst(f"git {vc} --template x -m ", f"{dq}$(cat <<{q}EOF{q}", real_push)),
    ("comment-head", subst(f"git {vc} -m #", f"{dq}$(cat <<{q}EOF{q}", real_push)),
    ("cd-before", subst(f"cd /tmp && git {vc} -m ", f"{dq}$(cat <<{q}EOF{q}", real_push)),
    ("after-close", subst(f"git {vc} -m ", f"{dq}$(cat <<{q}EOF{q}", "chore: x", close=f'){dq}; {real_push}')),
    ("unquoted-subst", subst(f"git {vc} -m ", f"$(cat <<{q}EOF{q}", real_push, close=")")),
    ("second-close", subst(f"git {vc} -m ", f"{dq}$(cat <<{q}EOF{q}", real_push, close=f'){dq}\n){dq}')),
    ("text-after-delim", subst(f"git {vc} -m ", f"{dq}$(cat <<{q}EOF{q} x", real_push)),
]

def run_dispatch(tree, cmd, tag, timeout=30, log=None):
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": str(tmp)})
    env = dict(os.environ)
    env["PATH"] = str(tmp / "bin") + os.pathsep + env.get("PATH", "")
    if log is not None:
        log.write_text("")
        env["DISPATCH_LOG"] = str(log)
    p = subprocess.Popen(["/bin/bash", str(tree / "dispatch-bash.sh")], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         cwd=str(tmp), env=env, start_new_session=True)
    try:
        out, err = p.communicate(payload, timeout=timeout)
        return p.returncode, out + err, None
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, 9)
        out, err = p.communicate()
        return 124, (out or "") + (err or ""), "timeout"

# The always-on hooks are stubs. Routing trees stub the push and commit
# gates too, so DISPATCH_LOG shows which groups ran.
ALWAYS = [
    "block-protected-target-writes.sh", "block-ambient-tracker-repo.sh",
    "block-privileged-escalation.sh", "require-skill-for-issue-create.sh",
    "require-orbit-slice-for-ticket.sh", "require-migration-ticket.sh",
    "require-active-ticket.sh", "warn-review-marker-write.sh",
    "warn-isolated-build-risk.sh", "block-reviewer-repo-mutation.sh",
    "block-reviewer-ci-wait.sh", "block-forged-menu-approval.sh",
    "block-git-add-all.sh", "suggest-ticket-template.sh",
    "validate-issue-structure.sh", "block-private-refs-in-public-repos.sh",
    "validate-pr-create.sh", "require-agdr-for-arch-pr.sh",
    "nudge-control-adversarial-test.sh", "block-unreviewed-merge.sh",
    "require-design-review-for-ui.sh", "block-merge-on-red-ci.sh",
    "require-architecture-review.sh", "detect-role-trigger.sh",
]
GATES = [
    "block-main-push.sh", "validate-branch-name.sh", "pre-push-gate.sh",
    "block-agent-routing-drift.sh", "check-secrets.sh",
    "block-onboarding-in-git.sh", "verify-commit-refs.sh",
    "validate-commit-format.sh", "require-agdr-for-arch-changes.sh",
    "warn-bootstrap-scope.sh",
]
def make_tree(src, label, stub_gates):
    dest = tmp / label
    shutil.copytree(src, dest)
    for name in ALWAYS:
        (dest / name).write_text('#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n')
        (dest / name).chmod(0o755)
    if stub_gates:
        for name in GATES:
            (dest / name).write_text(
                '#!/usr/bin/env bash\nset -euo pipefail\ncat >/dev/null\n'
                'printf \'%s\\n\' "$(basename "$0")" >> "${DISPATCH_LOG:?}"\n')
            (dest / name).chmod(0o755)
    return dest

(tmp / "bin").mkdir()
(tmp / "bin" / "bash").symlink_to("/bin/bash")
time_tree = make_tree(hooks, "new-time", stub_gates=False)
route_tree = make_tree(hooks, "new-route", stub_gates=True)

def strip_quoted(cmd):
    p = subprocess.run(
        ["/bin/bash", "-c", '. "$1"; strip_heredoc_bodies "$2" quoted', "_",
         str(hooks / "_lib-strip-heredoc.sh"), cmd],
        capture_output=True, text=True, cwd=str(tmp), check=False)
    return p.returncode, p.stdout

def routed(tree, cmd, tag):
    log = tmp / f"log-{tag}"
    run_dispatch(tree, cmd, tag, log=log)
    return log.read_text()

# Fast allow case: real push and commit gates, under UTF-8 and C. One
# warm-up run, then three timed runs. Each timed run must be <= 3 s.
for locale in ("en_US.UTF-8", "C"):
    os.environ["LC_ALL"] = locale
    run_dispatch(time_tree, allow_cmd, "warm")
    times, last, out, good = [], 0, "", True
    for _ in range(3):
        t0 = time.perf_counter()
        last, out, note = run_dispatch(time_tree, allow_cmd, "time")
        times.append(time.perf_counter() - t0)
        if note or times[-1] > 3.0 or last != 0:
            good = False
            break
    shown = ["%.3f" % t for t in times]
    if good:
        ok(f"16 KB substitution message {locale} times={shown} rc={last}")
    else:
        bad(f"16 KB substitution message {locale} times={shown} rc={last} (want each <=3s, rc=0) out={out[:240]!r}")
os.environ["LC_ALL"] = "en_US.UTF-8"

# The allow case routes the commit gates and not the push gates.
log_txt = routed(route_tree, allow_cmd, "allow")
if "verify-commit-refs.sh" in log_txt and "block-main-push.sh" not in log_txt:
    ok("substitution message routes commit gates, not push gates")
else:
    bad(f"substitution message routing: {log_txt!r}")
rc, out = strip_quoted(allow_cmd)
want = f"git {vc} -m {dq}$(cat \n){dq}"
if rc == 0 and out.rstrip("\n") == want:
    ok("stripper keeps the commit and the substitution frame")
else:
    bad(f"stripper output for the allow case: rc={rc} out={out[:200]!r}")

bad_allow = [lb for lb, cmd in allows if strip_quoted(cmd)[1].rstrip("\n") == cmd.rstrip("\n")
             or "block-main-push.sh" in routed(route_tree, cmd, f"a-{lb}")]
if bad_allow:
    bad("allow variants must strip and not route push gates: " + ",".join(bad_allow))
else:
    ok(f"allow variants strip and do not route push gates ({len(allows)} shapes)")

# Block twins: the raw command stays, and the body push routes push gates.
raw_bad = [lb for lb, cmd in blocks if strip_quoted(cmd)[1].rstrip("\n") != cmd.rstrip("\n")]
if raw_bad:
    bad("block twins must keep the raw command: " + ",".join(raw_bad))
else:
    ok(f"block twins keep the raw command ({len(blocks)} shapes)")
route_bad = [lb for lb, cmd in blocks if "block-main-push.sh" not in routed(route_tree, cmd, f"b-{lb}")]
if route_bad:
    bad("block twins must route push gates: " + ",".join(route_bad))
else:
    ok(f"block twins route push gates ({len(blocks)} shapes)")

# The gate visitor reads the stripped text only through the stripper. A
# shell runner keeps the raw text. A missing stripper gives the raw text.
def structure_text(lib_dir, cmd):
    p = subprocess.run(
        ["/bin/bash", "-c", '. "$1/_lib-git-global.sh"; _git_structure_text "$2"', "_",
         str(lib_dir), cmd], capture_output=True, text=True, cwd=str(tmp), check=False)
    return p.stdout
if structure_text(hooks, allow_cmd) == want:
    ok("visitor structure text strips the allow case")
else:
    bad("visitor structure text strips the allow case")
shell_twin = blocks[0][1]
if structure_text(hooks, shell_twin) == shell_twin:
    ok("visitor structure text keeps the raw shell twin")
else:
    bad("visitor structure text keeps the raw shell twin")
lone = tmp / "lone"
lone.mkdir()
shutil.copy(hooks / "_lib-git-global.sh", lone / "_lib-git-global.sh")
if structure_text(lone, allow_cmd) == allow_cmd:
    ok("visitor structure text is raw when the stripper is missing")
else:
    bad("visitor structure text is raw when the stripper is missing")

# A commit gate run alone on the allow case parses the stripped text, so it
# is fast. The fail-before below runs the same gate from the base.
def gate_alone(name, cmd):
    env = dict(os.environ)
    p = subprocess.run(["/bin/bash", str(hooks / name)],
                       input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": str(tmp)}),
                       capture_output=True, text=True, cwd=str(tmp), env=env, timeout=60, check=False)
    return p.returncode, p.stdout + p.stderr
t0 = time.perf_counter()
rc, out = gate_alone("verify-commit-refs.sh", allow_cmd)
dt = time.perf_counter() - t0
if rc == 0 and dt <= 2.0:
    ok(f"commit gate alone on the allow case dt={dt:.3f}s rc={rc}")
else:
    bad(f"commit gate alone on the allow case dt={dt:.3f}s rc={rc} out={out[:200]!r}")

# Fail-before: the dev commit before #1833. The allow case routes the push
# gates there. HEREDOC_1833_BASE_REF overrides the pin.
pin = os.environ.get("HEREDOC_1833_BASE_REF") or "1200b6df0ed3d64272176b22222503cea818e077"
have = subprocess.run(["git", "-C", str(root), "rev-parse", "--verify", "--quiet", pin + "^{commit}"],
                      capture_output=True, text=True, check=False)
if have.returncode != 0:
    print(f"NOTE: skip fail-before: pinned base {pin} is not in this clone", flush=True)
else:
    base = tmp / "base"
    base.mkdir()
    arch = subprocess.check_output(["git", "archive", pin, ".claude/hooks"], cwd=root)
    subprocess.run(["tar", "-x", "-C", str(base)], input=arch, check=True)
    base_route = make_tree(base / ".claude/hooks", "base-route", stub_gates=True)
    if "block-main-push.sh" in routed(base_route, allow_cmd, "base-allow"):
        ok("fail-before: base routes push gates for the substitution message")
    else:
        bad("fail-before: base routes push gates for the substitution message")
    t0 = time.perf_counter()
    env = dict(os.environ)
    p = subprocess.Popen(["/bin/bash", str(base / ".claude/hooks/verify-commit-refs.sh")],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, cwd=str(tmp), env=env, start_new_session=True)
    try:
        p.communicate(json.dumps({"tool_name": "Bash", "tool_input": {"command": allow_cmd}, "cwd": str(tmp)}), timeout=8)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, 9)
        p.communicate()
    bdt = time.perf_counter() - t0
    if bdt > 2.0:
        ok(f"fail-before: base commit gate alone dt={bdt:.3f}s (> 2 s)")
    else:
        bad(f"fail-before: base commit gate alone dt={bdt:.3f}s (want > 2 s)")

print(f"TOTAL {pass_n} passed; {fail_n} failed", flush=True)
(tmp / "counts").write_text(f"{pass_n} {fail_n}\n")
sys.exit(1 if fail_n else 0)
PY
rc=$?
set -e
PASS=0
FAIL=0
if [ -f "$TMP/counts" ]; then
  read -r PASS FAIL < "$TMP/counts" || true
fi
echo "OUTER TOTAL ${PASS} passed; ${FAIL} failed (python rc=$rc)"
[ "$rc" -eq 0 ]
