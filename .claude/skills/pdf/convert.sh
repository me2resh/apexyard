#!/usr/bin/env bash
# /pdf convert.sh — converter dispatch for the /pdf skill.
#
# Detects which PDF converters are available on the operator's machine
# and runs the right one for the input format. Graceful-degrades when
# none are installed (exit 3 + advisory message), matching the shape of
# .claude/skills/process/lint.sh and _lib-mermaid-lint.sh.
#
# Usage:
#   convert.sh --from=<input> --to=<output.pdf>
#              [--converter=pandoc|md-to-pdf|wkhtmltopdf|bpmn-to-image]
#              [--pdf-engine=<engine>]
#              [--check-only]
#
# Exit codes:
#   0 — converted cleanly (or --check-only and at least one converter found)
#   1 — conversion failed (the converter's stderr is streamed through)
#   2 — bad input / unsupported format / missing flags
#   3 — no converter available (advisory printed; install at least one)
#
# Design:
#   - Markdown: prefer pandoc → md-to-pdf
#   - HTML:     prefer wkhtmltopdf → pandoc → md-to-pdf (deepest fallback)
#   - BPMN:     two-step pipeline (bpmn-to-image → SVG → pandoc → PDF)
#
# Per-skill wrappers can override the dispatch order via --converter.

set -uo pipefail

FROM=""
TO=""
CONVERTER=""
PDF_ENGINE=""
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from=*)        FROM="${1#--from=}"; shift ;;
    --to=*)          TO="${1#--to=}"; shift ;;
    --converter=*)   CONVERTER="${1#--converter=}"; shift ;;
    --pdf-engine=*)  PDF_ENGINE="${1#--pdf-engine=}"; shift ;;
    --check-only)    CHECK_ONLY=1; shift ;;
    --help|-h)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    -*)
      echo "convert.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      echo "convert.sh: unexpected positional arg: $1" >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Detect available converters (cached in variables)
# ---------------------------------------------------------------------------
have_pandoc=0
have_wkhtmltopdf=0
have_npx=0
command -v pandoc       >/dev/null 2>&1 && have_pandoc=1
command -v wkhtmltopdf  >/dev/null 2>&1 && have_wkhtmltopdf=1
command -v npx          >/dev/null 2>&1 && have_npx=1

print_install_advisory() {
  cat >&2 <<MSG
convert.sh: no PDF converter installed.

Markdown inputs can use:
  • pandoc           — brew install pandoc (or apt-get install pandoc)
                       For best output also install xelatex (mactex / texlive-xetex)
  • md-to-pdf (npm)  — npm install -g md-to-pdf  (or run via npx, no install)

HTML inputs can use:
  • wkhtmltopdf      — brew install --cask wkhtmltopdf
  • pandoc           — same as above (uses its HTML reader)
  • md-to-pdf (npm)  — npm install -g md-to-pdf  (chromium under the hood)

BPMN inputs need a two-step pipeline:
  • bpmn-to-image (npm) → SVG → pandoc → PDF

Install at least one of the above and re-run /pdf.
MSG
}

# ---------------------------------------------------------------------------
# --check-only: just report what's available, exit 0/3 accordingly
# ---------------------------------------------------------------------------
if [ "$CHECK_ONLY" = "1" ]; then
  echo "convert.sh: converter availability"
  echo "  pandoc:       $([ $have_pandoc       -eq 1 ] && echo yes || echo no)"
  echo "  wkhtmltopdf:  $([ $have_wkhtmltopdf  -eq 1 ] && echo yes || echo no)"
  echo "  npx (md-to-pdf, bpmn-to-image): $([ $have_npx -eq 1 ] && echo yes || echo no)"
  if [ "$have_pandoc" -eq 0 ] && [ "$have_wkhtmltopdf" -eq 0 ] && [ "$have_npx" -eq 0 ]; then
    print_install_advisory
    exit 3
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate inputs for normal (non-check-only) mode
# ---------------------------------------------------------------------------
if [ -z "$FROM" ] || [ -z "$TO" ]; then
  echo "convert.sh: --from and --to are required" >&2
  exit 2
fi
if [ ! -f "$FROM" ]; then
  echo "convert.sh: input file not found: $FROM" >&2
  exit 2
fi

# Resolve absolute paths so converters that change cwd still work.
FROM_ABS=$(cd "$(dirname "$FROM")" && pwd)/$(basename "$FROM")
TO_DIR=$(dirname "$TO")
mkdir -p "$TO_DIR"
TO_ABS=$(cd "$TO_DIR" && pwd)/$(basename "$TO")

# ---------------------------------------------------------------------------
# Sniff input format
# ---------------------------------------------------------------------------
FORMAT=""
case "$FROM" in
  *.md|*.markdown)        FORMAT="markdown" ;;
  *.html|*.htm)           FORMAT="html" ;;
  *.bpmn|*.bpmn20.xml)    FORMAT="bpmn" ;;
  *)
    echo "convert.sh: unsupported input format for $FROM (supported: .md, .markdown, .html, .htm, .bpmn, .bpmn20.xml)" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Determine which converter to use
# ---------------------------------------------------------------------------
chosen=""

choose_for_markdown() {
  if [ -n "$CONVERTER" ]; then
    case "$CONVERTER" in
      pandoc)
        if [ "$have_pandoc" -eq 1 ]; then chosen="pandoc"; return; fi
        echo "convert.sh: --converter=pandoc requested but pandoc is not installed" >&2
        exit 3
        ;;
      md-to-pdf)
        if [ "$have_npx" -eq 1 ]; then chosen="md-to-pdf"; return; fi
        echo "convert.sh: --converter=md-to-pdf requested but npx is not available (need Node + npm)" >&2
        exit 3
        ;;
      wkhtmltopdf)
        echo "convert.sh: --converter=wkhtmltopdf is for HTML inputs, not markdown" >&2
        exit 2
        ;;
      *)
        echo "convert.sh: --converter=$CONVERTER is not valid for markdown (use pandoc or md-to-pdf)" >&2
        exit 2
        ;;
    esac
  fi
  if [ "$have_pandoc" -eq 1 ]; then chosen="pandoc"; return; fi
  if [ "$have_npx"    -eq 1 ]; then chosen="md-to-pdf"; return; fi
  print_install_advisory
  exit 3
}

choose_for_html() {
  if [ -n "$CONVERTER" ]; then
    case "$CONVERTER" in
      wkhtmltopdf)
        if [ "$have_wkhtmltopdf" -eq 1 ]; then chosen="wkhtmltopdf"; return; fi
        echo "convert.sh: --converter=wkhtmltopdf requested but it is not installed" >&2
        exit 3
        ;;
      pandoc)
        if [ "$have_pandoc" -eq 1 ]; then chosen="pandoc-html"; return; fi
        echo "convert.sh: --converter=pandoc requested but pandoc is not installed" >&2
        exit 3
        ;;
      md-to-pdf)
        if [ "$have_npx" -eq 1 ]; then chosen="md-to-pdf-html"; return; fi
        echo "convert.sh: --converter=md-to-pdf requested but npx is not available" >&2
        exit 3
        ;;
      *)
        echo "convert.sh: --converter=$CONVERTER is not valid for html" >&2
        exit 2
        ;;
    esac
  fi
  if [ "$have_wkhtmltopdf" -eq 1 ]; then chosen="wkhtmltopdf"; return; fi
  if [ "$have_pandoc"      -eq 1 ]; then chosen="pandoc-html"; return; fi
  if [ "$have_npx"         -eq 1 ]; then chosen="md-to-pdf-html"; return; fi
  print_install_advisory
  exit 3
}

choose_for_bpmn() {
  # BPMN always needs npx for bpmn-to-image, and either pandoc or
  # wkhtmltopdf for the SVG → PDF stage.
  if [ "$have_npx" -eq 0 ]; then
    cat >&2 <<MSG
convert.sh: BPMN → PDF requires npx (Node + npm) for bpmn-to-image.
  Install Node (https://nodejs.org), then re-run /pdf.
MSG
    exit 3
  fi
  if [ "$have_pandoc" -eq 0 ] && [ "$have_wkhtmltopdf" -eq 0 ]; then
    cat >&2 <<MSG
convert.sh: BPMN → PDF needs pandoc or wkhtmltopdf for the SVG → PDF stage.
  Install one of:
    • pandoc        — brew install pandoc
    • wkhtmltopdf   — brew install --cask wkhtmltopdf
MSG
    exit 3
  fi
  chosen="bpmn-to-image+pandoc"
}

case "$FORMAT" in
  markdown) choose_for_markdown ;;
  html)     choose_for_html ;;
  bpmn)     choose_for_bpmn ;;
esac

echo "convert.sh: input=$FORMAT  converter=$chosen  out=$TO_ABS" >&2

# ---------------------------------------------------------------------------
# Run the chosen converter
# ---------------------------------------------------------------------------
WORK=$(mktemp -d -t pdf-convert-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

case "$chosen" in
  pandoc)
    # Markdown → PDF via pandoc. --pdf-engine is overridable.
    eng_flag=""
    if [ -n "$PDF_ENGINE" ]; then
      eng_flag="--pdf-engine=$PDF_ENGINE"
    fi
    if pandoc "$FROM_ABS" -o "$TO_ABS" $eng_flag; then
      exit 0
    fi
    echo "convert.sh: pandoc conversion failed for $FROM_ABS" >&2
    exit 1
    ;;

  md-to-pdf)
    # Markdown → PDF via the md-to-pdf npm package (chromium-backed).
    #
    # md-to-pdf removed --pdf-output-folder and --dest-name in a breaking
    # change (see me2resh/apexyard#404).  The current CLI writes
    # <source-basename>.pdf in the same directory as the source file.
    #
    # Strategy: copy the source into a private temp dir under the desired
    # output stem, invoke md-to-pdf there, then mv the result to TO_ABS.
    # This avoids any cwd or output-name fighting.
    out_stem="$(basename "${TO_ABS%.*}")"
    tmp_src="$WORK/${out_stem}.md"
    tmp_out="$WORK/${out_stem}.pdf"
    cp "$FROM_ABS" "$tmp_src"
    if npx -y md-to-pdf "$tmp_src" >&2; then
      if [ -f "$tmp_out" ]; then
        mv "$tmp_out" "$TO_ABS"
        exit 0
      fi
      echo "convert.sh: md-to-pdf ran but no PDF appeared at $tmp_out" >&2
      exit 1
    fi
    echo "convert.sh: md-to-pdf conversion failed for $FROM_ABS" >&2
    exit 1
    ;;

  wkhtmltopdf)
    if wkhtmltopdf --quiet "$FROM_ABS" "$TO_ABS"; then
      exit 0
    fi
    echo "convert.sh: wkhtmltopdf conversion failed for $FROM_ABS" >&2
    exit 1
    ;;

  pandoc-html)
    eng_flag=""
    if [ -n "$PDF_ENGINE" ]; then
      eng_flag="--pdf-engine=$PDF_ENGINE"
    fi
    if pandoc --from html "$FROM_ABS" -o "$TO_ABS" $eng_flag; then
      exit 0
    fi
    echo "convert.sh: pandoc HTML→PDF conversion failed for $FROM_ABS" >&2
    exit 1
    ;;

  md-to-pdf-html)
    # md-to-pdf accepts HTML as a last-resort HTML→PDF path.
    #
    # Same staging strategy as the md-to-pdf (markdown) branch — copy
    # source into temp dir under desired output stem, let md-to-pdf write
    # <stem>.pdf next to it, then mv to TO_ABS.
    out_stem="$(basename "${TO_ABS%.*}")"
    tmp_src="$WORK/${out_stem}.html"
    tmp_out="$WORK/${out_stem}.pdf"
    cp "$FROM_ABS" "$tmp_src"
    if npx -y md-to-pdf "$tmp_src" >&2; then
      if [ -f "$tmp_out" ]; then
        mv "$tmp_out" "$TO_ABS"
        exit 0
      fi
      echo "convert.sh: md-to-pdf produced no PDF at $tmp_out for HTML input" >&2
      exit 1
    fi
    echo "convert.sh: md-to-pdf HTML→PDF conversion failed for $FROM_ABS" >&2
    exit 1
    ;;

  bpmn-to-image+pandoc)
    # Step 1: BPMN → SVG via bpmn-to-image.
    svg_out="$WORK/diagram.svg"
    if ! npx -y bpmn-to-image --no-title "${FROM_ABS}:${svg_out}" >&2; then
      echo "convert.sh: bpmn-to-image failed for $FROM_ABS" >&2
      exit 1
    fi
    if [ ! -f "$svg_out" ]; then
      echo "convert.sh: bpmn-to-image produced no SVG at $svg_out" >&2
      exit 1
    fi
    # Step 2: SVG → PDF via pandoc (or wkhtmltopdf via an HTML wrap).
    if [ "$have_pandoc" -eq 1 ]; then
      # Wrap the SVG in markdown so pandoc emits a one-page PDF with the diagram.
      wrapper_md="$WORK/wrap.md"
      cat > "$wrapper_md" <<MD
# $(basename "${FROM_ABS%.*}")

![](${svg_out})
MD
      eng_flag=""
      if [ -n "$PDF_ENGINE" ]; then
        eng_flag="--pdf-engine=$PDF_ENGINE"
      fi
      if pandoc "$wrapper_md" -o "$TO_ABS" $eng_flag; then
        exit 0
      fi
      echo "convert.sh: pandoc SVG→PDF wrap failed" >&2
      exit 1
    fi
    if [ "$have_wkhtmltopdf" -eq 1 ]; then
      wrapper_html="$WORK/wrap.html"
      cat > "$wrapper_html" <<HTML
<!doctype html><html><body><img src="${svg_out}" /></body></html>
HTML
      if wkhtmltopdf --quiet --enable-local-file-access "$wrapper_html" "$TO_ABS"; then
        exit 0
      fi
      echo "convert.sh: wkhtmltopdf SVG→PDF wrap failed" >&2
      exit 1
    fi
    echo "convert.sh: no SVG→PDF backend (pandoc / wkhtmltopdf)" >&2
    exit 1
    ;;

  *)
    echo "convert.sh: internal error — chosen=$chosen" >&2
    exit 2
    ;;
esac
