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
#   3. It checks that no name remains in any file or path. It fails on any
#      symbolic link. It fails on any binary file when the deny list is not
#      empty. The check is literal; it does not catch encoded content.
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
# A set CDPATH can make `cd` print a path and change its target.
unset CDPATH

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
# Remove trailing slashes, so that "link/" is tested as "link".
while [ "${#OUT}" -gt 1 ] && [ "${OUT%/}" != "$OUT" ]; do OUT="${OUT%/}"; done
# A symbolic out-dir could send the tree outside the place the operator chose.
[ ! -L "$OUT" ] || die "out-dir is a symbolic link: $OUT"
# The nearest existing parent must not resolve through a symbolic link.
# Compare its logical path with its physical path.
PARENT=$(dirname "$OUT")
while [ ! -d "$PARENT" ]; do PARENT=$(dirname "$PARENT"); done
LOGICAL=$(cd "$PARENT" && pwd) || die "cannot resolve the out-dir parent: $PARENT"
PHYSICAL=$(cd -P "$PARENT" && pwd -P) || die "cannot resolve the out-dir parent: $PARENT"
[ "$LOGICAL" = "$PHYSICAL" ] \
  || die "the out-dir parent resolves through a symbolic link: $PARENT"
if [ -e "$OUT" ]; then
  [ -d "$OUT" ] || die "out-dir is not a directory: $OUT"
  [ -z "$(ls -A "$OUT")" ] || die "out-dir is not empty: $OUT"
fi

NAMES_FILE=$(mktemp)
CREATED=0
cleanup() {
  local rc=$?
  rm -f "$NAMES_FILE"
  # On any failure, remove the partly redacted tree. No half-scrubbed copy
  # stays on disk.
  if [ "$rc" -ne 0 ] && [ "$CREATED" -eq 1 ]; then
    chmod -R u+w "$OUT" 2>/dev/null || true
    rm -rf "$OUT"
  fi
}
trap cleanup EXIT

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

mkdir -p "$OUT" || die "cannot create out-dir: $OUT"
CREATED=1
git -C "$REPO" archive --format=tar "$COMMIT" | tar -x -C "$OUT" \
  || die "git archive of $COMMIT failed"

# A symbolic link can point at a deny-list name or outside the snapshot.
# Fail closed on any link.
links=$(find "$OUT" -type l) || die "cannot scan for symbolic links"
[ -z "$links" ] || die "the snapshot holds a symbolic link: $(printf '%s' "$links" | head -5 | tr '\n' ' ')"

redacted=0
if [ -s "$NAMES_FILE" ]; then
  # Text files: replace each name. Longer names go first, so that a name
  # that contains a shorter name is replaced as a whole.
  rc=0
  hits=$(grep -rlIiF -f "$NAMES_FILE" "$OUT") || rc=$?
  [ "$rc" -le 1 ] || die "the text scan failed (grep exit $rc)"
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

  # A binary file is never redacted by the text pass. Fail closed on any.
  bins=""
  while IFS= read -r f; do
    grep -Iq '' "$f" 2>/dev/null || bins="$bins $f"
  done < <(find "$OUT" -type f -size +0)
  [ -z "$bins" ] || die "a binary file was not redacted:$(printf '%s' "$bins" | cut -c1-300)"

  # Proof step. The proof is literal: it does not catch encoded content.
  # Any match left in a file or in a path fails the snapshot. A scan error
  # (grep exit 2 or more) also fails the snapshot.
  rc=0
  left=$(grep -rliF -f "$NAMES_FILE" "$OUT") || rc=$?
  [ "$rc" -le 1 ] || die "the proof scan failed (grep exit $rc)"
  [ -z "$left" ] || die "a deny-list name remains in: $(printf '%s' "$left" | head -5 | tr '\n' ' ')"
  # List the paths relative to the out-dir. No pattern is built from the
  # out-dir name, so any out-dir name is safe.
  paths=$(cd -P "$OUT" && find . -print) || die "cannot list the snapshot paths"
  rc=0
  left=$(printf '%s\n' "$paths" | grep -iF -f "$NAMES_FILE") || rc=$?
  [ "$rc" -le 1 ] || die "the path proof scan failed (grep exit $rc)"
  [ -z "$left" ] || die "a deny-list name remains in a path: $(printf '%s' "$left" | head -5 | tr '\n' ' ')"
else
  echo "NOTE: the deny list is empty; the snapshot is not redacted." >&2
fi

chmod -R a-w "$OUT" || die "cannot make the snapshot read-only"

files=$(find "$OUT" -type f | wc -l | tr -d ' ')
echo "source-snapshot: $COMMIT -> $OUT ($files files, $redacted redacted)"
