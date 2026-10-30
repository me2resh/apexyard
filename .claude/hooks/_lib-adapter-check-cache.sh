#!/bin/bash
# Cache the advisory adapter comparison, including its original diagnostics.
# Perl and its core modules are already required by the adapter generator.
adapter_check_fingerprint() {
  perl -MDigest::SHA -MFile::Find -e '
    use strict; use warnings;
    local $SIG{__WARN__} = sub { die @_ };
    die "symlink output root\n" if -l ".agents" || -l ".codex";
    my @roots = @ARGV;
    my @paths;
    for my $root (@roots) {
      push @paths, $root;
      if (-d $root && !-l $root) {
        find({no_chdir => 1, wanted => sub { push @paths, $File::Find::name }}, $root);
      }
    }
    my $sha = Digest::SHA->new(256);
    for my $path (sort @paths) {
      die "symlink input\n" if -l $path;
      $sha->add($path, "\0");
      if (-f $path) {
        open my $fh, "<", $path or die "$path: $!";
        binmode $fh;
        $sha->add("file\0"); $sha->addfile($fh);
      } elsif (-d $path) { $sha->add("directory"); }
      elsif (!-e $path) { $sha->add("missing"); }
      else { die "unsupported input\n"; }
      $sha->add("\0");
    }
    print $sha->hexdigest;
  ' bin/sync-codex-adapter.sh .claude/hooks/_lib-adapter-check-cache.sh \
    .claude/settings.json .claude/harness-models.json .claude/skills .claude/agents \
    .agents/skills .codex/agents .codex/hooks.json .codex/apexyard-adapter.json
}

adapter_check_cached() {
  local cache_dir="$REPO_ROOT/.claude/session" cache hash saved rc output tmp warning
  warning=$(printf '%b' 'ApexYard: installed Codex adapter may be stale \342\200\224 run bash bin/sync-codex-adapter.sh --reconcile-installed.')
  cache="$cache_dir/codex-adapter-check"
  hash=$(adapter_check_fingerprint 2>/dev/null) || hash=""
  if [ -n "$hash" ] && [ -f "$cache" ]; then
    saved=$(jq -er --arg hash "$hash" '
      select(.hash == $hash and .complete == true and (.diagnostic | type == "string"))
      | .diagnostic
    ' "$cache" 2>/dev/null) && {
      [ -z "$saved" ] || printf '%s\n' "$saved" >&2
      return 0
    }
  fi
  rc=0
  output=$(_apexyard_gh_watchdog 5 bash "$CODEX_RECONCILER" --check-installed 2>&1 >/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$warning" >&2
    [ -z "$output" ] || printf '%s\n' "$output" >&2
  fi
  # Cache success and confirmed drift only. Failures and timeouts retry.
  if [ -n "$hash" ] && { [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && [[ "$output" == *DRIFT:* ]]; }; }; then
    if mkdir -p "$cache_dir" && tmp=$(mktemp "$cache_dir/adapter-check.XXXXXX"); then
      saved=""
      if [ "$rc" -ne 0 ]; then
        saved="$warning"
        [ -z "$output" ] || saved="$saved
$output"
      fi
      if ! jq -n --arg hash "$hash" --arg diagnostic "$saved" \
        '{hash: $hash, complete: true, diagnostic: $diagnostic}' > "$tmp"; then
        rm -f "$tmp"
        return 0
      fi
      mv -f "$tmp" "$cache"
    fi
  fi
  return 0
}
