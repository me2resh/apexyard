#!/bin/bash
# Verify decision record coverage and /agdr stats gap reports on a fixture repo.
set -eu
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
PASS=0
FAIL=0
check() {
  if "$@"; then PASS=$((PASS + 1)); else
    echo "FAIL: $*"
    FAIL=$((FAIL + 1))
  fi
}
has() { printf '%s\n' "$1" | grep -Fxq -- "$2"; }
lacks() { ! printf '%s\n' "$1" | grep -Fq -- "$2"; }

SC="$ROOT/.claude/skills/agdr/scripts"
HC="$ROOT/.claude/skills/handover/scripts/coverage.sh"
for s in list-subjects coverage-check stats-gaps; do check test -f "$SC/$s.sh"; done
check test -f "$HC"

# Fixture repository.
R="$SB/repo"
mkdir -p "$R/src" "$R/tests" "$R/docs/agdr"
cat > "$R/package.json" <<'JSON'
{
  "name": "fixture",
  "dependencies": {
    "express": "^4.0.0",
    "mongoose": "^8.0.0",
    "axios": "^1.0.0",
    "leftpad": "^1.0.0",
    "react": "^18.0.0",
    "zod": "^3.0.0"
  },
  "devDependencies": {
    "vitest": "^1.0.0"
  }
}
JSON
printf 'express\npytest\n' > "$R/requirements.txt"
printf 'module x\n\nrequire (\n\tgithub.com/gin-gonic/gin v1.9.0\n)\n' > "$R/go.mod"
printf "source 'https://rubygems.org'\ngem 'sinatra'\n" > "$R/Gemfile"
printf '[dependencies]\nserde = "1"\n\n[dev-dependencies]\ntempfile = "3"\n' > "$R/Cargo.toml"
cat > "$R/src/app.js" <<'JS'
const express = require('express');
const axios = require('axios');
const mongoose = require('mongoose');
fetch('https://api.stripe.com/v1/charges');
fetch('http://localhost:3000/health');
JS
printf "const leftpad = require('leftpad');\nconst express = require('express');\n" > "$R/tests/a.test.js"
AG="$R/docs/agdr"
agdr() { # file status title extra-body
  printf -- '---\nstatus: %s\n---\n\n# %s\n\n%s\n' "$2" "$3" "$4" > "$AG/$1"
}
agdr AgDR-0001-express.md executed "AgDR-0001: Use Express" "Chosen: **Express**, because it is small."
agdr AgDR-0002-axios.md proposed "AgDR-0002: Adopt Axios" "Chosen: **Axios**, because it is common."
agdr AgDR-0003-mongoose.md "superseded by AgDR-0009" "AgDR-0003: Use Mongoose" "Chosen: **Mongoose**."
agdr AgDR-0004-tests.md executed "AgDR-0004: Test runner" "We run vitest in CI. The zod library is nice. Our reactive UI is fast."

# Dependency and host listing.
SUBJ=$(bash "$SC/list-subjects.sh" "$R" 2>/dev/null || true)
check grep -q "^runtime	express	" <<< "$SUBJ"
check grep -q "^dev	vitest	" <<< "$SUBJ"
check grep -q "^runtime	github.com/gin-gonic/gin	go.mod" <<< "$SUBJ"
check grep -q "^runtime	sinatra	Gemfile" <<< "$SUBJ"
check grep -q "^runtime	serde	Cargo.toml" <<< "$SUBJ"
check grep -q "^dev	tempfile	Cargo.toml" <<< "$SUBJ"
check grep -q "^runtime	pytest	requirements.txt" <<< "$SUBJ"
check grep -q "^host	api.stripe.com	" <<< "$SUBJ"
check lacks "$SUBJ" "localhost"
check lacks "$SUBJ" "rubygems.org	"
# Names of 3 characters or fewer are ignored.
check lacks "$SUBJ" "	zod	"
check test "$(printf '%s\n' "$SUBJ" | head -n 1 | cut -f1)" = host

# Coverage hints.
COV=$(bash "$HC" "$R" 2>/dev/null || true)
check has "$COV" "$(printf 'runtime\texpress\ttitle-or-chosen')"
check has "$COV" "$(printf 'dev\tvitest\tbody-only')"
check has "$COV" "$(printf 'host\tapi.stripe.com\tunnamed')"
check has "$COV" "$(printf 'runtime\tleftpad\tunnamed')"
# Whole words only: "reactive" does not name react.
check has "$COV" "$(printf 'runtime\treact\tunnamed')"
check lacks "$COV" "	zod	"
check test "$(printf '%s\n' "$COV" | head -n 1 | cut -f1)" = host

# Stats gap report.
GAPS=$(bash "$SC/stats-gaps.sh" "$R" "$AG" 2>/dev/null || true)
check has "$GAPS" "$(printf 'proposed-in-use\taxios\tAgDR-0002-axios.md')"
check has "$GAPS" "$(printf 'superseded-in-use\tmongoose\tAgDR-0003-mongoose.md')"
check has "$GAPS" "$(printf 'test-only-runtime\tleftpad\t-')"
check lacks "$GAPS" "test-only-runtime	express"
check lacks "$GAPS" "AgDR-0001"
check lacks "$GAPS" "AgDR-0004"

# A proposed AgDR whose subject the code does not use is not reported.
agdr AgDR-0005-redis.md proposed "AgDR-0005: Use Redis" "Chosen: **Redis**."
GAPS2=$(bash "$SC/stats-gaps.sh" "$R" "$AG" 2>/dev/null || true)
check lacks "$GAPS2" "AgDR-0005"

# Review regressions (#2143): manifest shapes.
M="$SB/manifests"
mkdir -p "$M"
cat > "$M/package.json" <<'JSON'
{
  "peerDependencies": { "reactlib": ">=16" },
  "dependencies": {},
  "scripts": { "build": "tsc" }
}
JSON
printf '[project]\ndependencies = [\n  "pydantic[email]>=2",\n  "httpx>=0.2",\n  "sqlalchemy",\n]\n' > "$M/pyproject.toml"
printf "gem 'rails'\ngroup :test do\n  gem 'capybara'\nend\ngem 'puma'\n" > "$M/Gemfile"
printf 'module x\n\nrequire (\n\tgithub.com/direct/lib v1.0.0\n\tgolang.org/x/sysx v0.1.0 // indirect\n)\n' > "$M/go.mod"
MS=$(bash "$SC/list-subjects.sh" "$M" 2>/dev/null || true)
check grep -q "^runtime	reactlib	" <<< "$MS"
check lacks "$MS" "	scripts	"
check lacks "$MS" "	build	"
check grep -q "^runtime	pydantic	" <<< "$MS"
check grep -q "^runtime	httpx	" <<< "$MS"
check grep -q "^runtime	sqlalchemy	" <<< "$MS"
check grep -q "^dev	capybara	Gemfile" <<< "$MS"
check grep -q "^runtime	puma	Gemfile" <<< "$MS"
check grep -q "^runtime	github.com/direct/lib	" <<< "$MS"
check lacks "$MS" "sysx"

# Review regressions (#2143): lockfile and parent path.
P="$SB/test_area/app"
mkdir -p "$P/src" "$P/tests"
printf '{"dependencies":{"expressly":"1","leftpadx":"1"}}\n' > "$P/package.json"
printf "require('expressly');\n" > "$P/src/app.js"
printf "require('leftpadx');\n" > "$P/tests/a.test.js"
printf 'packages:\n  expressly: 1\n  leftpadx: 1\n' > "$P/pnpm-lock.yaml"
PG=$(bash "$SC/stats-gaps.sh" "$P" "$AG" 2>/dev/null || true)
check has "$PG" "$(printf 'test-only-runtime\tleftpadx\t-')"
check lacks "$PG" "test-only-runtime	expressly"

# Fail closed on a missing repository.
rc=0
bash "$SC/stats-gaps.sh" "$SB/nope" "$AG" >/dev/null 2>&1 || rc=$?
check test "$rc" -eq 2
# A symlinked manifest outside the repo is ignored.
L="$SB/linked"
mkdir -p "$L"
ln -s "$R/package.json" "$L/package.json"
check test -z "$(bash "$SC/list-subjects.sh" "$L" 2>/dev/null | grep -v '^host' || true)"

# Skill pointers stay short and name the scripts.
check grep -Fq 'scripts/stats-gaps.sh' "$ROOT/.claude/skills/agdr/SKILL.md"
check grep -Fq 'scripts/coverage.sh' "$ROOT/.claude/skills/handover/SKILL.md"
check grep -Fq -- '/decide --backfill' "$ROOT/.claude/skills/handover/SKILL.md"
check test "$(wc -c < "$ROOT/.claude/skills/agdr/SKILL.md")" -le 16000

echo "agdr coverage: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
