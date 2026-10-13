#!/usr/bin/env bash
# Local regression coverage for GH-1708. No service access or stdin required.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT="${APEXYARD_TEST_SRC_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
LIB="$ROOT/.claude/skills/scaffold/lib"
FIX="$ROOT/.claude/hooks/tests/fixtures/scaffold"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() {
  local name=$1
  shift
  if "$@"; then printf '  PASS: %s\n' "$name"; PASS=$((PASS+1));
  else printf '  FAIL: %s\n' "$name" >&2; FAIL=$((FAIL+1)); fi
}
ids() { bash "$LIB/next-questions.sh" "$@"; }
count_is() { local expected=$1 out; shift; out=$(ids "$@") || return 1; [ "$(jq -Rn '[inputs | select(length>0)] | length' <<< "$out")" = "$expected" ]; }
exit_is() { local expected=$1; shift; "$@" >"$TMP/output" 2>&1; [ "$?" -eq "$expected" ]; }
exact() { local expected=$1; shift; [ "$(ids "$@")" = "$expected" ]; }
mapped_is() { local filter=$1; shift; ids --mapped "$@" > "$TMP/mapped.json" && jq -e "$filter" "$TMP/mapped.json" >/dev/null; }
derived_is() { local filter=$1; shift; ids --derive "$@" > "$TMP/derived.json" && jq -e "$filter" "$TMP/derived.json" >/dev/null; }
check 'demo exact host-first order' exact $'host\nshape\nscale' --scale demo
check 'small four questions' exact $'host\nshape\nscale\ndataSensitivity' --scale small
check 'production five questions' exact $'host\nshape\nscale\ndataSensitivity\nreleaseCheck' --scale production
for tier in demo small production; do
  case "$tier" in demo) count=3 ;; small) count=4 ;; production) count=5 ;; esac
  jq -n '{answers:{hostKind:{value:"company cloud",source:"owner"}},specVersion:"0.1"}' > "$TMP/cloud.json"
  check "$tier cloud follow-up adds one before confirm" count_is "$((count+2))" --scale "$tier" --spec "$TMP/cloud.json"
  check "$tier confirm adds one" count_is "$((count+1))" --scale "$tier" --onboarding "$FIX/onboarding.fixture.yaml"
done
check 'unconfirmed mapped values remain questions' exact $'reuseConfirm\nhost\nshape\nscale\ndataSensitivity' --scale small --onboarding "$FIX/onboarding.fixture.yaml"
printf '%s\n' '{"reuseConfirm":"Use these"}' > "$TMP/reuse.json"
check 'confirmed onboarding skips host only' exact $'shape\nscale\ndataSensitivity' --scale small --onboarding "$FIX/onboarding.fixture.yaml" --run-answers "$TMP/reuse.json"
for choice in 'Change one' 'Ignore them and ask me'; do
  jq -n --arg choice "$choice" '{reuseConfirm:$choice}' > "$TMP/no-reuse.json"
  check "$choice never skips mapped values" count_is 4 --scale small --onboarding "$FIX/onboarding.fixture.yaml" --run-answers "$TMP/no-reuse.json"
done
check 'database maps only storage; sensitive fields never map' mapped_is '.answers.storage.value == "PostgreSQL" and (.answers | has("dataSensitivity") or has("compliance") or has("auth") | not)' --onboarding "$FIX/onboarding.fixture.yaml"
check 'language and CI are notes only' mapped_is '.notes.language == "Python" and .notes.ciSystem == "GitLab CI" and (.answers | has("language") or has("ci_cd") | not)' --onboarding "$FIX/onboarding.fixture.yaml"
check 'AWS hosting maps cloud and provider' mapped_is '.answers.hostKind.value == "company cloud" and .answers.hostProvider.value == "AWS"' --onboarding "$FIX/onboarding.fixture.yaml"
for value in Netlify Vercel Render Fly.io Heroku Amplify; do
  printf 'onboarding:\n  hosting: "%s"\n' "$value" > "$TMP/hosting.fixture.yaml"
  check "$value maps hosting service" mapped_is '.answers.hostKind.value == "hosting service"' --onboarding "$TMP/hosting.fixture.yaml"
done
for value in AWS GCP 'Google Cloud' Azure; do
  printf 'onboarding:\n  hosting: "%s"\n' "$value" > "$TMP/hosting.fixture.yaml"
  expected=$value; [ "$value" != GCP ] || expected='Google Cloud'
  check "$value exact cloud mapping" mapped_is ".answers.hostKind.value == \"company cloud\" and .answers.hostProvider.value == \"$expected\"" --onboarding "$TMP/hosting.fixture.yaml"
  printf 'onboarding:\n  cloud: "%s"\n' "$value" > "$TMP/provider.fixture.yaml"
  check "$value exact provider mapping" mapped_is ".answers.hostProvider.value == \"$expected\" and (.answers | has(\"hostKind\") | not)" --onboarding "$TMP/provider.fixture.yaml"
done
printf 'onboarding:\n  hosting: "our private platform"\n  cloud: aws\n' > "$TMP/unknown.fixture.yaml"
check 'unknown hosting and cloud mean ask' exact $'host\nshape\nscale' --scale demo --onboarding "$TMP/unknown.fixture.yaml"
check 'PRD explicit dataSensitivity mapped' mapped_is '.answers.dataSensitivity.value == "none" and .answers.dataSensitivity.source == "prd" and (.answers | has("auth") or has("compliance") | not)' --prd-answers "$FIX/prd.json"
printf '%s\n' '{"data":"payment"}' > "$TMP/prd-data.json"
check 'legacy PRD data explicitly maps sensitivity' mapped_is '.answers.dataSensitivity.value == "payment"' --prd-answers "$TMP/prd-data.json"
check 'confirmed PRD leaves host and releaseCheck' exact $'host\nreleaseCheck' --scale production --prd-answers "$FIX/prd.json" --run-answers "$TMP/reuse.json"
check 'spec wins over PRD and keeps conflict' mapped_is '.answers.shape.value == "web app" and any(.conflicts[]; .field == "shape")' --spec "$FIX/good.json" --prd-answers "$FIX/prd.json"
printf '%s\n' '{"shape":"data pipeline"}' > "$TMP/current.json"
check 'this run wins over spec' mapped_is '.answers.shape.value == "data pipeline"' --spec "$FIX/good.json" --run-answers "$TMP/current.json"
check 'bad scale usage' exit_is 2 ids --scale huge
check 'missing option value' exit_is 2 ids --scale
check 'missing file' exit_is 2 ids --scale demo --spec "$TMP/missing"
check 'valid spec with all sources' exit_is 0 bash "$LIB/validate-spec.sh" "$FIX/good.json"
for mutation in reason source scale extra answer unknown value date calendar duplicate mismatch; do
  case "$mutation" in
    reason) filter='del(.answers.shape.reason)' ;;
    source) filter='.answers.shape.source="guess"' ;;
    scale) filter='.scale="huge"' ;;
    extra) filter='.extra=true' ;;
    answer) filter='.answers.shape.extra=true' ;;
    unknown) filter='.answers.auth={value:"team",source:"owner"}' ;;
    value) filter='.answers.hostKind.value="unlisted"' ;;
    date) filter='.createdAt="yesterday"' ;;
    calendar) filter='.createdAt="2026-02-30T12:00:00Z"' ;;
    duplicate) filter='.unusedFields=["budget","budget"]' ;;
    mismatch) filter='.answers.scale.value="demo"' ;;
  esac
  jq "$filter" "$FIX/good.json" > "$TMP/bad.json"
  check "reject $mutation" exit_is 1 bash "$LIB/validate-spec.sh" "$TMP/bad.json"
done
check 'validator usage' exit_is 2 bash "$LIB/validate-spec.sh"
check 'bank contains seven constrained questions' jq -e '
  length == 7 and [.[].id] == ["reuseConfirm","host","hostProvider","shape","scale","dataSensitivity","releaseCheck"] and
  all(.[]; (.presets|length) <= 3 and (.presets|length) > 0 and
    (.recommended as $r | .presets | index($r)) != null and
    (.reason | split(" ") | length) <= 25 and (.reason|length) > 0 and
    (.condition|type) == "string" and all(.scales[]; . == "demo" or . == "small" or . == "production"))
' "$ROOT/.claude/skills/scaffold/questions.json"
for row in 1 2 3 4 5 6 7; do
  case "$row" in
    1) host='hosting service' shape='web app' provider=AWS path=typescript-nextjs ;;
    2) host='hosting service' shape='API service' provider=AWS path=python-fastapi ;;
    3) host='company cloud' shape='API service' provider=AWS path=python-fastapi ;;
    4) host='company cloud' shape='data pipeline' provider=AWS path=go-data-pipeline ;;
    5) host='company cloud' shape='web app' provider='Google Cloud' path=typescript-nextjs ;;
    6) host='server or container' shape='web app' provider=AWS path=typescript-nextjs ;;
    7) host=other shape=other provider=AWS path=custom ;;
  esac
  check "derive row $row and golden path" derived_is ".row == $row and .goldenPath == \"$path\" and (.pipeline|length)>0 and (.manualSteps|length)>0 and .notice == \"Deploy is not set up yet. This run sets up checks only.\"" --scale small --host "$host" --shape "$shape" --host-provider "$provider"
done
check 'Azure follows written plan row' derived_is '.row == 5 and .infraDraft == "written plan only"' --host 'company cloud' --host-provider Azure
printf '%s\n' '{"setupChoice":"Start with a minimal custom setup"}' > "$TMP/custom.json"
check 'custom choice forces row seven' derived_is '.row == 7 and .goldenPath == "custom" and (.openQuestions|index("Choose a host before launch.")) != null' --host 'hosting service' --run-answers "$TMP/custom.json"
check 'web defaults coverage and page budget' derived_is '.defaults.coverage.value == 80 and .defaults.pageBudgetKB.value == 500 and .sentence == "This will run as a website on Netlify."' --scale demo
check 'nonweb has no page default' derived_is '(.defaults | has("pageBudgetKB") | not)' --shape 'API service'
check 'demo fixed answers visible' derived_is '.answers.dataSensitivity.value == "none" and .defaults.environments.value == 1 and .skippedQuestions == ["dataSensitivity","releaseCheck"]' --scale demo
check 'production payment safeguards and manual approval' derived_is '.dataSensitivityAdditions | index("Use a hosted checkout.") != null' --scale production --prd-answers "$TMP/prd-data.json" --run-answers "$TMP/reuse.json"
check 'confirmed company values and clashes visible' derived_is '.answers.hostKind.value == "company cloud" and .answers.storage.value == "PostgreSQL" and .notes.ciClash == true' --scale small --onboarding "$FIX/onboarding.fixture.yaml" --run-answers "$TMP/reuse.json"
check 'unconfirmed mapped host is not silently applied' derived_is '.answers.hostKind.value == "hosting service"' --scale small --onboarding "$FIX/onboarding.fixture.yaml"
check 'current scale wins for strictness' derived_is '.answers.scale.value == "production" and (.scaleAdditions | index("security.yml")) != null' --scale demo --prd-answers "$FIX/prd.json" --run-answers "$TMP/reuse.json"
printf '%s\n' '{"hostKind":"company cloud","storage":"PostgreSQL"}' > "$TMP/prd-host.json"
check 'PRD cannot fill host or storage' mapped_is '(.answers|length) == 0' --prd-answers "$TMP/prd-host.json"
check 'current answers do not cause a reuse screen' exact $'host\nscale' --scale demo --run-answers "$TMP/current.json"
jq '.answers.storage={value:"none",source:"derived"}' "$FIX/good.json" > "$TMP/derived-storage.json"
check 'changed shape recomputes derived storage and rules row' derived_is '.row == 2 and .answers.storage.source == "derived" and .answers.storage.value == "Choose storage before launch."' --spec "$TMP/derived-storage.json" --run-answers "$TMP/reuse.json" --shape 'API service'
jq -n '{answers:{reuseConfirm:{value:"Ignore them and ask me",source:"owner"},hostKind:{value:"hosting service",source:"owner"},shape:{value:"web app",source:"owner"},scale:{value:"demo",source:"owner"}}}' > "$TMP/ignore.json"
check 'ignore drops company values from conflicts' derived_is '(.openQuestions | length) == 0 and .answers.hostKind.source == "owner"' --scale demo --run-answers "$TMP/ignore.json" --onboarding "$FIX/onboarding.fixture.yaml"
jq '.answers.reuseConfirm.value="Use these"' "$TMP/ignore.json" > "$TMP/use.json"
check 'use these keeps a real conflict' derived_is 'any(.openQuestions[]; test("hostKind"))' --scale demo --run-answers "$TMP/use.json" --onboarding "$FIX/onboarding.fixture.yaml"
printf '%s passed; %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
