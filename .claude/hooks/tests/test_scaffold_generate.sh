#!/usr/bin/env bash
# Prove each floor gate with local fake tools.
set -euo pipefail
root=${APEXYARD_TEST_SRC_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
lib=$root/.claude/skills/scaffold/lib
fix=$root/.claude/hooks/tests/fixtures/scaffold
node=$fix/floor-node
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
check() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; pass=$((pass+1)); }
fails() { if "$@" > "$tmp/failure.log" 2>&1; then return 1; fi; }
contains() { [[ $(cat "$1") == *"$2"* ]]; }
generate() { bash "$lib/generate.sh" --spec "$1" --target "$2" --name fixture > "$tmp/output"; }
for pair in 'node:web app' 'python:API service' 'go:data pipeline' 'custom:other' 'none:other'; do
  kind=${pair%%:*} shape=${pair#*:}
  jq --arg shape "$shape" '.answers.shape={value:$shape,source:"owner"} | .answers.hostKind={value:"server or container",source:"owner"}' "$fix/good.json" > "$tmp/$kind.json"
  if [ "$kind" = custom ]; then
    jq '.customStack={value:"Elixir",source:"owner"} | .answers.setupChoice={value:"Start with a minimal custom setup",source:"owner"}' "$tmp/$kind.json" > "$tmp/edit.json"
    cp "$tmp/edit.json" "$tmp/$kind.json"
  fi
  check generate "$tmp/$kind.json" "$tmp/$kind"
  check cmp "$tmp/$kind.json" "$tmp/$kind/docs/scaffold/spec.json"
  case "$kind" in node) bundle=typescript-nextjs ;; python) bundle=python-fastapi ;; go) bundle=go-data-pipeline ;; *) bundle=custom ;; esac
  check contains "$tmp/$kind/.apexyard/topology" "bundle=$bundle"
  if [ "$bundle" != custom ]; then check contains "$tmp/$kind/.apexyard/topology" "version=$(cat "$root/topologies/$bundle/VERSION")"; fi
  for file in .github/workflows/ci.yml scripts/ci/{lint,typecheck,test,build,audit,coverage-gate,audit-gate}.sh docs/scaffold/{spec.json,notes.md} docs/agdr/AgDR-0001-scaffold-choices.md; do
    check test -f "$tmp/$kind/$file"
  done
  check test ! -d "$tmp/$kind/src"
  check contains "$tmp/$kind/docs/agdr/AgDR-0001-scaffold-choices.md" 'Status: proposed.'
  check contains "$tmp/$kind/docs/agdr/AgDR-0001-scaffold-choices.md" 'Source: `owner`'
  check contains "$tmp/$kind/handbooks/architecture/migration-safety.md" 'ENFORCEMENT: blocking'
  for gate in lint typecheck test build audit coverage-gate; do check contains "$tmp/$kind/.github/workflows/ci.yml" "scripts/ci/$gate.sh"; done
  while IFS= read -r -d '' markdown; do
    result=$(bash "$root/bin/check-writing-profile.sh" --files "$markdown")
    check test -z "$result"
  done < <(find "$tmp/$kind" -type f -name '*.md' -print0)
done
check contains "$tmp/none/docs/scaffold/notes.md" 'Choose a host before launch.'
check contains "$tmp/custom/docs/scaffold/golden-path-request.md" Elixir
check contains "$tmp/custom/docs/agdr/AgDR-0001-scaffold-choices.md" Elixir
check contains "$tmp/python/scripts/ci/lint.sh" 'ruff check'
check contains "$tmp/python/scripts/ci/typecheck.sh" 'mypy --strict'
check contains "$tmp/go/scripts/ci/lint.sh" 'golangci-lint run'
check contains "$tmp/go/scripts/ci/typecheck.sh" 'go vet'
mkdir -p "$tmp/boundary"
printf 'unchanged\n' > "$tmp/boundary/sentinel"
check generate "$tmp/node.json" "$tmp/boundary/target"
check contains "$tmp/boundary/sentinel" unchanged
outside=$(find "$tmp/boundary" -type f ! -path "$tmp/boundary/target/*")
check test "$outside" = "$tmp/boundary/sentinel"
for gate in lint typecheck test build audit; do
  check contains "$tmp/custom/scripts/ci/$gate.sh" "placeholder: $gate is not set up yet. Fill scripts/ci/$gate.sh."
  check bash "$tmp/custom/scripts/ci/$gate.sh"
done
printf 'sentinel\n' > "$tmp/sentinel"
check fails generate "$tmp/node.json" "$tmp/node"
check contains "$tmp/sentinel" sentinel
printf '{}\n' > "$tmp/invalid.json"
check fails generate "$tmp/invalid.json" "$tmp/invalid"
check test ! -e "$tmp/invalid"
jq '.coverage={value:101,source:"owner"}' "$tmp/node.json" > "$tmp/invalid-coverage.json"
check fails generate "$tmp/invalid-coverage.json" "$tmp/invalid-coverage"
check test ! -e "$tmp/invalid-coverage"
mkdir "$tmp/hidden"
touch "$tmp/hidden/.keep"
check fails generate "$tmp/node.json" "$tmp/hidden"
mkdir "$tmp/link-outside"
ln -s "$tmp/link-outside" "$tmp/link"
check fails generate "$tmp/node.json" "$tmp/link"
check test ! -e "$tmp/link-outside/docs"
# Seed the secret through a copied fixture, never through generator code.
jq --rawfile secret "$node/secret.fixture" '.openQuestions=[$secret]' "$tmp/node.json" > "$tmp/secret.json"
check fails generate "$tmp/secret.json" "$tmp/secret"
check test ! -e "$tmp/secret"
mkdir "$tmp/bin"
cat > "$tmp/bin/npx" <<'TOOL'
#!/usr/bin/env bash
set -eu
[ "$1" != --no-install ] || shift
case "$1" in next) gate=lint ;; tsc) gate=typecheck ;; *) exit 2 ;; esac
[ "${FAULT:-}" != "$gate" ]
TOOL
cat > "$tmp/bin/npm" <<'TOOL'
#!/usr/bin/env bash
set -eu
case "$*" in
  'run build') [ "${FAULT:-}" != build ] ;;
  'audit --omit=dev --json') cat "$AUDIT_FIXTURE"; exit "${AUDIT_STATUS:-0}" ;;
  'run test '*) exit 0 ;;
  *) exit 2 ;;
esac
TOOL
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
cp "$node/package.json" "$tmp/node/"
for gate in lint typecheck build; do
  check bash -c 'cd "$1" && bash "scripts/ci/$2.sh"' _ "$tmp/node" "$gate"
  check fails env FAULT="$gate" bash -c 'cd "$1" && bash "scripts/ci/$2.sh"' _ "$tmp/node" "$gate"
done
coverage_proof() {
  local script=$1
  [ -f "$script" ] && bash "$script" "$node/coverage-clean.json" && fails bash "$script" "$node/coverage-low.json"
}
check coverage_proof "$tmp/node/scripts/ci/coverage-gate.sh"
check fails bash "$tmp/node/scripts/ci/coverage-gate.sh" "$tmp/missing-summary.json"
check fails bash "$tmp/node/scripts/ci/coverage-gate.sh" "$tmp/invalid.json"
# Both mutations must break the same proof used above.
check fails coverage_proof "$tmp/absent.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/always-pass.sh"
check fails coverage_proof "$tmp/always-pass.sh"
printf 'PASS: coverage proof rejects absent and always-pass gates.\n'
jq '.coverage={value:90,source:"owner"}' "$tmp/node.json" > "$tmp/higher.json"
check generate "$tmp/higher.json" "$tmp/higher"
check fails bash "$tmp/higher/scripts/ci/coverage-gate.sh" "$node/coverage-clean.json"
for audit in clean dev moderate; do
  check bash "$tmp/node/scripts/ci/audit-gate.sh" "$node/audit-$audit.json"
  check env AUDIT_FIXTURE="$node/audit-$audit.json" bash -c 'cd "$1" && bash scripts/ci/audit.sh' _ "$tmp/node"
done
check fails bash "$tmp/node/scripts/ci/audit-gate.sh" "$node/audit-high.json"
check fails env AUDIT_FIXTURE="$node/audit-high.json" AUDIT_STATUS=1 bash -c 'cd "$1" && bash scripts/ci/audit.sh' _ "$tmp/node"
check fails bash "$tmp/node/scripts/ci/audit-gate.sh" "$tmp/invalid.json"
check bash "$tmp/node/scripts/ci/audit-gate.sh" < "$node/audit-clean.json"
jq '.vulnerabilities[].severity="critical"' "$node/audit-high.json" > "$tmp/critical.json"
check fails bash "$tmp/node/scripts/ci/audit-gate.sh" "$tmp/critical.json"
check jq -e '.ticket.bootstrap_skills | index("scaffold") != null' "$root/.claude/project-config.defaults.json"
printf 'PASS: %s scaffold checks.\n' "$pass"
