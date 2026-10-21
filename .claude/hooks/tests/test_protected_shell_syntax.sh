#!/bin/bash
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/_test-protected-state.sh"
probe() {
  jq -cn --arg cwd "$TMP/live" --arg command "$1" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$command}}' | /bin/bash "$ROOT/block-protected-target-writes.sh"
}
check 2 'copy destination before redirect' probe 'cp x .claude/hooks/x.sh > /tmp/log'
check 0 'copy source remains read only before redirect' probe 'cp .claude/settings.json /tmp/bak > /tmp/log'
check 2 'install destination before fd redirect' probe 'install -D x .claude/hooks/x.sh 2>/tmp/log'
check 0 'target-directory copy with redirect' probe 'cp -t /tmp/bak .claude/settings.json > /tmp/log'
check 2 'background copy is still a write' probe 'cp x .claude/hooks/x.sh & echo done'
check 2 'quoted input operator is an operand' probe 'mytool "<" .claude/hooks/x.sh'
check 2 'quoted output operator is an operand' probe 'cp x ">" .claude/hooks/x.sh'
check 0 'quoted fd number is an operand' probe 'cp .claude/settings.json "2">/tmp/log'
read_text=$(printf "cat <<'DOC'\nDon't change .claude/hooks/x.sh\nDOC\n")
check 0 'quoted heredoc data' probe "$read_text"
write_text=$(printf "cat > /tmp/log <<'DOC'\nDon't change .claude/hooks/x.sh\nDOC\n")
check 0 'quoted heredoc data with safe output' probe "$write_text"
shell_text=$(printf "bash <<'SCRIPT'\ngit apply x.patch\nSCRIPT\n")
check 2 'shell stdin program is checked' probe "$shell_text"
check 2 'shell here string program is checked' probe 'bash <<<"touch .claude/hooks/x.sh"'
check 0 'ordinary here string is data' probe 'cat <<<"touch .claude/hooks/x.sh"'
source_text=$(printf "source /dev/stdin <<'SCRIPT'\necho x > .claude/hooks/x.sh\nSCRIPT\n")
check 2 'sourced stdin program is checked' probe "$source_text"
check 2 'sourced here string program is checked' probe 'source /dev/stdin <<<"touch .claude/hooks/x.sh"'
source_text=$(printf "source /dev/stdin <<'SCRIPT'\ncd .claude/hooks\nSCRIPT\ntouch x.sh\n")
check 2 'sourced stdin directory persists' probe "$source_text"
probe_scratch() {
  jq -cn --arg cwd "$TMP/scratch" --arg command "$1" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$command}}' | /bin/bash "$ROOT/block-protected-target-writes.sh"
}
printf '%s\n' '--- /dev/null' "+++ $TMP/live/.claude/hooks/x.sh" > "$TMP/headers.diff"
check 2 'patch header from input redirect' probe_scratch "patch -p0 < $TMP/headers.diff"
printf '%s\n' '--- /dev/null' "+++ $TMP/scratch/x.sh" > "$TMP/safe.diff"
check 0 'safe patch header from input redirect' probe_scratch "patch -p0 < $TMP/safe.diff"
check 2 'subshell directory stack is private' probe "pushd $TMP/scratch; ( pushd $TMP/live/.claude/hooks ); popd; touch .claude/hooks/x.sh"
check 0 'subshell directory stack safe destination' probe "pushd $TMP/scratch; ( pushd $TMP/live/.claude/hooks ); popd; touch $TMP/scratch/x.sh"
check 2 'bash child directory stack is private' probe "pushd $TMP/scratch; bash -c 'pushd $TMP/live/.claude/hooks'; popd; touch .claude/hooks/x.sh"
check 2 'subshell variable assignments are private' probe 'p=.claude/hooks/x.sh; ( p=/tmp/x ); echo x > "$p"'
check 2 'bash child variable assignments are private' probe 'p=.claude/hooks/x.sh; bash -c '"'"'p=/tmp/x'"'"'; echo x > "$p"'
check 2 'background directory change is private' probe "cd $TMP/scratch & touch .claude/hooks/x.sh"
check 2 'pipeline directory change is private' probe "cd $TMP/scratch | cat; touch .claude/hooks/x.sh"
check 2 'redirect file named source is not a source command' probe 'python3 -c "import sys;open(sys.argv[1],'"'"'w'"'"')" &> source .claude/hooks/x.sh'
shell_text=$(printf "bash <<'SCRIPT' | cat\ntouch .claude/hooks/x.sh\nSCRIPT\n")
check 2 'shell stdin program in a pipeline' probe "$shell_text"
source_text=$(printf "source /dev/fd/3 3<<'SCRIPT'\ntouch .claude/hooks/x.sh\nSCRIPT\n")
check 2 'sourced declared descriptor program' probe "$source_text"
finish
