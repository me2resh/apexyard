#!/usr/bin/env bash
# Prove each floor gate with local fake tools.
set -euo pipefail
# shellcheck source=./_test-session-isolation.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
root=${APEXYARD_TEST_SRC_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
lib=$root/.claude/skills/scaffold/lib
fix=$root/.claude/hooks/tests/fixtures/scaffold
node=$fix/floor-node
tmp=$(mktemp -d)
proof_name="scaffoldstarterproof$$"
proof_ws=''
cleanup() {
  rm -rf "$tmp"
  if [ -n "$proof_ws" ]; then rm -rf "${proof_ws:?}/${proof_name:?}"; fi
}
trap cleanup EXIT
export CHECK_ENV_NETWORK=up
unset npm_config_ignore_scripts || true
pass=0
check() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; pass=$((pass+1)); }
fails() { if "$@" > "$tmp/failure.log" 2>&1; then return 1; fi; }
contains() { [[ $(cat "$1") == *"$2"* ]]; }
generate() { bash "$lib/generate.sh" --spec "$1" --target "$2" --name "$(basename "$2")" > "$tmp/output"; }
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
  if [ "$kind" = node ]; then
    check test -f "$tmp/$kind/src/app/api/health/route.ts"
    check test -f "$tmp/$kind/package-lock.json"
    check test ! -d "$tmp/$kind/node_modules"
    check test ! -d "$tmp/$kind/.next"
    check cmp "$root/topologies/typescript-nextjs/starter/scripts/audit-gate.sh" "$tmp/$kind/scripts/ci/audit-gate.sh"
    check cmp "$root/topologies/typescript-nextjs/starter/scripts/coverage-gate.sh" "$tmp/$kind/scripts/ci/coverage-gate.sh"
    check contains "$tmp/$kind/package.json" '"dev:fresh"'
    check contains "$tmp/$kind/package.json" '"data:reset"'
    check contains "$tmp/$kind/src/infrastructure/session.ts" 'HttpOnly'
    check contains "$tmp/$kind/src/infrastructure/session.ts" 'SameSite=Lax'
    check contains "$tmp/$kind/src/infrastructure/problem.ts" 'application/problem+json'
    check contains "$tmp/$kind/.gitignore" '.env*'
    check contains "$tmp/$kind/.gitignore" '!.env.example'
    check contains "$tmp/$kind/.github/workflows/ci.yml" "node-version: '22'"
    check contains "$tmp/$kind/.github/workflows/ci.yml" "scripts/exact-pins.sh"
    check contains "$tmp/$kind/scripts/ci/lint.sh" 'eslint .'
    check contains "$tmp/$kind/scripts/ci/test.sh" 'npm run test -- --coverage.reporter=json-summary'
    check contains "$tmp/$kind/docs/agdr/AgDR-0001-scaffold-choices.md" 'sql.js'
    check contains "$tmp/$kind/docs/scaffold/notes.md" 'The starter source tree is copied.'
    check bash -c 'jq -e '\''[.dependencies,.devDependencies] | map(to_entries[].value) | all(.[]; test("^[0-9]+[.][0-9]+[.][0-9]+$"))'\'' "$1" >/dev/null' _ "$tmp/$kind/package.json"
  else
    check test ! -d "$tmp/$kind/src"
    check contains "$tmp/$kind/docs/scaffold/notes.md" 'No source tree is included.'
  fi
  check contains "$tmp/$kind/.github/workflows/ci.yml" 'persist-credentials: false'
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
check contains "$tmp/custom/scripts/ci/audit.sh" '::warning::'
check test -x "$tmp/custom/scripts/exact-pins.sh"
bash -c 'cd "$1" && bash scripts/exact-pins.sh' _ "$tmp/custom" > "$tmp/pins.out"
check contains "$tmp/pins.out" '::warning::'
check contains "$tmp/custom/docs/scaffold/notes.md" 'HttpOnly'
check contains "$tmp/custom/docs/scaffold/notes.md" 'SameSite=Lax'
check contains "$tmp/custom/docs/scaffold/notes.md" 'application/problem+json'
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
case "$1" in eslint) gate=lint ;; tsc) gate=typecheck ;; *) exit 2 ;; esac
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
check fails bash "$tmp/node/scripts/ci/audit-gate.sh" "$node/audit-dev-high.json"
check fails env AUDIT_FIXTURE="$node/audit-high.json" AUDIT_STATUS=1 bash -c 'cd "$1" && bash scripts/ci/audit.sh' _ "$tmp/node"
check fails bash "$tmp/node/scripts/ci/audit-gate.sh" "$tmp/invalid.json"
check bash "$tmp/node/scripts/ci/audit-gate.sh" < "$node/audit-clean.json"
jq '.vulnerabilities[].severity="critical"' "$node/audit-high.json" > "$tmp/critical.json"
check fails bash "$tmp/node/scripts/ci/audit-gate.sh" "$tmp/critical.json"
check jq -e '.ticket.bootstrap_skills | index("scaffold") != null' "$root/.claude/project-config.defaults.json"
check fails bash "$lib/generate.sh" --spec "$tmp/node.json" --target "$tmp/mismatch-dir" --name fixture
check test ! -e "$tmp/mismatch-dir"
# shellcheck source=/dev/null
. "$root/.claude/hooks/_lib-portfolio-paths.sh"
proof_ws=$(portfolio_workspace_dir)
rm -rf "${proof_ws:?}/${proof_name:?}"
check bash "$lib/generate.sh" --spec "$tmp/node.json" --name "$proof_name"
check test -f "$proof_ws/$proof_name/src/app/api/health/route.ts"
check test ! -d "$proof_ws/$proof_name/node_modules"
rm -rf "${proof_ws:?}/${proof_name:?}"
check bash -c 'CHECK_ENV_NETWORK=down CHECK_ENV_INSTALL_SCRIPTS=blocked bash "$1" --spec "$2" --target "$3" --name blocked > "$4"' _ "$lib/generate.sh" "$tmp/node.json" "$tmp/blocked" "$tmp/output"
for gate in lint typecheck build coverage audit; do
  mkdir -p "$tmp/fault-$gate"
  rsync -a --exclude node_modules --exclude .next --exclude coverage --exclude data "$root/topologies/typescript-nextjs/starter/" "$tmp/fault-$gate/"
  check patch -p1 --forward --dry-run --directory "$tmp/fault-$gate" --input "$fix/starter-faults/$gate.patch"
done
check contains "$tmp/blocked/docs/agdr/AgDR-0001-scaffold-choices.md" 'check=fail'
check contains "$tmp/blocked/docs/agdr/AgDR-0001-scaffold-choices.md" 'fallback=sql.js'
check contains "$tmp/blocked/docs/agdr/AgDR-0001-scaffold-choices.md" 'install-scripts'
chmod +x "$fix/node-18.sh"
CHECK_ENV_NODE="$fix/node-18.sh" CHECK_ENV_NETWORK=up CHECK_ENV_ROOT="$tmp/node18" bash "$root/topologies/typescript-nextjs/starter/scripts/check-env.sh" > "$tmp/node18.out"
check contains "$tmp/node18.out" 'failed=node'
check contains "$tmp/node18.out" 'fallback=sql.js'
(
  set -a
  # shellcheck source=/dev/null
  . "$fix/env-blocked.env"
  set +a
  CHECK_ENV_ROOT="$tmp/envblock" bash "$root/topologies/typescript-nextjs/starter/scripts/check-env.sh"
) > "$tmp/envblock.out"
check contains "$tmp/envblock.out" 'fallback=sql.js'
check contains "$tmp/envblock.out" 'network'
copy_lib=$tmp/copy-starter-fn.sh
awk '
  /^copy_starter\(\)/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$lib/generate.sh" > "$copy_lib"
# shellcheck source=/dev/null
. "$copy_lib"
src=$tmp/copy-src
dest=$tmp/copy-dest
mkdir -p "$src/node_modules" "$src/nested/node_modules" "$src/data" "$src/pkg/data" \
  "$src/.next" "$src/nested/.next" "$src/coverage" "$src/nested/coverage" "$src/scripts"
printf 'x\n' > "$src/node_modules/skip.txt"
printf 'y\n' > "$src/nested/node_modules/keep.txt"
printf 'z\n' > "$src/data/skip.txt"
printf 'k\n' > "$src/pkg/data/keep.txt"
printf 'n\n' > "$src/.next/skip.txt"
printf 'n2\n' > "$src/nested/.next/keep.txt"
printf 'c\n' > "$src/coverage/skip.txt"
printf 'c2\n' > "$src/nested/coverage/keep.txt"
printf 'e\n' > "$src/.env"
printf 'ex\n' > "$src/.env.example"
printf 'el\n' > "$src/.env.local"
printf 'ne\n' > "$src/nested/.env"
printf 'nx\n' > "$src/nested/.env.example"
printf 't\n' > "$src/file.tsbuildinfo"
printf 's\n' > "$src/keep.ts"
printf 'sh\n' > "$src/scripts/ok.sh"
copy_starter "$src" "$dest"
check test ! -e "$dest/node_modules/skip.txt"
check test -f "$dest/nested/node_modules/keep.txt"
check test ! -e "$dest/data/skip.txt"
check test -f "$dest/pkg/data/keep.txt"
check test ! -e "$dest/.next/skip.txt"
check test -f "$dest/nested/.next/keep.txt"
check test ! -e "$dest/coverage/skip.txt"
check test -f "$dest/nested/coverage/keep.txt"
check test ! -e "$dest/.env"
check test ! -e "$dest/.env.local"
check test ! -e "$dest/nested/.env"
check test -f "$dest/.env.example"
check test -f "$dest/nested/.env.example"
check test ! -e "$dest/file.tsbuildinfo"
check test -f "$dest/keep.ts"
check test -x "$dest/scripts/ok.sh"
printf 'PASS: %s scaffold checks.\n' "$pass"
