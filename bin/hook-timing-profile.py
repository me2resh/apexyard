#!/usr/bin/env python3
"""Measure how long ApexYard hooks take, and print p50, p95 and max.

Two modes. Both print one line per hook with the sample count n, and the
p50, p95 and max values in milliseconds. The percentile method is nearest
rank: sort the n samples, take the value at rank ceil(p * n).

  parse   Read a Claude Code debug log and measure each hook that matches a
          script name. Claude Code writes a line like
            Hooks: PreToolUse:Bash <command> finished with status 0 (547ms)
          for each hook run when you start it with --debug-file <path>.

            hook-timing-profile.py parse DEBUG_LOG SCRIPT [SCRIPT ...]

  run     Pipe one hook payload into the real settings.json wrapper command
          N times and measure the wall time of each call. Use this for routes
          that a short debug session does not reach, such as a git commit.
          The payload is only sent to the hooks. The command is never run.

            hook-timing-profile.py run SETTINGS_JSON N EVENT MATCHER SCRIPT COMMAND

  EVENT is a hook event such as PreToolUse. MATCHER is the matcher string of
  the settings.json entry. SCRIPT picks the entry whose command names it.

The script reads and writes no state. It needs only the Python standard
library.
"""
import json
import math
import re
import subprocess
import sys
import time


def percentile(sorted_values, p):
    rank = max(1, math.ceil(p * len(sorted_values)))
    return sorted_values[rank - 1]


def report(name, values):
    values = sorted(values)
    if not values:
        print("%s: no samples" % name)
        return 1
    print(
        "%s: n=%d p50=%dms p95=%dms max=%dms"
        % (name, len(values), percentile(values, 0.50), percentile(values, 0.95), values[-1])
    )
    return 0


def parse(log_path, scripts):
    line_re = re.compile(r"Hooks: [A-Za-z]+:[A-Za-z|]+ .*finished with status (\d+) \((\d+)ms\)")
    samples = dict((s, []) for s in scripts)
    with open(log_path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = line_re.search(line)
            if not match:
                continue
            for script in scripts:
                if script in line:
                    samples[script].append(int(match.group(2)))
    status = 0
    for script in scripts:
        status |= report(script, samples[script])
    return status


def find_command(settings_path, event, matcher, script):
    with open(settings_path, encoding="utf-8") as handle:
        settings = json.load(handle)
    for group in settings["hooks"][event]:
        if group.get("matcher") != matcher:
            continue
        for hook in group["hooks"]:
            if script in hook["command"]:
                return hook["command"]
    raise SystemExit("no %s/%s entry names %s" % (event, matcher, script))


def run(settings_path, count, event, matcher, script, command):
    wrapper = find_command(settings_path, event, matcher, script)
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    values = []
    for _ in range(count):
        start = time.monotonic()
        subprocess.run(
            ["bash", "-c", wrapper],
            input=payload,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        values.append(int((time.monotonic() - start) * 1000))
    return report("%s [%s]" % (script, command), values)


def main(argv):
    if len(argv) >= 4 and argv[1] == "parse":
        return parse(argv[2], argv[3:])
    if len(argv) == 8 and argv[1] == "run":
        return run(argv[2], int(argv[3]), argv[4], argv[5], argv[6], argv[7])
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
