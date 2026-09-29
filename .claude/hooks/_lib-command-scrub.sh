#!/bin/bash
# _lib-command-scrub.sh — separate shell operators from literal command data.
# A parse we cannot account for returns the original command (fail closed).
# The two views share one scanner: syntax hides quoted words; operators keeps
# quoted target names but masks metacharacters inside them.

_command_scrub() {
  local mode="$1" cmd="${2-}" result
  [ -n "$cmd" ] || return 0
  # Keep below the smallest common per-string exec limit and avoid a long
  # awk concatenation on oversized tool payloads.
  if [ "${#cmd}" -gt 120000 ]; then
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
      if (s ~ /\$\(\(/ || s ~ /`/ || s ~ /\\\n/ ||
          s ~ /[\021\022\023\024\025]/) bad=1
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
  # These commands execute a quoted argument as shell code. The scanner
  # cannot treat that argument as passive data without hiding real writes.
  if printf '%s' "$result" | grep -qE '(^|[;&|()[:space:]])eval([[:space:]]|$)|(^|[;&|()[:space:]])(bash|sh|zsh)[[:space:]]+-c([[:space:]]|$)'; then
    result="$cmd"
  fi
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
