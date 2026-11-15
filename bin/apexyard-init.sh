#!/usr/bin/env bash
# Create an ops repository with the full framework history.
set -euo pipefail
# Testers opt in before launch. Keep release coordinates together.
cockpit_enabled=${APEXYARD_COCKPIT:-0}
# The adopter sets the install source and the setup command. No default exists.
COCKPIT_SOURCE=${APEXYARD_COCKPIT_SOURCE:-}
COCKPIT_CMD=${APEXYARD_COCKPIT_CMD:-}
COCKPIT_TAG=${APEXYARD_COCKPIT_TAG:-v0.15.2}
cockpit=0
usage() {
  echo 'Usage: apexyard init [--org X] [--name ops] [--private|--public] [--dir PATH] [--ref REF] [--agent NAME] [--dry-run] [-i|--interactive] [-y|--yes]'
  if [ "$cockpit_enabled" = 1 ]; then
    echo '  --cockpit  Install the Cockpit after repository setup.'
  fi
}
fail() { echo "apexyard init: $*" >&2; exit 2; }
org='' name=ops visibility=--private target='' dry_run=0 agent=claude
org_set=0 name_set=0 visibility_set=0 target_set=0 agent_set=0
interactive=0 yes=0
[ ! -t 0 ] || interactive=1
ref=${APEXYARD_FRAMEWORK_REF:-main}
framework=${APEXYARD_FRAMEWORK_URL:-https://github.com/me2resh/apexyard.git}
gh_cmd=${APEXYARD_GH:-gh}
pipx_cmd=${APEXYARD_PIPX:-pipx}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --org|--name|--dir|--ref|--agent)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 requires a value"
      case "$1" in
        --org) org=$2; org_set=1 ;; --name) name=$2; name_set=1 ;;
        --dir) target=$2; target_set=1 ;; --ref) ref=$2 ;; --agent) agent=$2; agent_set=1 ;;
      esac
      shift 2 ;;
    --private|--public) visibility=$1; visibility_set=1; shift ;;
    -i|--interactive) interactive=1; shift ;;
    -y|--yes) yes=1; shift ;;
    --cockpit)
      [ "$cockpit_enabled" = 1 ] || fail "unknown option: $1"
      cockpit=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done
[ "$yes" -eq 0 ] || interactive=0
# No terminal and no --yes: never ask and never guess. Name each missing flag.
if [ "$interactive" -eq 0 ] && [ "$yes" -eq 0 ]; then
  missing=''
  [ "$org_set" -eq 1 ] || missing="$missing --org"
  [ "$name_set" -eq 1 ] || missing="$missing --name"
  [ -z "$missing" ] || fail "no terminal, so it cannot ask. Missing flags:${missing}. Pass each flag, or add --yes to accept the defaults."
fi
validate() {
  case "$1" in
    org) case "$2" in ''|*[!a-zA-Z0-9_-]*) echo 'invalid organisation name'; return 1 ;; esac ;;
    name) case "$2" in ''|.|..|*[!a-zA-Z0-9_.-]*) echo 'invalid repository name'; return 1 ;; esac ;;
    agent) case "$2" in
      claude|codex|cursor|opencode|pi|other) ;;
      *) echo "invalid agent: $2"; return 1 ;;
    esac ;;
    target)
      if [ -e "$2" ] || [ -L "$2" ]; then
        [ -d "$2" ] || { echo "target is not a directory: $2"; return 1; }
        [ -z "$(ls -A "$2")" ] || { echo "target directory is not empty: $2"; return 1; }
      fi ;;
  esac
}
repo_exists() {
  "$gh_cmd" repo view "$org/$1" --json name >/dev/null 2>&1
}
ask() {
  local kind=$1 question=$2 default=$3 reason
  while :; do
    printf '%s [%s]: ' "$question" "$default" >&2
    # A last line with no newline is still an answer.
    IFS= read -r answer || [ -n "$answer" ] || fail "no answer for $question"
    [ -n "$answer" ] || answer=$default
    if [ "$kind" = target ]; then
      # The shell does not expand ~ in a typed answer. Match it literally.
      # shellcheck disable=SC2088
      case "$answer" in '~') answer=$HOME ;; '~/'*) answer="$HOME/${answer#\~/}" ;; esac
    fi
    if [ "$kind" = visibility ]; then
      answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
      case "$answer" in private|public) return 0 ;; esac
      echo 'enter private or public' >&2
    elif reason=$(validate "$kind" "$answer"); then
      if [ "$kind" = name ] && repo_exists "$answer"; then
        printf '%s/%s already exists on GitHub. Choose a different name.\n' "$org" "$answer" >&2
      else
        return 0
      fi
    else
      printf '%s\n' "$reason" >&2
    fi
  done
}
reason=$(validate agent "$agent") || fail "$reason"
for tool in git jq "$gh_cmd"; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done
if [ "$interactive" -eq 1 ]; then
  cat >&2 <<'INTRO'
ApexYard init creates your ops repo. The ops repo is your own copy of the
ApexYard framework. It holds your settings and the list of projects that
ApexYard manages for you. It is a new repo in your GitHub account, not a
fork, so it can be private. Later, 'apexyard update' brings in new
framework versions.

Answer each question, or press Enter to use the value in brackets.
Nothing is created until you confirm.

INTRO
  if [ "$org_set" -eq 0 ]; then
    login=$("$gh_cmd" api user --jq .login)
    orgs=$("$gh_cmd" api user/orgs --jq '.[].login' 2>/dev/null) || orgs=''
    if [ -n "$orgs" ]; then
      orgs=$(printf '%s\n' "$orgs" | paste -s -d ',' - | sed 's/,/, /g')
      printf 'Your account: %s. Your organisations: %s.\n' "$login" "$orgs" >&2
    else
      printf 'Your account: %s.\n' "$login" >&2
    fi
    ask org 'GitHub account or organisation for the new repo' "$login"
    org=$answer
  fi
  if [ "$name_set" -eq 0 ]; then
    ask name 'Repository name' ops
    name=$answer
  fi
  if [ "$visibility_set" -eq 0 ]; then
    ask visibility 'Private or public' private
    visibility=--$answer
  fi
  if [ "$target_set" -eq 0 ]; then
    ask target 'Folder to create' "./$name"
    target=$answer
  fi
  if [ "$agent_set" -eq 0 ]; then
    ask agent 'Coding agent (claude, codex, cursor, opencode, pi, other)' claude
    agent=$answer
  fi
fi
[ -n "$org" ] || org=$("$gh_cmd" api user --jq .login)
reason=$(validate org "$org") || fail "$reason"
reason=$(validate name "$name") || fail "$reason"
if repo_exists "$name"; then
  fail "$org/$name already exists on GitHub. Choose a different name."
fi
[ -n "$target" ] || target=$name
case "$target" in /*) ;; *) target="$PWD/${target#./}" ;; esac
reason=$(validate target "$target") || fail "$reason"
cat <<PLAN

This is what will happen:
  1. Download ApexYard ($ref) into $target.
     You get the full framework history, so updates can merge cleanly.
  2. Link your copy to the framework repo as 'upstream'.
     'apexyard update' uses this link to bring in new versions.
  3. Create the ${visibility#--} GitHub repo $org/$name and upload your copy.
     This repo is yours. It is not a fork.
  4. Create two local setup files: onboarding.yaml and apexyard.projects.yaml.
     They stay on this computer until you commit them.
PLAN
[ "$dry_run" -eq 0 ] || exit 0
if [ "$interactive" -eq 1 ]; then
  while :; do
    printf 'Create it? [Y/n] ' >&2
    IFS= read -r answer || [ -n "$answer" ] || fail 'no answer for Create it?'
    answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
    case "$answer" in
      y|yes|'') break ;;
      n|no) echo 'Nothing created.'; exit 0 ;;
      *) echo 'enter y or n' >&2 ;;
    esac
  done
fi
target_existed=0
[ ! -e "$target" ] && [ ! -L "$target" ] || target_existed=1
step=1 repo_created=0
origin_is_new_repo() {
  local origin
  origin=$(git -C "$target" remote get-url origin 2>/dev/null) || return 1
  case "$origin" in
    "https://github.com/$org/$name"|"https://github.com/$org/$name.git"|\
    "git@github.com:$org/$name"|"git@github.com:$org/$name.git"|\
    "ssh://git@github.com/$org/$name"|"ssh://git@github.com/$org/$name.git") return 0 ;;
  esac
  return 1
}
cleanup() {
  local status=$?
  [ "$status" -ne 0 ] || return 0
  # gh can create the repo and then fail the push. Never delete the only copy.
  if [ "$repo_created" -eq 0 ] && [ "$step" -eq 3 ] && { repo_exists "$name" || origin_is_new_repo; }; then
    printf 'Init stopped at step 3. The GitHub repo %s/%s exists, but the upload failed. It kept %s.\n' "$org" "$name" "$target" >&2
    printf 'Finish with: cd %s && git push -u origin main, then run /onboard.\n' "$target" >&2
  elif [ "$repo_created" -eq 1 ]; then
    printf 'Init stopped at step %s. The GitHub repo %s/%s exists. Finish with: cd %s and run /onboard.\n' "$step" "$org" "$name" "$target" >&2
  elif [ "$target_existed" -eq 0 ]; then
    rm -rf -- "$target"
    printf 'Init stopped at step %s. It removed %s. Nothing was created on GitHub.\n' "$step" "$target" >&2
  else
    printf 'Init stopped at step %s. It kept %s. Nothing was created on GitHub.\n' "$step" "$target" >&2
  fi
}
trap cleanup EXIT
echo '[1/4] Downloading ApexYard...'
git clone -q --branch "$ref" -- "$framework" "$target"
step=2
echo '[2/4] Linking to the framework repo...'
git -C "$target" remote rename origin upstream
# Reset the cloned branch name without removing its history.
git -C "$target" checkout -q -B main
version=$(git -C "$target" describe --tags --exact-match "$ref" 2>/dev/null || git -C "$target" describe --tags --always)
mkdir -p "$target/.claude"
printf '%s\n' "$version" > "$target/.claude/framework-version"
git -C "$target" add -- .claude/framework-version
if ! git -C "$target" diff --cached --quiet; then
  git -C "$target" -c user.name='ApexYard' -c user.email='apexyard@users.noreply.github.com' commit -q -m 'chore: record framework version'
fi
step=3
printf '[3/4] Creating %s/%s on GitHub...\n' "$org" "$name"
(cd "$target" && "$gh_cmd" repo create "$org/$name" "$visibility" --source=. --remote=origin --push)
repo_created=1
step=4
echo '[4/4] Creating local setup files...'
for pair in 'onboarding.example.yaml onboarding.yaml' 'apexyard.projects.yaml.example apexyard.projects.yaml'; do
  read -r example local_file <<< "$pair"
  if [ ! -e "$target/$local_file" ]; then
    cp "$target/$example" "$target/$local_file"
  fi
done
# Write only facts that init knows. The company name stays a placeholder,
# so the agent's first session still starts onboarding.
owner_name=$(git -C "$target" config user.name 2>/dev/null || true)
case "$owner_name" in
  ''|*[\"\\/\&]*) ;;
  *)
    sed "s/^  - name: \"Your Name\"/  - name: \"$owner_name\"/" "$target/onboarding.yaml" > "$target/onboarding.yaml.tmp"
    mv "$target/onboarding.yaml.tmp" "$target/onboarding.yaml" ;;
esac
# The setup skill installs these hooks too. Doing it here means it is never missed.
if [ -f "$target/bin/install-git-hooks.sh" ]; then
  (cd "$target" && bash bin/install-git-hooks.sh >/dev/null 2>&1) || true
fi
trap - EXIT

install_cockpit() {
  if [ -z "$COCKPIT_SOURCE" ] || [ -z "$COCKPIT_CMD" ]; then
    echo 'Cockpit skipped: it is not configured. Set APEXYARD_COCKPIT_SOURCE and APEXYARD_COCKPIT_CMD, then run apexyard init again or install it by hand.' >&2
    return 0
  fi
  if ! command -v "$pipx_cmd" >/dev/null 2>&1; then
    echo 'Cockpit skipped: pipx is missing. Install pipx with python3 -m pip install --user pipx, then run python3 -m pipx ensurepath. Install the premium CLI separately afterward.' >&2
    return 0
  fi
  # Leave authentication to the existing git credential configuration.
  # Suppress child output so credential diagnostics cannot expose secrets.
  if ! GIT_TERMINAL_PROMPT=0 "$pipx_cmd" install "${COCKPIT_SOURCE}@${COCKPIT_TAG}" >/dev/null 2>&1; then
    echo 'Cockpit install failed. Request access to the Cockpit package from your ApexYard contact and check your existing GitHub login, then retry.' >&2
  elif ! "$COCKPIT_CMD" setup --ops "$target" --portfolio "$target" >/dev/null 2>&1; then
    echo 'Cockpit setup failed. Check your Cockpit access with your ApexYard contact, then run the Cockpit setup command with --ops and --portfolio pointing to this repo.' >&2
  fi
}
if [ "$cockpit_enabled" = 1 ]; then
  if [ "$interactive" -eq 1 ] && [ "$cockpit" -eq 0 ]; then
    printf 'Install the Cockpit too? [y/N] ' >&2
    IFS= read -r answer || answer=n
    case "$answer" in y|Y|yes|YES|Yes) cockpit=1 ;; esac
  fi
  [ "$cockpit" -eq 0 ] || install_cockpit
fi

# Telemetry must not prevent repository creation.
# shellcheck source=bin/_lib-telemetry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib-telemetry.sh"
telemetry_notice_once || true
telemetry_send "$agent" || true

case "$agent" in
  claude) open_step="Run: cd $target && claude /onboard" ;;
  *) open_step="Open $target in $agent and run /onboard." ;;
esac
cat <<NEXT

Done. Your ops repo is $org/$name, in $target.
The rest of setup needs your answers about your company, your stack and
your first project. Your coding agent asks them in /onboard.
Next:
  1. Run 'apexyard doctor'. It checks jq and the GitHub CLI and offers to install a missing one.
  2. $open_step
  3. On Windows, use Git Bash or WSL.
NEXT
if [ "$interactive" -eq 1 ] && [ "$agent" = claude ] && command -v "${APEXYARD_AGENT_CMD:-claude}" >/dev/null 2>&1; then
  printf 'Open it in Claude now and start /onboard? [Y/n] ' >&2
  IFS= read -r answer || answer=n
  answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
  case "$answer" in
    y|yes|'') cd "$target" && exec "${APEXYARD_AGENT_CMD:-claude}" /onboard ;;
  esac
fi
