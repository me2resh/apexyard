#!/bin/bash
# The shell tokenizer of block-protected-target-writes.sh (AgDR-0261 section B).
# It is one awk program in a variable, so the hooks folder holds only .sh files.
# A copy of the hooks by the *.sh glob then keeps the gate working.
# The program reads shell text as data. It never runs that text.
# shellcheck disable=SC2034 # block-protected-target-writes.sh reads it.
IFS= read -r -d '' PT_TOKENS_AWK <<'AWK' || true
# Tokenize shell text as data. Preserve substitutions; never evaluate them.
# Token kinds: W word, O operator, P case-statement syntax (not a command),
# S command-substitution body, D heredoc reference, H heredoc body.
function token(value, kind) { if (!source_view) printf "%s%s%c",kind,value,0 }
# Emit the body of each $(...) and `...` in heredoc text that expands.
function subs(s,    k,n,ch,d,start) {
  n=length(s)
  for(k=1;k<=n;k++) {
    ch=substr(s,k,1)
    if(ch=="\\") {k++;continue}
    if(ch=="$" && substr(s,k+1,1)=="(") {
      d=1; k+=2; start=k
      while(k<=n) {
        ch=substr(s,k,1)
        if(ch=="(") d++
        if(ch==")") d--
        if(!d) break
        k++
      }
      if(d) return 0
      token(substr(s,start,k-start),"S")
      continue
    }
    if(ch=="`") {
      k++; start=k
      while(k<=n && substr(s,k,1)!="`") {if(substr(s,k,1)=="\\")k++; k++}
      if(k>n) return 0
      token(substr(s,start,k-start),"S")
    }
  }
  return 1
}
function emit(    kind) {
  if (!have) return
  kind="W"
  # Case headers and patterns are not commands. Their substitutions are
  # still emitted as S tokens.
  if(cdepth && cstate[cdepth]=="hdr") {kind="P"; if(word=="in" && !quoted_word) cstate[cdepth]="pat"}
  else if(cdepth && cstate[cdepth]=="pat") {kind="P"; if(word=="esac" && !quoted_word) cdepth--}
  else if(command_start && !quoted_word && word=="case") {kind="P"; cstate[++cdepth]="hdr"}
  else if(command_start && !quoted_word && cdepth && word=="esac") {kind="P"; cdepth--}
  token(word,kind)
  if(kind=="P") {command_start=0; word=""; have=0; quoted_word=0; return}
  if (expect_here) {
    delimiter[++here_count]=word; tabs[here_count]=here_tabs; here_id[here_count]=next_here_id; expect_here=0
    here_quoted[here_count]=quoted_word
  }
  if(redir_operand) redir_operand=0
  else if (source_view && source_operand) {
    removed_start[++removed_count]=word_start; removed_end[removed_count]=i-1
    if(word=="/dev/stdin" || word=="/dev/fd/0") shell_header=1
    source_operand=0; command_start=0
  } else if (command_start) {
    if (word=="source" || word==".") {source_operand=1;command_start=0}
    else if (word !~ /^[A-Za-z_][A-Za-z_0-9]*=/ && word!="if" && word!="then" && word!="while" && word!="do") {
      shell_header=(word=="bash" || word=="sh" || word=="zsh")
      command_start=0
    }
  }
  word=""; have=0; quoted_word=0
}
function bodies(    h,start,offset,finish,line,compare,body,found) {
  for(h=1;h<=here_count;h++) {
    start=i+1; body=""; found=0
    while(start<=length(text)) {
      offset=index(substr(text,start),"\n")
      if(!offset) finish=length(text)+1; else finish=start+offset-1
      line=substr(text,start,finish-start); compare=line
      if(tabs[h]) sub(/^\t+/,"",compare)
      if(compare==delimiter[h]) { i=finish; found=1; break }
      body=body (tabs[h]?compare:line) "\n"
      start=finish+1
    }
    if(!found) return 0
    token(body,"H" here_id[h] ":")
    # An unquoted delimiter expands substitutions in the body.
    if(!here_quoted[h] && !subs(body)) return 0
  }
  here_count=0; return 1
}
{ text=text $0 "\n" }
END {
  quote=""; subdepth=0; command_start=1
  for(i=1;i<=length(text);i++) {
    c=substr(text,i,1); nextc=substr(text,i+1,1)
    if (!have && c !~ /[ \t\r\n;|&()<>]/) word_start=i
    if(subdepth) {
      word=word c
      if(c=="(")subdepth++
      if(c==")")subdepth--
      # The substitution body runs as a command. Emit it for a separate scan.
      if(!subdepth) token(substr(text,sub_start,i-sub_start),"S")
      continue
    }
    if(c=="$" && nextc=="(" && quote!="\047") {word=word "$(";have=1;subdepth=1;i++;sub_start=i+1;continue}
    if(c=="`" && quote!="\047") {
      start=i+1; j=start
      while(j<=length(text) && substr(text,j,1)!="`") {if(substr(text,j,1)=="\\")j++; j++}
      if(j>length(text)) exit 2
      token(substr(text,start,j-start),"S")
      word=word substr(text,i,j-i+1); have=1; i=j; continue
    }
    if(quote!="") {
      if(c==quote){quote="";continue}
      if(c=="\\" && quote=="\"" && (nextc=="\"" || nextc=="\\")) {word=word nextc;i++;continue}
      word=word c;continue
    }
    if(c=="\"" || c=="\047"){quote=c;have=1;quoted_word=1;continue}
    if(c=="\\"){if(nextc!="\n") {word=word nextc;have=1;quoted_word=1} i++;continue}
    if(c=="#" && !have){while(i<=length(text)&&substr(text,i,1)!="\n")i++;c="\n";nextc=""}
    if(c ~ /[ \t\r]/){emit();continue}
    if(c ~ /[;|&()\n<>]/) {
      fd=""
      if(c ~ /[<>]/ && have && !quoted_word && word ~ /^[0-9]+$/) {fd=word;word="";have=0}
      emit(); was_shell=shell_header
      newline=(c=="\n"); if(newline)c=";"
      if((c==">" && nextc ~ /[>&|]/) || (c=="<" && nextc ~ /[<>]/) || (c=="&"&&nextc ~ /[&>]/) || (c=="|"&&nextc=="|")) {c=c nextc;i++}
      # Longer output forms: the combined append "&>>", the zsh combined
      # append ">>&", and a zsh clobber suffix "!" or "|" after an output
      # operator (">!", ">>!", ">>|", "&>!", "&>>|", ">&!", ">>&|"). Each form
      # is one redirect operator.
      if(c=="&>" && substr(text,i+1,1)==">") {c="&>>";i++}
      if(c==">>" && substr(text,i+1,1)=="&") {c=">>&";i++}
      if((c==">" || c==">>" || c=="&>" || c=="&>>" || c==">&" || c==">>&") && substr(text,i+1,1) ~ /[!|]/) {c=c substr(text,i+1,1);i++}
      if(c=="<<" && substr(text,i+1,1)=="<") {c="<<<";i++}
      if(c=="<<" && substr(text,i+1,1)=="-") {c="<<-";i++}
      # A case terminator is one operator. A newline before ";;" is not part of it.
      if(c==";" && !newline && nextc==";") {c=";;";i++; if(substr(text,i+1,1)=="&") {c=";;&";i++}}
      else if(c==";" && !newline && nextc=="&") {c=";&";i++}
      # Inside a case pattern list, "(", "|" and ")" are pattern syntax.
      if(cdepth && cstate[cdepth]=="pat" && fd=="" && (c=="(" || c=="|" || c==")")) {
        token(c,"P")
        if(c==")") {cstate[cdepth]="body";command_start=1;source_operand=0;shell_header=0;redir_operand=0}
        continue
      }
      if(cdepth && cstate[cdepth]=="body" && (c==";;" || c==";&" || c==";;&")) cstate[cdepth]="pat"
      if(c==";" || c==";;" || c==";&" || c==";;&" || c=="&&" || c=="||" || c=="|" || c=="&" || c=="(" || c==")") {command_start=1;source_operand=0;shell_header=0;redir_operand=0}
      else redir_operand=1
      if(c=="<<" || c=="<<-") {
        next_here_id=++body_serial
        token(body_serial ":" (fd==""?"0":fd),"D")
      }
      token(fd c,"O")
      if(c=="<<" || c=="<<-") {expect_here=1;here_tabs=(c=="<<-")}
      if(newline && here_count) {
        # A shell's stdin is executable. Parse its source operands in the raw
        # token view. Other heredoc bodies are data in that view.
        if(source_view && was_shell) here_count=0
        else if(!bodies()) exit 2
      }
      continue
    }
    word=word c;have=1
  }
  emit()
  if(quote!="" || subdepth || expect_here || here_count || cdepth) exit 2
  # The end record shows that the whole text was read without a syntax error.
  token("","E")
  if(source_view) {
    start=1
    for(j=1;j<=removed_count;j++) {
      printf "%sLIBRARY",substr(text,start,removed_start[j]-start)
      start=removed_end[j]+1
    }
    printf "%s",substr(text,start)
  }
}
AWK
