#!/usr/bin/env bash
# source-snapshot.sh — build a read-only, sanitized source snapshot for an
# /eval-agents run with source access (#1815).
#
# Usage:
#   source-snapshot.sh <commit> <out-dir> <deny-list> [<repo-dir>]
#
# The script does these steps:
#   1. It exports the tracked files at <commit> with `git archive`. The
#      snapshot has no .git directory and no history, so the reviewer cannot
#      see the later fix commit.
#   2. It replaces each name in <deny-list> with "<project>" in file text and
#      in file and directory names. The match is literal and ignores case.
#   3. It checks that no name remains in any file or path.
#   4. It removes write permission from the whole tree.
#
# <deny-list> holds one name per line. Blank lines and lines that start with
# "#" are ignored. Keep the deny list outside the repository: it names the
# private projects that the snapshot must not show.
#
# Exit codes:
#   0 — the snapshot is ready and clean
#   2 — usage error, or the script cannot build the snapshot or cannot prove
#       that it is clean (fail closed: do not use <out-dir>)

set -euo pipefail
export LC_ALL=C

die() {
  echo "source-snapshot: $*" >&2
  exit 2
}

COMMIT="${1:-}"
OUT="${2:-}"
DENY="${3:-}"
REPO="${4:-.}"

if [ -z "$COMMIT" ] || [ -z "$OUT" ] || [ -z "$DENY" ]; then
  die "usage: source-snapshot.sh <commit> <out-dir> <deny-list> [<repo-dir>]"
fi
[ -f "$DENY" ] && [ -r "$DENY" ] || die "cannot read deny list: $DENY"
git -C "$REPO" cat-file -e "$COMMIT^{commit}" 2>/dev/null \
  || die "unknown commit: $COMMIT"
if [ -e "$OUT" ]; then
  [ -d "$OUT" ] || die "out-dir is not a directory: $OUT"
  [ -z "$(ls -A "$OUT")" ] || die "out-dir is not empty: $OUT"
fi

NAMES_FILE=$(mktemp)
trap 'rm -f "$NAMES_FILE"' EXIT

# Normalize the deny list. A name shorter than 3 characters would change
# ordinary words, so the script refuses it.
while IFS= read -r line || [ -n "$line" ]; do
  line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  case "$line" in
    '' | '#'*) continue ;;
  esac
  [ "${#line}" -ge 3 ] || die "deny-list name is shorter than 3 characters: $line"
  printf '%s\n' "$line" >> "$NAMES_FILE"
done < "$DENY"

mkdir -p "$OUT"
git -C "$REPO" archive --format=tar "$COMMIT" | tar -x -C "$OUT" \
  || die "git archive of $COMMIT failed"

redacted=0
if [ -s "$NAMES_FILE" ]; then
  # Text files: replace each name. Longer names go first, so that a name
  # that contains a shorter name is replaced as a whole.
  hits=$(grep -rlIiF -f "$NAMES_FILE" "$OUT" || true)
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | while IFS= read -r f; do
      NAMES="$NAMES_FILE" perl -pi -e '
        BEGIN {
          open(my $fh, "<", $ENV{NAMES}) or die "cannot read names\n";
          my @n = map { chomp; $_ } <$fh>;
          my $alt = join("|", map { quotemeta } sort { length($b) <=> length($a) } @n);
          $re = qr/(?:$alt)/i;
        }
        s/$re/<project>/g;
      ' "$f" || exit 2
    done || die "text redaction failed"
    redacted=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
  fi

  # File and directory names: rename from the deepest path up.
  NAMES="$NAMES_FILE" perl -MFile::Find -e '
    open(my $fh, "<", $ENV{NAMES}) or die "cannot read names\n";
    my @n = map { chomp; $_ } <$fh>;
    my $alt = join("|", map { quotemeta } sort { length($b) <=> length($a) } @n);
    my $re = qr/(?:$alt)/i;
    finddepth(sub {
      my $old = $_;
      return if $old eq ".";
      (my $new = $old) =~ s/$re/<project>/g;
      return if $new eq $old;
      die "rename target exists: $File::Find::dir/$new\n" if -e $new;
      rename($old, $new) or die "cannot rename $File::Find::name\n";
    }, $ARGV[0]);
  ' "$OUT" || die "path redaction failed"

  # Proof step. Any match left in a file (text or binary) or in a path fails
  # the snapshot.
  left=$(grep -rliF -f "$NAMES_FILE" "$OUT" || true)
  [ -z "$left" ] || die "a deny-list name remains in: $(printf '%s' "$left" | head -5 | tr '\n' ' ')"
  left=$( (cd "$OUT" && find . | grep -iF -f "$NAMES_FILE") || true)
  [ -z "$left" ] || die "a deny-list name remains in a path: $(printf '%s' "$left" | head -5 | tr '\n' ' ')"
else
  echo "NOTE: the deny list is empty; the snapshot is not redacted." >&2
fi

chmod -R a-w "$OUT" || die "cannot make the snapshot read-only"

files=$(find "$OUT" -type f | wc -l | tr -d ' ')
echo "source-snapshot: $COMMIT -> $OUT ($files files, $redacted redacted)"
