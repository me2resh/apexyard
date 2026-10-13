#!/usr/bin/env bash
# Generate the floor without source code or infrastructure.
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$base/../../.." && pwd)
spec='' target='' name=''
bad() { printf 'scaffold: %s\n' "$1" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || bad 'expected an option value'
  case "$1" in
    --spec) spec=$2 ;; --target) target=$2 ;; --name) name=$2 ;;
    *) bad 'unknown option' ;;
  esac
  shift 2
done
[ -n "$spec" ] && [ -n "$target" ] || bad 'spec and target are required'
[ -z "$name" ] || [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || bad 'invalid name'
bash "$base/lib/validate-spec.sh" "$spec"
spec_json=$(cat "$spec")
# Pass saved answers as current answers. This preserves the confirmed setup.
derived=$(bash "$base/lib/next-questions.sh" --derive --spec "$spec" --run-answers "$spec")
bundle=$(jq -r '.goldenPath' <<< "$derived")
case "$bundle" in
  typescript-nextjs) language=TypeScript ;;
  python-fastapi) language=Python ;;
  go-data-pipeline) language=Go ;;
  *) language=custom ;;
esac
floor=$(jq -r '[80, (.coverage.value // 80)] | max' <<< "$spec_json")
# Scan input strings before any project file is written.
scan_git() {
  local file line
  if [ "$SCAFFOLD_SCAN_MODE" = inputs ]; then
    jq -r '.. | strings | "+" + .' "$SCAFFOLD_SCAN_SPEC"
  fi
  while IFS= read -r -d '' file; do
    while IFS= read -r line || [ -n "$line" ]; do printf '+%s\n' "$line"; done < "$file"
  done < <(find "$SCAFFOLD_SCAN_TARGET" -type f -print0)
}
git() { scan_git; }
export SCAFFOLD_SCAN_MODE=inputs SCAFFOLD_SCAN_SPEC=$spec SCAFFOLD_SCAN_TARGET=$root/handbooks
export -f git scan_git
printf '%s\n' '{"tool_input":{"command":"git commit"}}' | bash "$root/.claude/hooks/check-secrets.sh" || bad 'secret scan failed'
[ ! -L "$target" ] || bad 'target is a symbolic link'
if [ -e "$target" ]; then
  [ -d "$target" ] || bad 'target is not a directory'
  shopt -s nullglob dotglob
  entries=("$target"/*)
  [ "${#entries[@]}" -eq 0 ] || bad 'target is not empty'
  shopt -u nullglob dotglob
fi
mkdir -p "$target"
target=$(cd "$target" && pwd -P)
mkdir -p "$target"/{.github/workflows,scripts/ci,.apexyard,docs/agdr,docs/scaffold,handbooks}
cp "$spec" "$target/docs/scaffold/spec.json"
bash "$base/lib/copy-handbooks.sh" "$root/handbooks" "$target/handbooks"
printf 'bundle=%s\n' "$bundle" > "$target/.apexyard/topology"
if [ "$bundle" != custom ]; then
  printf 'version=%s\n' "$(cat "$root/topologies/$bundle/VERSION")" >> "$target/.apexyard/topology"
fi
cat > "$target/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  floor:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5
YAML
if [ "$bundle" = typescript-nextjs ]; then
  cat >> "$target/.github/workflows/ci.yml" <<'YAML'
      - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020
        with:
          node-version: '20'
      - run: npm ci
YAML
fi
for gate in lint typecheck test build audit coverage-gate; do
  printf '      - run: scripts/ci/%s.sh\n' "$gate" >> "$target/.github/workflows/ci.yml"
done
for gate in lint typecheck test build audit; do
  command=''
  case "$bundle:$gate" in
    typescript-nextjs:lint) command='npx --no-install next lint' ;;
    typescript-nextjs:typecheck) command='npx --no-install tsc --noEmit' ;;
    typescript-nextjs:test) command='npm run test -- --coverage --coverageReporters=json-summary' ;;
    typescript-nextjs:build) command='npm run build' ;;
    typescript-nextjs:audit) command='report=$(mktemp)
trap '\''rm -f "$report"'\'' EXIT
npm audit --omit=dev --json > "$report" || true
bash scripts/ci/audit-gate.sh "$report"' ;;
    python-fastapi:lint) command='ruff check .
ruff format --check .' ;;
    python-fastapi:typecheck) command='mypy --strict app/' ;;
    python-fastapi:test) command='mkdir -p coverage
pytest --cov=app --cov-report=json:coverage/python.json
jq '\''{total:{lines:{pct:.totals.percent_covered}}}'\'' coverage/python.json > coverage/coverage-summary.json' ;;
    python-fastapi:build) command='uvicorn app.main:app --help
alembic check' ;;
    go-data-pipeline:lint) command='golangci-lint run --timeout=5m' ;;
    go-data-pipeline:typecheck) command='go vet ./...' ;;
    go-data-pipeline:test) command='go test -race -coverprofile=coverage.out -covermode=atomic ./...
summary=$(go tool cover -func=coverage.out)
pct=${summary##*total:}
pct=${pct##*$'\''\t'\''}
pct=${pct%\%}
mkdir -p coverage
jq -n --arg pct "$pct" '\''{total:{lines:{pct:($pct|tonumber)}}}'\'' > coverage/coverage-summary.json' ;;
    go-data-pipeline:build) command='GOOS=linux GOARCH=amd64 go build -o /dev/null ./cmd/...' ;;
  esac
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    if [ -n "$command" ]; then printf '%s\n' "$command"; else
      printf "printf 'placeholder: %s is not set up yet. Fill scripts/ci/%s.sh.\\n'\nexit 0\n" "$gate" "$gate"
    fi
  } > "$target/scripts/ci/$gate.sh"
done
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\nfloor=%s\n' "$floor"
  cat <<'GATE'
# Read the Istanbul total.lines.pct number. Missing data fails.
jq -se --argjson floor "$floor" '
  length == 1 and (.[0].total.lines.pct |
    type == "number" and . >= $floor and . <= 100)
' "${1:-coverage/coverage-summary.json}" >/dev/null
GATE
} > "$target/scripts/ci/coverage-gate.sh"
cat > "$target/scripts/ci/audit-gate.sh" <<'GATE'
#!/usr/bin/env bash
set -euo pipefail
# Read npm audit output from a file or stdin. Ignore explicit dev-only findings.
jq -se '
  def severe: . == "high" or . == "critical";
  length == 1 and (.[0] | type == "object" and .error == null and
    ((.vulnerabilities | type) == "object" or (.advisories | type) == "object") and
    ([ (.vulnerabilities // {} | .[] | select(.isDev != true) |
         select((.severity | severe) or any(.via[]?; type == "object" and (.severity | severe)))),
       (.advisories // {} | .[] | select(.severity | severe) |
         select((.findings | length) == 0 or any(.findings[]; .dev != true))) ] | length) == 0)
' "${1:--}" >/dev/null
GATE
chmod +x "$target/scripts/ci/"*.sh
{
  printf '# Scaffold notes\n\n## Coverage format\n\n'
  printf 'Write an Istanbul summary to `coverage/coverage-summary.json`.\nUse a number at `total.lines.pct`. The coverage floor is %s percent.\n\n' "$floor"
  printf 'Non-npm stacks must replace the audit placeholder.\nPython and Go need their bundle tools before CI can run.\nNo source tree is included.\n\n## Open questions\n\n'
  jq -r '.openQuestions[] | "- " + .' <<< "$derived"
} > "$target/docs/scaffold/notes.md"
# Render the template body. Follow the body-H1 decision record convention.
{
  frontmatter=0 body=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = --- ]; then frontmatter=$((frontmatter+1)); continue; fi
    [ "$frontmatter" -ne 1 ] || continue
    if [ "$body" -eq 0 ]; then
      [ "$line" = '# {Short Title}' ] || continue
      body=1
    fi
    case "$line" in
      '<!--'*) continue ;;
      '# {Short Title}') printf '# Scaffold choices\n\nStatus: proposed.\n' ;;
      '> In the context of '*) printf '> I chose the floor from the confirmed spec. The owner must set up source code and deploy.\n' ;;
      '{Decision-relevant context '*) printf 'The spec records each answer and its source.\n' ;;
      '| {option 1}'*) printf '| Bundle | Uses known tools | Needs source code |\n' ;;
      '| {option 2}'*) printf '| Custom | Supports other stacks | Needs tool commands |\n' ;;
      'Chosen: '*)
        printf 'Chosen bundle: `%s`. Rules row: %s. Coverage floor: %s percent.\n\n' "$bundle" "$(jq -r '.row' <<< "$derived")" "$floor"
        printf 'The first matching rules row uses the host and shape answers.\n\n'
        printf 'Language: `%s`. Source: derived from the bundle.\n\n' "$language"
        printf 'The bundle pipeline supplies the tool commands.\n\n'
        jq -r '.pipeline[] | "- Pipeline: `" + . + "`. Source: `derived`."' <<< "$derived"
        jq -r '.answers | to_entries[] | "- `" + .key + "`: `" + (.value.value|tostring) + "`. Source: `" + .value.source + "`."' <<< "$derived"
        jq -r 'if .customStack then "- Custom stack: `" + .customStack.value + "`. Source: `" + .customStack.source + "`." else empty end' <<< "$spec_json"
        jq -r 'if .coverage then "- Coverage: `" + (.coverage.value|tostring) + "`. Source: `" + .coverage.source + "`." else "- Coverage: `80`. Source: `default`." end' <<< "$spec_json"
        ;;
      '- {consequence 1}') printf '%s\n' '- The floor adds checks.' ;;
      '- {consequence 2}') printf '%s\n' '- The owner must add source code and deploy.' ;;
      '- {commit/PR/deployment links}') printf '%s\n' '- `docs/scaffold/spec.json`' '- `docs/scaffold/notes.md`' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$root/templates/agdr.md"
} > "$target/docs/agdr/AgDR-0001-scaffold-choices.md"
if [ "$bundle" = custom ]; then
  {
    printf '# Golden path request\n\nStatus: draft.\n\nThe owner can file this request.\nAdd a bundle for the stack described by these answers.\n\n'
    jq -r 'if .customStack then "Stack: `" + .customStack.value + "`. Source: `" + .customStack.source + "`.\n" else "Stack: unresolved. The owner must name the stack.\n" end' <<< "$spec_json"
    jq -r '.answers | to_entries[] | "- `" + .key + "`: `" + (.value.value|tostring) + "`. Source: `" + .value.source + "`."' <<< "$spec_json"
    printf '\n## Open questions\n\nChoose the language and tool commands before implementation.\n'
  } > "$target/docs/scaffold/golden-path-request.md"
fi
# Run the unchanged hook through the read-only shim. Create no repository.
export SCAFFOLD_SCAN_MODE=tree SCAFFOLD_SCAN_TARGET=$target
printf '%s\n' '{"tool_input":{"command":"git commit"}}' | bash "$root/.claude/hooks/check-secrets.sh" || bad 'secret scan failed'
unset -f git scan_git
printf 'scaffold: generated %s\n' "$target"
