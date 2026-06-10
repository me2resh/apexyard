#!/usr/bin/env bash
# /dfd — data-classification heuristics
#
# Walks a target codebase looking for data elements that should be
# tagged with a classification label (PII, PCI, secrets, internal,
# public). Three detection pathways, additive:
#
#   1. Annotations  — `@PII`, `@Sensitive`, `// CLASSIFIED: <label>`,
#                     `# classification: <label>`
#   2. Env-var heuristics — `*_SECRET`, `*_TOKEN`, `*_KEY`, `*_PASSWORD`
#                           in `.env*` / `process.env.*` / `os.environ[...]`
#   3. Schema heuristics — column / field names matching known PII /
#                          PCI patterns
#
# A fourth pathway (explicit registry — `docs/data-classification.yaml`)
# is honoured when present and OVERRIDES the heuristic output for any
# field it covers.
#
# Usage:
#   classify.sh <target-dir>
#     target-dir   absolute path to project root
#
# Output: structured YAML on stdout under a `classifications:` root key.
#
# Bash 3.2 compatible (no associative arrays, no `${var,,}` / `${var^^}`).

set -uo pipefail

TARGET="${1:-}"

if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  echo "ERROR: classify.sh requires a target directory as the first argument" >&2
  exit 2
fi

TARGET=$(cd "$TARGET" && pwd -P)

SKIP_DIRS="node_modules vendor .venv venv target dist build coverage .next .nuxt .turbo .cache __pycache__ .git .svn"

scoped_grep() {
  local pattern="$1"; shift
  local prune_args="" first=1 d
  for d in $SKIP_DIRS; do
    if [ $first -eq 1 ]; then
      prune_args="-name $d"
      first=0
    else
      prune_args="$prune_args -o -name $d"
    fi
  done
  # shellcheck disable=SC2086
  find "$TARGET" \( $prune_args \) -prune -o -type f -print 2>/dev/null \
    | xargs grep -nHE "$pattern" "$@" 2>/dev/null \
    | head -400
}

rel_path() {
  local p="$1"
  printf './%s\n' "${p#"$TARGET"/}"
}

# Lowercase / uppercase (bash 3.2 has no ${var,,} / ${var^^})
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Map a column / field name to a heuristic classification label.
# Outputs the label or empty + nonzero on no match.
classify_field() {
  local name_lc
  name_lc=$(lower "$1")

  case "$name_lc" in
    # PCI — payment card data (most specific first)
    card_number|cardnumber|card_no|pan)              echo "pci";       return 0 ;;
    cvv|cvc|card_verification|csc)                   echo "pci";       return 0 ;;
    exp_month|exp_year|expiry_month|expiry_year|expiration_date) echo "pci"; return 0 ;;

    # Secrets — credentials / keys
    password|password_hash|passwd|pwd_hash|hashedpassword) echo "secrets"; return 0 ;;
    api_key|apikey|secret_key|access_token|refresh_token|bearer_token) echo "secrets"; return 0 ;;
    private_key|priv_key)                            echo "secrets";   return 0 ;;

    # PII — personally identifiable
    email|email_address|user_email|emailaddress)     echo "pii";       return 0 ;;
    phone|phone_number|phonenumber|mobile|mobile_number) echo "pii";   return 0 ;;
    ssn|social_security_number|national_id|nin)      echo "pii";       return 0 ;;
    dob|date_of_birth|birth_date|birthdate)          echo "pii";       return 0 ;;
    address|street_address|home_address|mailing_address) echo "pii";   return 0 ;;
    first_name|last_name|full_name|surname|given_name) echo "pii";     return 0 ;;
    ip_address|ip|client_ip|remote_addr|user_ip)     echo "pii";       return 0 ;;
    passport|passport_number|drivers_license|license_number) echo "pii"; return 0 ;;
  esac
  return 1
}

# Map an env-var name to a heuristic classification label.
classify_envvar() {
  local up
  up=$(upper "$1")

  case "$up" in
    *_SECRET|*_PASSWORD|*_PWD|*PRIVATE_KEY*)     echo "secrets"; return 0 ;;
    *_TOKEN|*_API_KEY|*_APIKEY|*_KEY)            echo "secrets"; return 0 ;;
    SMTP_*|EMAIL_*|MAIL_*)                        echo "email-routing"; return 0 ;;
    DATABASE_URL|DB_URL|DB_PASSWORD|DB_USER|POSTGRES_*|MYSQL_*) echo "secrets"; return 0 ;;
  esac
  return 1
}

echo "classifications:"

# ---- Pathway 1: Annotations ------------------------------------------------

ANNO_HITS=$(scoped_grep '(@PII|@Sensitive|CLASSIFIED:[[:space:]]*[a-zA-Z_-]+|classification:[[:space:]]*[a-zA-Z_-]+)')
if [ -n "$ANNO_HITS" ]; then
  echo "  # --- annotation pathway ---"
  printf '%s\n' "$ANNO_HITS" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    file=$(printf '%s' "$line" | cut -d: -f1)
    lno=$(printf '%s' "$line" | cut -d: -f2)
    content=$(printf '%s' "$line" | cut -d: -f3-)
    label=""
    case "$content" in
      *'@PII'*)       label="pii" ;;
      *'@Sensitive'*) label="sensitive" ;;
    esac
    if printf '%s' "$content" | grep -qE 'CLASSIFIED:'; then
      label=$(printf '%s' "$content" | grep -oE 'CLASSIFIED:[[:space:]]*[a-zA-Z_-]+' | sed 's/.*://' | tr -d '[:space:]')
    fi
    if printf '%s' "$content" | grep -qE 'classification:'; then
      label=$(printf '%s' "$content" | grep -oE 'classification:[[:space:]]*[a-zA-Z_-]+' | sed 's/.*://' | tr -d '[:space:]')
    fi
    [ -z "$label" ] && continue
    short_content=$(printf '%s' "$content" | tr -d '"' | tr -d "'" | cut -c1-80)
    ev=$(rel_path "$file")
    echo "  - source: annotation"
    echo "    label: \"$label\""
    echo "    evidence: \"${ev}:${lno}\""
    echo "    context: \"$short_content\""
  done
fi

# ---- Pathway 2: Env vars ---------------------------------------------------

ENV_FILES=$(find "$TARGET" -maxdepth 3 -type f \( -name '.env' -o -name '.env.*' -o -name '.env.example' \) 2>/dev/null | head -10)
ENV_REFS=$(scoped_grep '(process\.env\.[A-Z_][A-Z0-9_]*|os\.environ\[[\x27"][A-Z_][A-Z0-9_]*[\x27"]\]|getenv\([\x27"][A-Z_][A-Z0-9_]*[\x27"]\))')

if [ -n "$ENV_FILES" ] || [ -n "$ENV_REFS" ]; then
  echo "  # --- env-var pathway ---"
  ENV_SEEN_FILE=$(mktemp)
  for envf in $ENV_FILES; do
    [ -z "$envf" ] && continue
    while IFS= read -r raw; do
      key=$(printf '%s' "$raw" | grep -oE '^[A-Z_][A-Z0-9_]*' | head -1)
      [ -z "$key" ] && continue
      grep -qx "$key" "$ENV_SEEN_FILE" 2>/dev/null && continue
      echo "$key" >> "$ENV_SEEN_FILE"
      label=$(classify_envvar "$key")
      [ -z "$label" ] && continue
      ev=$(rel_path "$envf")
      echo "  - source: env_var"
      echo "    label: \"$label\""
      echo "    name: \"$key\""
      echo "    evidence: \"${ev}:1\""
    done < "$envf"
  done
  if [ -n "$ENV_REFS" ]; then
    printf '%s\n' "$ENV_REFS" | while IFS= read -r line; do
      [ -z "$line" ] && continue
      file=$(printf '%s' "$line" | cut -d: -f1)
      lno=$(printf '%s' "$line" | cut -d: -f2)
      content=$(printf '%s' "$line" | cut -d: -f3-)
      key=$(printf '%s' "$content" | grep -oE '[A-Z_][A-Z0-9_]{2,}' | head -1)
      [ -z "$key" ] && continue
      grep -qx "$key" "$ENV_SEEN_FILE" 2>/dev/null && continue
      echo "$key" >> "$ENV_SEEN_FILE"
      label=$(classify_envvar "$key")
      [ -z "$label" ] && continue
      ev=$(rel_path "$file")
      echo "  - source: env_var_ref"
      echo "    label: \"$label\""
      echo "    name: \"$key\""
      echo "    evidence: \"${ev}:${lno}\""
    done
  fi
  rm -f "$ENV_SEEN_FILE"
fi

# ---- Pathway 3: Schema columns ---------------------------------------------

# Prisma — `<field>  <Type>` lines inside `model X { ... }`
PRISMA_F=$(find "$TARGET" -maxdepth 4 -name 'schema.prisma' -type f 2>/dev/null | head -5)
if [ -n "$PRISMA_F" ]; then
  echo "  # --- schema pathway: Prisma ---"
  for f in $PRISMA_F; do
    in_model=0
    line_no=0
    current_model=""
    while IFS= read -r raw; do
      line_no=$((line_no + 1))
      # Detect model start
      first_word=$(printf '%s' "$raw" | awk '{print $1}')
      second_word=$(printf '%s' "$raw" | awk '{print $2}')
      if [ "$first_word" = "model" ] && [ -n "$second_word" ]; then
        in_model=1
        current_model=$(printf '%s' "$second_word" | tr -d '{')
        continue
      fi
      # Detect model end (closing brace at column 0/1)
      case "$raw" in
        '}'*|' }'*) in_model=0; continue ;;
      esac
      if [ "$in_model" -eq 1 ]; then
        field=$(printf '%s' "$raw" | awk '{print $1}')
        [ -z "$field" ] && continue
        case "$field" in
          @@*|//*) continue ;;
        esac
        label=$(classify_field "$field")
        [ -z "$label" ] && continue
        ev=$(rel_path "$f")
        echo "  - source: schema_column"
        echo "    label: \"$label\""
        echo "    model: \"$current_model\""
        echo "    field: \"$field\""
        echo "    evidence: \"${ev}:${line_no}\""
      fi
    done < "$f"
  done
fi

# Raw SQL migrations
SQL_F=$(find "$TARGET" -maxdepth 5 -type f \( -name '*.sql' -o -name 'schema.sql' \) 2>/dev/null | head -10)
if [ -n "$SQL_F" ]; then
  echo "  # --- schema pathway: raw SQL ---"
  for f in $SQL_F; do
    line_no=0
    while IFS= read -r raw; do
      line_no=$((line_no + 1))
      field=$(printf '%s' "$raw" | awk '{print $1}' | sed 's/[",;]//g' | cut -c1-64)
      [ -z "$field" ] && continue
      label=$(classify_field "$field")
      [ -z "$label" ] && continue
      ev=$(rel_path "$f")
      echo "  - source: schema_column"
      echo "    label: \"$label\""
      echo "    field: \"$field\""
      echo "    evidence: \"${ev}:${line_no}\""
    done < "$f"
  done
fi

# SQLAlchemy / Django ORM — `<name> = Column(...)` / `<name> = models.<Field>(`
ORM_FIELDS=$(scoped_grep '^\s*[a-z_][a-z0-9_]*\s*=\s*(Column|models\.)')
if [ -n "$ORM_FIELDS" ]; then
  echo "  # --- schema pathway: Python ORMs ---"
  printf '%s\n' "$ORM_FIELDS" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    file=$(printf '%s' "$line" | cut -d: -f1)
    lno=$(printf '%s' "$line" | cut -d: -f2)
    content=$(printf '%s' "$line" | cut -d: -f3-)
    field=$(printf '%s' "$content" | grep -oE '^[[:space:]]*[a-z_][a-z0-9_]*' | head -1 | tr -d '[:space:]')
    [ -z "$field" ] && continue
    label=$(classify_field "$field")
    [ -z "$label" ] && continue
    ev=$(rel_path "$file")
    echo "  - source: schema_column"
    echo "    label: \"$label\""
    echo "    field: \"$field\""
    echo "    evidence: \"${ev}:${lno}\""
  done
fi

# TS / Mongoose / TypeORM field literals — `fieldName: { type: ... }`
# Match well-known PII / PCI field names at the start of a line (after indent).
TS_FIELDS=$(scoped_grep '^[[:space:]]*(email|phone|phone_number|ssn|dob|address|password|api_key|card_number|cvv|first_name|last_name|full_name|ip_address)[[:space:]]*[:?]')
if [ -n "$TS_FIELDS" ]; then
  echo "  # --- schema pathway: TS object literals ---"
  TS_SEEN_FILE=$(mktemp)
  printf '%s\n' "$TS_FIELDS" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    file=$(printf '%s' "$line" | cut -d: -f1)
    lno=$(printf '%s' "$line" | cut -d: -f2)
    content=$(printf '%s' "$line" | cut -d: -f3-)
    field=$(printf '%s' "$content" | grep -oE '^[[:space:]]*[a-z_][a-z0-9_]*' | head -1 | tr -d '[:space:]')
    [ -z "$field" ] && continue
    key="${file}|${field}"
    grep -qxF "$key" "$TS_SEEN_FILE" 2>/dev/null && continue
    echo "$key" >> "$TS_SEEN_FILE"
    label=$(classify_field "$field")
    [ -z "$label" ] && continue
    ev=$(rel_path "$file")
    echo "  - source: schema_column"
    echo "    label: \"$label\""
    echo "    field: \"$field\""
    echo "    evidence: \"${ev}:${lno}\""
  done
  rm -f "$TS_SEEN_FILE"
fi

# ---- Pathway 4: Explicit registry override ---------------------------------

REG=$(find "$TARGET" -maxdepth 3 -type f \( -name 'data-classification.yaml' -o -name 'data-classification.yml' -o -name 'data-classification.md' \) 2>/dev/null | head -1)
if [ -n "$REG" ]; then
  echo "  # --- explicit registry (overrides heuristics) ---"
  echo "  - source: explicit_registry"
  echo "    path: \"$(rel_path "$REG")\""
  echo "    note: \"Operator-authored classification registry detected. Skill MUST load this file and let it override heuristic labels for any field it covers.\""
fi
