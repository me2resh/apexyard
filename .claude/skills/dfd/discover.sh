#!/usr/bin/env bash
# /dfd — six-axis Data Flow Diagram discovery, read-only.
#
# Scans a target codebase for DFD elements: external actors, processes,
# data stores, data flows, trust boundaries, and data classifications
# (axis 6 delegated to classify.sh and merged in by the calling skill).
#
# Usage:
#   discover.sh <target-dir> [scope-hint]
#     target-dir   absolute path to the project root (must exist)
#     scope-hint   optional anchor — service name, "all", or empty
#
# Output: a YAML-ish structured discovery report on stdout. Sections:
#   actors:            external entities (users, third-party SaaS, admin consoles)
#   processes:         service handlers (HTTP, queue consumer, scheduled job)
#   stores:            persistent data stores (DB, cache, object storage, search index)
#   flows:             arrows — `{source, target, payload_hint, evidence}`
#   boundaries:        inferred trust boundaries — `{name, scope_hint, rationale}`
#   classifications:   per-data-element classification labels (PII / PCI / secrets / ...)
#
# Bash 3.2 compatible (no associative arrays, no `${var,,}` syntax) so
# the script works under the system bash on stock macOS.

set -uo pipefail

TARGET="${1:-}"
SCOPE_HINT="${2:-}"

if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  echo "ERROR: discover.sh requires a target directory as the first argument" >&2
  exit 2
fi

TARGET=$(cd "$TARGET" && pwd -P)

SKIP_DIRS="node_modules vendor .venv venv target dist build coverage .next .nuxt .turbo .cache __pycache__ .git .svn .idea .vscode"

# scoped_grep <pattern>: greps the target dir for <pattern>, pruning vendored dirs.
# Outputs `file:line:match` (grep -nH format), capped at 500 lines.
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
    | head -500
}

# rel_path <abspath>  → path relative to TARGET (with leading ./)
rel_path() {
  local p="$1"
  printf './%s\n' "${p#"$TARGET"/}"
}

# first_evidence <hits-blob>: extracts the first file:line from a multi-line
# grep -nH blob and rewrites the file part to a relative path.
first_evidence() {
  local blob="$1"
  [ -z "$blob" ] && return 0
  local first
  first=$(printf '%s\n' "$blob" | head -1)
  local file line
  file=$(printf '%s' "$first" | cut -d: -f1)
  line=$(printf '%s' "$first" | cut -d: -f2)
  printf '%s:%s\n' "$(rel_path "$file")" "$line"
}

# --- Discovery axes ----------------------------------------------------------

echo "# DFD discovery report"
echo "# Target: $TARGET"
echo "# Scope hint: ${SCOPE_HINT:-(none)}"
echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# ---- Axis 1: External actors -----------------------------------------------

echo "actors:"

# Auth providers
AUTH_HITS=$(scoped_grep '(@auth0|aws-cdk-lib/aws-cognito|@clerk/|@supabase/auth|keycloak-js|next-auth|passport-)')
if [ -n "$AUTH_HITS" ]; then
  ev=$(first_evidence "$AUTH_HITS")
  echo "  - id: auth_provider"
  echo "    type: external_auth"
  echo "    evidence: \"$ev\""
fi

# Third-party SDK imports → external system actors
TP_PATTERNS='(stripe|@sendgrid/mail|nodemailer|postmark|twilio|@anthropic-ai/sdk|openai|@aws-sdk/client-(bedrock|sns|sqs)|@sentry/|@datadog/|posthog-js|@amplitude/analytics|mixpanel|algoliasearch|meilisearch)'
TP_HITS=$(scoped_grep "$TP_PATTERNS")

# Walk TP_HITS once, emit one entry per unique vendor (track via a temp file).
TP_SEEN_FILE=$(mktemp)
if [ -n "$TP_HITS" ]; then
  printf '%s\n' "$TP_HITS" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    file=$(printf '%s' "$line" | cut -d: -f1)
    lno=$(printf '%s' "$line" | cut -d: -f2)
    content=$(printf '%s' "$line" | cut -d: -f3-)
    vendor=$(printf '%s' "$content" | grep -oE "$TP_PATTERNS" | head -1)
    [ -z "$vendor" ] && continue
    # Canonicalise the vendor key to a single short token
    case "$vendor" in
      *stripe*)              key="stripe" ;;
      *sendgrid*)            key="sendgrid" ;;
      *nodemailer*)          key="nodemailer" ;;
      *postmark*)            key="postmark" ;;
      *twilio*)              key="twilio" ;;
      *anthropic*)           key="anthropic" ;;
      *openai*)              key="openai" ;;
      *bedrock*)             key="bedrock" ;;
      *sns*)                 key="aws_sns" ;;
      *sqs*)                 key="aws_sqs" ;;
      *sentry*)              key="sentry" ;;
      *datadog*)             key="datadog" ;;
      *posthog*)             key="posthog" ;;
      *amplitude*)           key="amplitude" ;;
      *mixpanel*)            key="mixpanel" ;;
      *algoliasearch*)       key="algolia" ;;
      *meilisearch*)         key="meilisearch" ;;
      *)                     key="${vendor//[^a-zA-Z0-9]/_}" ;;
    esac
    if ! grep -qx "$key" "$TP_SEEN_FILE" 2>/dev/null; then
      echo "$key" >> "$TP_SEEN_FILE"
      ev_rel=$(rel_path "$file")
      echo "  - id: ext_${key}"
      echo "    type: external_service"
      echo "    name: \"$key\""
      echo "    evidence: \"${ev_rel}:${lno}\""
    fi
  done
fi
rm -f "$TP_SEEN_FILE"

# Public HTTP entry points (anyone calling these is an external actor)
ROUTE_HITS=$(scoped_grep '(app|router|fastify)\.(get|post|put|patch|delete|all)\s*\(')
if [ -n "$ROUTE_HITS" ]; then
  ev=$(first_evidence "$ROUTE_HITS")
  echo "  - id: public_user"
  echo "    type: human"
  echo "    name: \"End user (via HTTP)\""
  echo "    evidence: \"$ev\""
fi

# Admin route detection — separate persona
# Use literal `/admin/` or `/api/admin/` strings (avoid shell metacharacter pain)
ADMIN_HITS=$(scoped_grep '/admin/|/api/admin/')
if [ -n "$ADMIN_HITS" ]; then
  ev=$(first_evidence "$ADMIN_HITS")
  echo "  - id: admin_user"
  echo "    type: human"
  echo "    name: \"Admin (privileged)\""
  echo "    evidence: \"$ev\""
fi

echo ""

# ---- Axis 2: Processes -----------------------------------------------------

echo "processes:"

# HTTP route handlers (one process per route batch)
N_ROUTES=0
if [ -n "$ROUTE_HITS" ]; then
  N_ROUTES=$(printf '%s\n' "$ROUTE_HITS" | wc -l | tr -d ' ')
fi
if [ "$N_ROUTES" -gt 0 ]; then
  echo "  - id: http_api"
  echo "    type: http_handler"
  echo "    name: \"HTTP API handlers\""
  echo "    count: $N_ROUTES"
fi

# Queue consumers / async jobs
QUEUE_HITS=$(scoped_grep 'new (Queue|Worker)\s*\(|@app\.task|@shared_task|@celery|sidekiq|@workflow\.defn')
N_Q=0
if [ -n "$QUEUE_HITS" ]; then
  N_Q=$(printf '%s\n' "$QUEUE_HITS" | wc -l | tr -d ' ')
fi
if [ "$N_Q" -gt 0 ]; then
  echo "  - id: queue_workers"
  echo "    type: queue_consumer"
  echo "    name: \"Background workers\""
  echo "    count: $N_Q"
fi

# Scheduled jobs / cron
CRON_HITS=$(scoped_grep 'cron\.schedule\s*\(|@scheduled_job|^schedule:|Events:.*Schedule:|^cron:')
N_C=0
if [ -n "$CRON_HITS" ]; then
  N_C=$(printf '%s\n' "$CRON_HITS" | wc -l | tr -d ' ')
fi
if [ "$N_C" -gt 0 ]; then
  echo "  - id: scheduled_jobs"
  echo "    type: scheduled"
  echo "    name: \"Scheduled jobs / cron\""
  echo "    count: $N_C"
fi

echo ""

# ---- Axis 3: Data stores ---------------------------------------------------

echo "stores:"

# Prisma
PRISMA_FILES=$(find "$TARGET" -name 'schema.prisma' -type f 2>/dev/null | head -3)
HAS_PRISMA=""
if [ -n "$PRISMA_FILES" ]; then
  first_p=$(printf '%s\n' "$PRISMA_FILES" | head -1)
  provider=$(grep -m1 -E '^\s*provider\s*=' "$first_p" 2>/dev/null | awk -F'"' '{print $2}')
  [ -z "$provider" ] && provider="postgresql"
  ev=$(rel_path "$first_p")
  echo "  - id: rdbms_prisma"
  echo "    type: rdbms"
  echo "    name: \"$provider (via Prisma)\""
  echo "    evidence: \"${ev}:1\""
  HAS_PRISMA=1
fi

# TypeORM @Entity
if [ -z "$HAS_PRISMA" ]; then
  TYPEORM=$(scoped_grep '@Entity\s*\(')
  if [ -n "$TYPEORM" ]; then
    ev=$(first_evidence "$TYPEORM")
    echo "  - id: rdbms_typeorm"
    echo "    type: rdbms"
    echo "    name: \"RDBMS (via TypeORM)\""
    echo "    evidence: \"$ev\""
  fi
fi

# SQLAlchemy
if [ -z "$HAS_PRISMA" ]; then
  SQLA=$(scoped_grep 'class\s+\w+\(.*(Base|db\.Model)|__tablename__\s*=')
  if [ -n "$SQLA" ]; then
    ev=$(first_evidence "$SQLA")
    echo "  - id: rdbms_sqlalchemy"
    echo "    type: rdbms"
    echo "    name: \"RDBMS (via SQLAlchemy)\""
    echo "    evidence: \"$ev\""
  fi
fi

# Mongo
MONGO=$(scoped_grep 'mongoose|MongoClient|mongodb://')
HAS_MONGO=""
if [ -n "$MONGO" ]; then
  ev=$(first_evidence "$MONGO")
  echo "  - id: docdb_mongo"
  echo "    type: document_store"
  echo "    name: \"MongoDB\""
  echo "    evidence: \"$ev\""
  HAS_MONGO=1
fi

# Dynamo
DYNAMO=$(scoped_grep '@aws-sdk/client-dynamodb|DynamoDBClient|boto3.*dynamodb')
HAS_DYNAMO=""
if [ -n "$DYNAMO" ]; then
  ev=$(first_evidence "$DYNAMO")
  echo "  - id: docdb_dynamo"
  echo "    type: document_store"
  echo "    name: \"DynamoDB\""
  echo "    evidence: \"$ev\""
  HAS_DYNAMO=1
fi

# Redis
REDIS=$(scoped_grep 'ioredis|new Redis\s*\(|redis://|RedisClient')
HAS_REDIS=""
if [ -n "$REDIS" ]; then
  ev=$(first_evidence "$REDIS")
  echo "  - id: cache_redis"
  echo "    type: cache"
  echo "    name: \"Redis\""
  echo "    evidence: \"$ev\""
  HAS_REDIS=1
fi

# S3
S3=$(scoped_grep '@aws-sdk/client-s3|S3Client|aws-sdk.*S3\(|boto3.*s3')
HAS_S3=""
if [ -n "$S3" ]; then
  ev=$(first_evidence "$S3")
  echo "  - id: object_s3"
  echo "    type: object_storage"
  echo "    name: \"S3 (or compatible)\""
  echo "    evidence: \"$ev\""
  HAS_S3=1
fi

# Search index
SEARCH=$(scoped_grep '@elastic/elasticsearch|algoliasearch|meilisearch|MeiliSearch')
if [ -n "$SEARCH" ]; then
  ev=$(first_evidence "$SEARCH")
  echo "  - id: search_index"
  echo "    type: search"
  echo "    name: \"Search index\""
  echo "    evidence: \"$ev\""
fi

# Data warehouse
DW=$(scoped_grep '@google-cloud/bigquery|snowflake-sdk|redshift-data')
if [ -n "$DW" ]; then
  ev=$(first_evidence "$DW")
  echo "  - id: dwh"
  echo "    type: data_warehouse"
  echo "    name: \"Data warehouse\""
  echo "    evidence: \"$ev\""
fi

echo ""

# ---- Axis 4: Data flows ----------------------------------------------------

echo "flows:"

if [ "$N_ROUTES" -gt 0 ]; then
  echo "  - source: public_user"
  echo "    target: http_api"
  echo "    payload_hint: \"HTTP request (body, headers, cookies)\""
fi

if [ -n "$HAS_PRISMA" ]; then
  echo "  - source: http_api"
  echo "    target: rdbms_prisma"
  echo "    payload_hint: \"persistent records\""
fi

if [ -n "$HAS_MONGO" ]; then
  echo "  - source: http_api"
  echo "    target: docdb_mongo"
  echo "    payload_hint: \"document writes / queries\""
fi

if [ -n "$HAS_DYNAMO" ]; then
  echo "  - source: http_api"
  echo "    target: docdb_dynamo"
  echo "    payload_hint: \"item writes / queries\""
fi

if [ -n "$HAS_S3" ]; then
  echo "  - source: http_api"
  echo "    target: object_s3"
  echo "    payload_hint: \"uploaded objects\""
fi

if [ -n "$HAS_REDIS" ]; then
  echo "  - source: http_api"
  echo "    target: cache_redis"
  echo "    payload_hint: \"cached query results / session data\""
fi

if [ "$N_Q" -gt 0 ] && [ -n "$TP_HITS" ]; then
  echo "  - source: queue_workers"
  echo "    target: ext_third_party"
  echo "    payload_hint: \"outbound integration calls (webhook, API)\""
fi

echo ""

# ---- Axis 5: Trust boundaries ----------------------------------------------

echo "boundaries:"

if [ "$N_ROUTES" -gt 0 ]; then
  echo "  - id: public_to_backend"
  echo "    name: \"Public Internet ↔ Backend\""
  echo "    rationale: \"HTTP routes detected — anonymous / authenticated transition\""
fi

if [ -n "$ADMIN_HITS" ]; then
  echo "  - id: user_to_admin"
  echo "    name: \"User ↔ Admin (privilege escalation)\""
  echo "    rationale: \"/admin/* route prefix detected — additional auth required\""
fi

if [ -n "$HAS_PRISMA$HAS_MONGO$HAS_DYNAMO$HAS_REDIS$HAS_S3" ]; then
  echo "  - id: backend_to_data"
  echo "    name: \"Backend ↔ Data Stores\""
  echo "    rationale: \"Data store(s) detected — DB credentials / IAM gate the boundary\""
fi

if [ -n "$TP_HITS" ]; then
  echo "  - id: us_to_third_party"
  echo "    name: \"Us ↔ Third-party SaaS\""
  echo "    rationale: \"Third-party SDK imports detected — outbound calls cross org boundary\""
fi

echo ""

# ---- Axis 6: Data classifications ------------------------------------------
# Delegated to classify.sh and merged by the calling skill.

echo "classifications:"
echo "  # populated by classify.sh — invoke separately for the heuristic walk"
echo ""

echo "# Summary — caller to populate counts before presenting to operator"
