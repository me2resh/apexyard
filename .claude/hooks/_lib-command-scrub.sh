#!/bin/bash
# _lib-command-scrub.sh — separate shell operators from literal command data.
#
# Scope (AgDR-0181, AgDR-0192): only these consumers may use the scrubbed view —
#   (a) the write detector (_lib-detect-bash-write.sh) for redirect presence
#       and target questions asked by the ticket and migration gates
#   (b) auto-code-review.sh PostToolUse trigger matching
#   (c) block-ambient-tracker-repo.sh for tracker-command matching
# Routing, merge detection, and other command matchers read the raw command.
#
# Scrub only when every command word is on the data-only allowlist and the
# raw text has no executing $( / backtick / <( / >( / <<< outside single
# quotes and outside quoted heredoc bodies. Otherwise return the raw
# command. When unsure, return raw.

# Normalize a command word for allowlist comparison: drop quotes and
# backslashes, then strip a leading path so /bin/cat and \cat become cat.
# Uses a portable tr class (GNU and BSD) that stays silent on stderr.
_command_scrub_norm_word() {
  local flat
  flat=$(printf '%s' "${1-}" | tr -d "'\"\\\\")
  flat="${flat##*/}"
  printf '%s' "$flat"
}

# Return 0 when scrubbing is safe. Return 1 when the caller must keep raw.
_command_scrub_allowlist_ok() {
  local cmd="${1-}" verdict
  [ -n "$cmd" ] || return 1
  if [ "${#cmd}" -gt 120000 ]; then
    return 1
  fi
  if ! command -v awk >/dev/null 2>&1; then
    return 1
  fi
  verdict=$(COMMAND_SCRUB_INPUT="$cmd" awk '
    function norm_word(w,    t) {
      t = w
      gsub(/["\047\\]/, "", t)
      sub(/^.*\//, "", t)
      return t
    }
    function is_assign(t) {
      return t ~ /^[A-Za-z_][A-Za-z0-9_]*=/
    }
    function is_reserved(t) {
      return t == "then" || t == "do" || t == "else" || t == "elif" || \
             t == "!" || t == "time" || t == "if" || t == "while" || \
             t == "until" || t == "for" || t == "select" || t == "case" || \
             t == "coproc" || t == "function" || t == "in" || t == "esac" || \
             t == "done" || t == "fi"
    }
    function is_allow_simple(t) {
      return t == "echo" || t == "printf" || t == "cat" || t == "grep" || \
             t == "egrep" || t == "fgrep" || t == "rg" || t == "head" || \
             t == "tail" || t == "wc" || t == "sort" || t == "uniq" || \
             t == "cut" || t == "tr" || t == "diff" || t == "cmp" || \
             t == "ls" || t == "stat" || t == "file" || t == "basename" || \
             t == "dirname" || t == "realpath" || t == "jq" || t == "yq" || \
             t == "true" || t == "false" || t == "test" || t == "[" || \
             t == "cd" || t == "pwd" || t == "mkdir" || t == "touch" || \
             t == "tee" || t == "cp" || t == "mv" || t == "rm" || \
             t == "git" || t == "gh"
    }
    # read_word may skip ahead through quotes. Reject a consumed word that
    # still holds executing $( / backticks / process substitution / <<<
    # outside single quotes.
    function word_executes(w,    i, wn, c, nx, st) {
      wn = length(w)
      st = "plain"
      for (i = 1; i <= wn; i++) {
        c = substr(w, i, 1)
        nx = substr(w, i + 1, 1)
        if (st == "single") {
          if (c == "\047") st = "plain"
          continue
        }
        if (st == "double") {
          if (c == "\"") { st = "plain"; continue }
          if (c == "\\") { i++; continue }
          if (c == "`") return 1
          if (c == "$" && nx == "(") return 1
          if (c == "<" && nx == "(") return 1
          if (c == ">" && nx == "(") return 1
          continue
        }
        if (c == "\047") { st = "single"; continue }
        if (c == "\"") { st = "double"; continue }
        if (c == "`") return 1
        if (c == "$" && nx == "(") return 1
        if (c == "<" && nx == "(") return 1
        if (c == ">" && nx == "(") return 1
        if (c == "<" && nx == "<" && substr(w, i + 2, 1) == "<") return 1
      }
      return 0
    }
    function git_sub_ok(t) {
      return t == "log" || t == "show" || t == "diff" || t == "status" || \
             t == "commit" || t == "add" || t == "rev-parse" || \
             t == "branch" || t == "ls-files" || t == "blame"
    }
    function gh_pr_ok(t) {
      return t == "view" || t == "diff" || t == "create" || t == "edit" || \
             t == "comment" || t == "review"
    }
    function gh_issue_ok(t) {
      return t == "view" || t == "comment" || t == "create" || t == "edit"
    }
    function skip_ws() {
      while (pos <= n && substr(s, pos, 1) ~ /[ \t]/) pos++
    }
    # Read one shell word starting at pos. Sets WORD and advances pos.
    function read_word(    c, q, out, esc) {
      WORD = ""
      skip_ws()
      if (pos > n) return 0
      c = substr(s, pos, 1)
      if (c ~ /[;&|(){}]/ || c == "\n") return 0
      out = ""
      while (pos <= n) {
        c = substr(s, pos, 1)
        if (esc) {
          out = out c
          esc = 0
          pos++
          continue
        }
        if (q == "") {
          if (c == "\\") { esc = 1; out = out c; pos++; continue }
          if (c == "\047") { q = "\047"; out = out c; pos++; continue }
          if (c == "\"") { q = "\""; out = out c; pos++; continue }
          if (c ~ /[ \t\n;&|(){}]/) break
          if (c == "<" || c == ">" || c == "#") break
          out = out c
          pos++
          continue
        }
        if (q == "\047") {
          out = out c
          pos++
          if (c == "\047") q = ""
          continue
        }
        # double-quoted
        if (c == "\\" && pos < n) {
          out = out c substr(s, pos + 1, 1)
          pos += 2
          continue
        }
        out = out c
        pos++
        if (c == "\"") q = ""
      }
      WORD = out
      return (WORD != "")
    }
    function peek_two(    a, b) {
      a = substr(s, pos, 1)
      b = substr(s, pos + 1, 1)
      return a b
    }
    # After a command word was accepted, ensure git/gh subcommands are safe.
    # Consumes trailing words of this simple command (stops at separators).
    function check_git_or_gh(cmdw,    tok, saw_c, subcmd, skip_arg, ntok) {
      if (cmdw != "git" && cmdw != "gh") return 1
      saw_c = 0
      subcmd = ""
      skip_arg = 0
      ntok = 0
      while (read_word()) {
        if (word_executes(WORD)) return 0
        tok = norm_word(WORD)
        if (tok == "") continue
        if (skip_arg) { skip_arg = 0; continue }
        if (cmdw == "git") {
          if (WORD ~ /^-c/ || tok == "-c") { saw_c = 1; break }
          if (tok == "-C" || tok == "--git-dir" || tok == "--work-tree" || \
              tok == "--namespace" || tok == "--super-prefix") {
            skip_arg = 1
            continue
          }
          if (WORD ~ /^--git-dir=/ || WORD ~ /^--work-tree=/ || \
              WORD ~ /^--namespace=/) continue
          if (substr(WORD, 1, 1) == "-") continue
          subcmd = tok
          break
        }
        # gh
        if (tok == "-R" || tok == "--repo" || tok == "-h" || tok == "--help") {
          if (tok == "-R" || tok == "--repo") skip_arg = 1
          continue
        }
        if (WORD ~ /^--repo=/) continue
        if (substr(WORD, 1, 1) == "-") continue
        ntok++
        if (ntok == 1) {
          if (tok == "api") return 1
          if (tok == "pr" || tok == "issue") {
            # The syntax view blanks quoted words. Keep raw so a quoted
            # tracker subcommand cannot disappear from the tracker gate.
            if (WORD ~ /["\047\\]/) return 0
            subcmd = tok
            continue
          }
          return 0
        }
        if (ntok == 2) {
          if (subcmd == "pr") return gh_pr_ok(tok)
          if (subcmd == "issue") return gh_issue_ok(tok)
          return 0
        }
        break
      }
      if (cmdw == "git") {
        if (saw_c) return 0
        if (subcmd == "") return 0
        return git_sub_ok(subcmd)
      }
      # gh with only one token that was not api
      if (subcmd == "pr" || subcmd == "issue") return 0
      return 0
    }
    BEGIN {
      s = ENVIRON["COMMAND_SCRUB_INPUT"]
      n = length(s)
      SQ = sprintf("%c", 39)
      DQ = sprintf("%c", 34)
      BS = sprintf("%c", 92)
      pos = 1
      state = "plain"
      cmd_start = 1
      pending = 0
      ok = 1
      while (pos <= n && ok) {
        c = substr(s, pos, 1)
        nextc = substr(s, pos + 1, 1)
        if (state == "single") {
          if (c == SQ) state = "plain"
          pos++
          continue
        }
        if (state == "double") {
          if (c == DQ) { state = "plain"; pos++; continue }
          if (c == BS && (nextc == DQ || nextc == BS || nextc == "$")) {
            pos += 2
            continue
          }
          if (c == "$" && nextc == "(") { ok = 0; break }
          if (c == "`") { ok = 0; break }
          if (c == "<" && nextc == "(") { ok = 0; break }
          if (c == ">" && nextc == "(") { ok = 0; break }
          pos++
          continue
        }
        if (state == "heredoc") {
          # Consume through the terminator line. Quoted bodies are data.
          # Unquoted bodies must not hold $( or backticks.
          line_start = pos
          while (pos <= n && substr(s, pos, 1) != "\n") pos++
          line = substr(s, line_start, pos - line_start)
          check = line
          if (hd_tabs[hd_index]) sub(/^\t+/, "", check)
          if (!hd_quoted[hd_index]) {
            if (index(line, "$(") || index(line, "`")) { ok = 0; break }
            if (index(line, "<(") || index(line, ">(") || index(line, "<<<")) {
              ok = 0
              break
            }
          }
          if (pos <= n && substr(s, pos, 1) == "\n") pos++
          if (check == hd_delim[hd_index]) {
            hd_index++
            if (hd_index > pending) {
              state = "plain"
              cmd_start = 1
              pending = 0
            }
          }
          continue
        }
        # plain
        if (c == BS) {
          if (pos == n) { ok = 0; break }
          # Escaped newline is line continuation — treat as whitespace.
          if (nextc == "\n") { pos += 2; continue }
          if (cmd_start) {
          # Beginning of a word that starts with a backslash.
          save = pos
          if (!read_word()) { ok = 0; break }
          if (word_executes(WORD)) { ok = 0; break }
          w = norm_word(WORD)
          if (w == "") { ok = 0; break }
          # A leading assignment can name a program (GIT_PAGER, EDITOR). Return raw.
          if (is_assign(WORD)) { ok = 0; break }
          if (is_reserved(w)) { cmd_start = 1; continue }
          if (w == "gh" && WORD ~ /["\047\\]/) { ok = 0; break }
          if (!is_allow_simple(w)) { ok = 0; break }
          if (!check_git_or_gh(w)) { ok = 0; break }
          cmd_start = 0
          continue
        }
          pos += 2
          continue
        }
        if (c == SQ) {
          # At command-start a quote begins a command word, not a data span.
          if (!cmd_start) { state = "single"; pos++; continue }
        }
        if (c == DQ) {
          if (!cmd_start) { state = "double"; pos++; continue }
        }
        if (c == "`") { ok = 0; break }
        if (c == "$" && nextc == "(") { ok = 0; break }
        if (c == "<" && nextc == "(") { ok = 0; break }
        if (c == ">" && nextc == "(") { ok = 0; break }
        if (c == "<" && nextc == "<") {
          third = substr(s, pos + 2, 1)
          if (third == "<") { ok = 0; break }  # <<<
          # Heredoc opener.
          j = pos + 2
          tabs = 0
          if (substr(s, j, 1) == "-") { tabs = 1; j++ }
          while (j <= n && substr(s, j, 1) ~ /[ \t]/) j++
          q = substr(s, j, 1)
          if (q == SQ || q == DQ) {
            j++
            start = j
            while (j <= n && substr(s, j, 1) != q) j++
            if (j > n) { ok = 0; break }
            delim = substr(s, start, j - start)
            j++
            quoted = 1
          } else {
            start = j
            while (j <= n && substr(s, j, 1) ~ /[A-Za-z0-9_]/) j++
            delim = substr(s, start, j - start)
            quoted = 0
          }
          if (delim == "") { ok = 0; break }
          # The body starts at the next newline. Check the rest of this
          # command line first, including any more heredoc openers.
          after = substr(s, j, 1)
          if (after != "" && after !~ /[[:space:];|&()<>]/) { ok = 0; break }
          pending++
          hd_delim[pending] = delim
          hd_quoted[pending] = quoted
          hd_tabs[pending] = tabs
          pos = j
          continue
        }
        if (c == "\n") {
          cmd_start = 1
          pos++
          if (pending) { hd_index = 1; state = "heredoc" }
          continue
        }
        if (c == "#" && (pos == 1 || substr(s, pos - 1, 1) ~ /[[:space:];&|()<>]/)) {
          while (pos <= n && substr(s, pos, 1) != "\n") pos++
          continue
        }
        two = peek_two()
        if (two == "&&" || two == "||") { cmd_start = 1; pos += 2; continue }
        if (c == ";" || c == "|" || c == "&" || c == "(" || c == "{" || c == ")") {
          cmd_start = 1
          pos++
          continue
        }
        if (c == "}") { cmd_start = 1; pos++; continue }
        if (c ~ /[ \t]/) { pos++; continue }
        if (cmd_start) {
          if (!read_word()) { ok = 0; break }
          if (word_executes(WORD)) { ok = 0; break }
          w = norm_word(WORD)
          if (w == "") { ok = 0; break }
          # A leading assignment can name a program (GIT_PAGER, EDITOR). Return raw.
          if (is_assign(WORD) && WORD !~ /^[A-Za-z_][A-Za-z0-9_]*==/) {
            ok = 0
            break
          }
          if (is_reserved(w)) {
            cmd_start = 1
            continue
          }
          # The tracker gate must see gh when its command word is quoted.
          if (w == "gh" && WORD ~ /["\047\\]/) { ok = 0; break }
          if (!is_allow_simple(w)) { ok = 0; break }
          if (!check_git_or_gh(w)) { ok = 0; break }
          cmd_start = 0
          continue
        }
        # Not at command start: skip this word / redirection target.
        if (c == "<" || c == ">") {
          # Redirection operator — skip optional fd digits already passed.
          if (nextc == ">" || nextc == "&" || nextc == "|") pos++
          pos++
          skip_ws()
          # Optional target word.
          if (read_word() && word_executes(WORD)) { ok = 0; break }
          continue
        }
        if (!read_word()) { pos++; continue }
        if (word_executes(WORD)) { ok = 0; break }
      }
      if (state != "plain" || pending) ok = 0
      if (ok) print "yes"; else print "no"
    }
  ' 2>/dev/null) || verdict="no"
  [ "$verdict" = "yes" ]
}

_command_scrub() {
  local mode="$1" cmd="${2-}" result
  [ -n "$cmd" ] || return 0
  # Keep below the smallest common per-string exec limit and avoid a long
  # awk concatenation on oversized tool payloads.
  if [ "${#cmd}" -gt 120000 ]; then
    printf '%s' "$cmd"
    return 0
  fi
  # Allowlist gate: scrub only data-only command words. Else keep raw.
  if ! _command_scrub_allowlist_ok "$cmd"; then
    printf '%s' "$cmd"
    return 0
  fi
  if ! command -v awk >/dev/null 2>&1; then
    printf '%s' "$cmd"
    return 0
  fi
  result=$(COMMAND_SCRUB_INPUT="$cmd" COMMAND_SCRUB_MODE="$mode" awk '
    function blank(s,    t) { t=s; gsub(/[^\n]/, " ", t); return t }
    function quoted(c) {
      if (mode == "syntax") return " "
      if (c == ">") return GT
      if (c == "<") return LT
      if (c == "|") return PIPE
      if (c == "&") return AMP
      if (c == ";") return SEMI
      return c
    }
    function word_char(c) { return c ~ /[A-Za-z0-9_]/ }
    BEGIN {
      s=ENVIRON["COMMAND_SCRUB_INPUT"]
      mode=ENVIRON["COMMAND_SCRUB_MODE"]
      n=length(s); SQ=sprintf("%c",39); DQ=sprintf("%c",34)
      BS=sprintf("%c",92); GT=sprintf("%c",17); LT=sprintf("%c",18)
      PIPE=sprintf("%c",19); AMP=sprintf("%c",20); SEMI=sprintf("%c",21)
      state="plain"; out=""; pending=0; depth=0; bad=0
      # Allowlist gate already rejected executing $( / backticks / <<< /
      # process substitution outside singles and quoted heredocs. Inside
      # those data regions the characters below are blanked as data.
      if (s ~ /\\\n/ || s ~ /[\021\022\023\024\025]/) bad=1
      for (i=1; i<=n && !bad; i++) {
        c=substr(s,i,1); nextc=substr(s,i+1,1)
        if (state == "single") {
          if (c == SQ) { state="plain"; out=out quoted(c) }
          else out=out quoted(c)
          continue
        }
        if (state == "double") {
          if (c == DQ) { state="plain"; out=out quoted(c); continue }
          if (c == "$" && nextc == "(") {
            stack[++depth]="double"; parens[depth]=1
            out=out "$("; i++; state="plain"; continue
          }
          if (c == "$" && (nextc == "{" || nextc == "[")) { bad=1; break }
          if (c == BS && (nextc == DQ || nextc == BS || nextc == "$")) {
            out=out quoted(c) quoted(nextc); i++; continue
          }
          out=out quoted(c); continue
        }
        if (c == BS) {
          if (i == n) { bad=1; break }
          out=out quoted(c) quoted(nextc); i++; continue
        }
        if (c == "$" && (nextc == SQ || nextc == DQ || nextc == "{" || nextc == "[")) {
          bad=1; break
        }
        if (c == "$" && nextc == "(") {
          stack[++depth]="plain"; parens[depth]=1
          out=out "$("; i++; continue
        }
        if (depth > 0 && c == "(") parens[depth]++
        if (depth > 0 && c == ")") {
          parens[depth]--
          if (parens[depth] == 0) { state=stack[depth]; depth-- }
        }
        if (c == SQ) { state="single"; out=out quoted(c); continue }
        if (c == DQ) { state="double"; out=out quoted(c); continue }
        if (c == "#" && (i == 1 || substr(s,i-1,1) ~ /[[:space:];&|()<>]/)) {
          j=index(substr(s,i),"\n")
          if (!j) { out=out blank(substr(s,i)); i=n; break }
          out=out blank(substr(s,i,j-1)); i+=j-2; continue
        }
        if (c == "<" && nextc == "<" && substr(s,i+2,1) != "<") {
          j=i+2; tabs=0
          if (substr(s,j,1) == "-") { tabs=1; j++ }
          while (substr(s,j,1) ~ /[ \t]/ && j<=n) j++
          q=substr(s,j,1)
          if (q == SQ || q == DQ) {
            j++; start=j
            while (j<=n && substr(s,j,1)!=q) j++
            if (j>n) { bad=1; break }
            delim=substr(s,start,j-start); j++
          } else {
            start=j
            while (j<=n && word_char(substr(s,j,1))) j++
            delim=substr(s,start,j-start)
          }
          after=substr(s,j,1)
          if (delim == "" || (after != "" && after !~ /[[:space:];|&()<>]/)) {
            bad=1; break
          }
          markers[++pending]=delim; strip_tabs[pending]=tabs
          out=out substr(s,i,j-i); i=j-1; continue
        }
        out=out c
        if (c == "\n" && pending) {
          for (h=1; h<=pending && !bad; h++) {
            found=0
            while (i<n) {
              start=i+1; j=index(substr(s,start),"\n")
              if (j) { line=substr(s,start,j-1); end=start+j-1 }
              else { line=substr(s,start); end=n }
              check=line
              if (strip_tabs[h]) sub(/^\t+/,"",check)
              out=out blank(line)
              if (j) out=out "\n"
              i=end
              if (check == markers[h]) { found=1; break }
            }
            if (!found) bad=1
          }
          pending=0
        }
      }
      if (state != "plain" || depth || pending) bad=1
      if (bad) printf "%s",s; else printf "%s",out
    }
  ' 2>/dev/null) || result="$cmd"
  [ -n "$result" ] || result="$cmd"
  printf '%s' "$result"
}

scrub_bash_command() { _command_scrub syntax "$1"; }
mask_bash_command_operators() { _command_scrub operators "$1"; }

unmask_bash_command_operators() {
  if [ "$#" -gt 0 ]; then
    printf '%s' "$1" | tr '\021\022\023\024\025' '><|&;'
  else
    tr '\021\022\023\024\025' '><|&;'
  fi
}
