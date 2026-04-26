#!/usr/bin/env bash
# apply-twenty-schema.sh
# Applies versioned JSON migration files from twenty-schema/migrations/V*.json
# against the Twenty Metadata GraphQL API.
#
# Prerequisites:
#   - curl, jq, docker on PATH (psql is invoked inside the bookings-db container via 'docker exec')
#   - infrastructure/.env with TWENTY_API_KEY, TWENTY_API_BASE_URL, and bookings-DB vars
#   - V004__twenty_schema_tracker.sql must have been applied (twenty_schema_migrations table)
#
# Re-runnable: safe to run multiple times. Successfully-applied migrations are
# skipped. Failed-mid-run migrations require manual resolution (see README).
#
# Rate limit: Twenty enforces 100 req/min per workspace. This script paces itself
# to ~50 req/min (~1.2s between API calls) to leave headroom for concurrent UI activity.
#
# Usage: ./scripts/apply-twenty-schema.sh
set -euo pipefail

# ─────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MIGRATIONS_DIR="${REPO_ROOT}/twenty-schema/migrations"
ENV_FILE="${REPO_ROOT}/infrastructure/.env"

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
err()  { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Rate-limit pacer: sleep ~1.2s between mutations (~50 req/min)
pace() { sleep 1.2; }

# Run a SQL command against the bookings DB via 'docker exec'.
# The bookings-db port is intentionally NOT published to the host — the internal
# DB stays internal (CLAUDE.md invariant #1), and the production path is identical
# to local since the script will eventually run as a one-shot container alongside
# the stack. Container name is configurable via BOOKINGS_DB_CONTAINER.
# Usage: psql_exec "SQL"
# Returns: psql stdout in -t -A format (tuples-only, unaligned, quiet).
psql_exec() {
  docker exec -e PGPASSWORD="${BOOKINGS_DB_PASSWORD}" "${BOOKINGS_DB_CONTAINER}" \
    psql -U "${BOOKINGS_DB_USER}" -d "${BOOKINGS_DB_NAME}" -t -A -q -c "$1"
}

# ─────────────────────────────────────────────
# Preflight: env file
# ─────────────────────────────────────────────
if [ ! -f "${ENV_FILE}" ]; then
  die "infrastructure/.env not found. Run ./scripts/bootstrap.sh first."
fi
# shellcheck source=/dev/null
source "${ENV_FILE}"

for var in TWENTY_API_KEY TWENTY_API_BASE_URL BOOKINGS_DB_USER BOOKINGS_DB_PASSWORD BOOKINGS_DB_NAME; do
  if [ -z "${!var:-}" ]; then
    die "Required env var '${var}' is missing or empty in infrastructure/.env"
  fi
done

TWENTY_BASE="${TWENTY_API_BASE_URL%/}"   # strip trailing slash
BOOKINGS_DB_CONTAINER="${BOOKINGS_DB_CONTAINER:-hr-bookings-db}"

# ─────────────────────────────────────────────
# Preflight: dependencies
# ─────────────────────────────────────────────
for dep in curl jq docker; do
  command -v "${dep}" >/dev/null 2>&1 || die "Required tool '${dep}' not found on PATH"
done

# ─────────────────────────────────────────────
# Preflight: Twenty reachability
# ─────────────────────────────────────────────
log "Checking Twenty reachability at ${TWENTY_BASE}/healthz ..."
HEALTH_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${TWENTY_BASE}/healthz" || true)
if [ "${HEALTH_HTTP}" != "200" ]; then
  die "Twenty healthz returned HTTP ${HEALTH_HTTP}. Is the server running?"
fi
log "Twenty is reachable (HTTP 200)."

# ─────────────────────────────────────────────
# Preflight: Twenty auth verification
# ─────────────────────────────────────────────
log "Verifying API key auth against ${TWENTY_BASE}/metadata ..."
AUTH_RESPONSE=$(curl -s --max-time 15 \
  -X POST \
  -H "Authorization: Bearer ${TWENTY_API_KEY}" \
  -H "Content-Type: application/json" \
  "${TWENTY_BASE}/metadata" \
  -d '{"query":"{ __typename }"}')

AUTH_TYPENAME=$(echo "${AUTH_RESPONSE}" | jq -r '.data.__typename // empty' 2>/dev/null || true)
AUTH_ERRORS=$(echo "${AUTH_RESPONSE}" | jq -r '.errors // empty' 2>/dev/null || true)

if [ -z "${AUTH_TYPENAME}" ]; then
  err "Auth check failed. Response body:"
  echo "${AUTH_RESPONSE}" >&2
  die "API key auth failed. Ensure TWENTY_API_KEY is valid and has DATA_MODEL permission."
fi
log "Auth verified (typename: ${AUTH_TYPENAME})."

# ─────────────────────────────────────────────
# Preflight: bookings DB reachability
# ─────────────────────────────────────────────
log "Checking bookings DB reachability via 'docker exec ${BOOKINGS_DB_CONTAINER}' ..."
if ! psql_exec "SELECT 1;" >/dev/null 2>&1; then
  die "Cannot connect to bookings DB via 'docker exec ${BOOKINGS_DB_CONTAINER}'. Is the container running and healthy? Try: docker compose -f infrastructure/docker-compose.yml ps"
fi

# Check that the tracker table exists
TRACKER_EXISTS=$(psql_exec "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='twenty_schema_migrations';" 2>/dev/null || echo "0")
if [ "${TRACKER_EXISTS}" != "1" ]; then
  die "Table 'twenty_schema_migrations' does not exist in bookings DB. Run './scripts/migrate-bookings-db.sh' first (V004__twenty_schema_tracker.sql must be applied)."
fi
log "Bookings DB reachable; tracker table exists."

# ─────────────────────────────────────────────
# Load state: GET /rest/metadata/objects
# Returns all objects (built-in + custom) with their fields.
# We cache name→uuid and name→fieldName→fieldUuid for resolving references.
# ─────────────────────────────────────────────
log "Loading existing Twenty schema state from ${TWENTY_BASE}/rest/metadata/objects ..."
METADATA_RESPONSE=$(curl -s --max-time 30 \
  -H "Authorization: Bearer ${TWENTY_API_KEY}" \
  "${TWENTY_BASE}/rest/metadata/objects")

METADATA_ERROR=$(echo "${METADATA_RESPONSE}" | jq -r '.error // empty' 2>/dev/null || true)
if [ -n "${METADATA_ERROR}" ]; then
  err "Failed to load schema state. Response:"
  echo "${METADATA_RESPONSE}" >&2
  die "Cannot continue without schema state."
fi

# Build name→uuid map from the response
# The REST metadata endpoint returns { "objects": [ { "nameSingular": "...", "id": "...", ... } ] }
declare -A OBJECT_UUID_MAP
while IFS=$'\t' read -r name uuid; do
  OBJECT_UUID_MAP["${name}"]="${uuid}"
done < <(echo "${METADATA_RESPONSE}" | jq -r '.data.objects[] | [.nameSingular, .id] | @tsv' 2>/dev/null)

log "Loaded ${#OBJECT_UUID_MAP[@]} objects from Twenty schema."

# ─────────────────────────────────────────────
# Determine pending migrations
# ─────────────────────────────────────────────
APPLIED_VERSIONS=$(psql_exec "SELECT version FROM twenty_schema_migrations ORDER BY version;" 2>/dev/null || true)

# Collect and sort migration files
declare -a PENDING_FILES=()
for mig_file in "${MIGRATIONS_DIR}"/V*.json; do
  [ -f "${mig_file}" ] || continue
  # Strip single-line // comments before parsing (migration JSON files may contain them)
  _mig_json_tmp=$(sed '/^[[:space:]]*\/\//d' "${mig_file}" 2>/dev/null || true)
  mig_version=$(echo "${_mig_json_tmp}" | jq -r '.version' 2>/dev/null || true)
  if [ -z "${mig_version}" ]; then
    err "Cannot parse version from ${mig_file} — skipping"
    continue
  fi
  if echo "${APPLIED_VERSIONS}" | grep -qxF "${mig_version}"; then
    log "SKIP ${mig_version} (already applied)"
  else
    PENDING_FILES+=("${mig_file}")
  fi
done

if [ ${#PENDING_FILES[@]} -eq 0 ]; then
  log "No pending migrations. Nothing to do."
  exit 0
fi

log "Pending migrations: ${#PENDING_FILES[@]}"

# ─────────────────────────────────────────────
# Helper: issue a createOneObject mutation
# ─────────────────────────────────────────────
create_object() {
  local object_input="$1"
  local MUTATION
  MUTATION=$(cat <<'GQLEOF'
mutation CreateOneObject($input: CreateOneObjectInput!) {
  createOneObject(input: $input) {
    id
    nameSingular
    namePlural
    labelSingular
    labelPlural
    isCustom
    isActive
  }
}
GQLEOF
)
  local variables
  variables=$(jq -n --argjson obj "${object_input}" '{"input":{"object": $obj}}')
  local body
  body=$(jq -n --arg q "${MUTATION}" --argjson v "${variables}" '{"query":$q,"variables":$v}')

  local response
  response=$(curl -s --max-time 30 \
    -X POST \
    -H "Authorization: Bearer ${TWENTY_API_KEY}" \
    -H "Content-Type: application/json" \
    "${TWENTY_BASE}/metadata" \
    -d "${body}")
  echo "${response}"
}

# ─────────────────────────────────────────────
# Helper: issue a createOneField mutation
# Resolves objectName → objectMetadataId and
# relationCreationPayload.targetObjectName → targetObjectMetadataId
# ─────────────────────────────────────────────
create_field() {
  local field_input="$1"

  # Resolve objectName → objectMetadataId
  local obj_name
  obj_name=$(echo "${field_input}" | jq -r '.objectName')
  local obj_uuid="${OBJECT_UUID_MAP[${obj_name}]:-}"
  if [ -z "${obj_uuid}" ]; then
    echo '{"error":"RESOLUTION_FAILED","detail":"Object not found in state cache: '"${obj_name}"'"}'
    return
  fi

  # Strip objectName; inject objectMetadataId
  local resolved_input
  resolved_input=$(echo "${field_input}" | jq --arg id "${obj_uuid}" 'del(.objectName) | .objectMetadataId = $id')

  # Resolve targetObjectName in relationCreationPayload (if present)
  local has_relation
  has_relation=$(echo "${resolved_input}" | jq -r 'if .relationCreationPayload then "yes" else "no" end')
  if [ "${has_relation}" = "yes" ]; then
    local target_obj_name
    target_obj_name=$(echo "${resolved_input}" | jq -r '.relationCreationPayload.targetObjectName')
    local target_obj_uuid="${OBJECT_UUID_MAP[${target_obj_name}]:-}"
    if [ -z "${target_obj_uuid}" ]; then
      echo '{"error":"RESOLUTION_FAILED","detail":"Target object not found in state cache: '"${target_obj_name}"'"}'
      return
    fi
    resolved_input=$(echo "${resolved_input}" | \
      jq --arg id "${target_obj_uuid}" \
      'del(.relationCreationPayload.targetObjectName) | .relationCreationPayload.targetObjectMetadataId = $id')
  fi

  local MUTATION
  MUTATION=$(cat <<'GQLEOF'
mutation CreateOneField($input: CreateOneFieldMetadataInput!) {
  createOneField(input: $input) {
    id
    type
    name
    label
    objectMetadataId
    isCustom
    isActive
  }
}
GQLEOF
)
  local variables
  variables=$(jq -n --argjson f "${resolved_input}" '{"input":{"field": $f}}')
  local body
  body=$(jq -n --arg q "${MUTATION}" --argjson v "${variables}" '{"query":$q,"variables":$v}')

  local response
  response=$(curl -s --max-time 30 \
    -X POST \
    -H "Authorization: Bearer ${TWENTY_API_KEY}" \
    -H "Content-Type: application/json" \
    "${TWENTY_BASE}/metadata" \
    -d "${body}")
  echo "${response}"
}

# ─────────────────────────────────────────────
# Helper: write error to bookings DB workflow_errors table
# ─────────────────────────────────────────────
record_error() {
  local workflow_name="apply-twenty-schema.sh"
  local execution_id="$1"
  local node_name="$2"
  local error_message="$3"
  local context_json="$4"
  # Escape single quotes in strings for psql
  local safe_message="${error_message//\'/\'\'}"
  local safe_context="${context_json//\'/\'\'}"
  psql_exec "INSERT INTO workflow_errors (workflow_name, execution_id, node_name, error_message, context) VALUES ('${workflow_name}', '${execution_id}', '${node_name}', '${safe_message}', '${safe_context}'::jsonb);" >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────
# Apply each pending migration
# ─────────────────────────────────────────────
SUMMARY_APPLIED=()
SUMMARY_SKIPPED=()

# Unique run ID for error tracking
RUN_ID="apply-$(date -u +%Y%m%dT%H%M%S)-$$"

for mig_file in "${PENDING_FILES[@]}"; do
  # Strip single-line // comments before parsing (migration JSON files may contain them for readability)
  mig_json=$(sed '/^[[:space:]]*\/\//d' "${mig_file}")
  mig_version=$(echo "${mig_json}" | jq -r '.version')
  mig_description=$(echo "${mig_json}" | jq -r '.description')
  mig_op_count=$(echo "${mig_json}" | jq '.operations | length')

  log "─────────────────────────────────────────────"
  log "Applying migration ${mig_version}: ${mig_description}"
  log "Operations: ${mig_op_count}"

  # Check for partial apply: if any object from this migration already exists in Twenty
  # but the migration is not in the tracker, surface a warning and abort.
  # We check the first createObject in the migration.
  first_obj_name=$(echo "${mig_json}" | jq -r '[.operations[] | select(.kind == "createObject")] | first | .input.nameSingular // empty')
  if [ -n "${first_obj_name}" ] && [ -n "${OBJECT_UUID_MAP[${first_obj_name}]:-}" ]; then
    err "CONFLICT DETECTED: Object '${first_obj_name}' already exists in Twenty but migration ${mig_version} is not in the tracker."
    err "This indicates a partial apply from a previous run or manual intervention."
    err ""
    err "Manual resolution required:"
    err "  Option A: Remove the already-applied operations from ${mig_file} and re-run."
    err "  Option B: Delete the partial objects in the Twenty UI and re-run cleanly."
    err "  Option C: If this migration is fully applied, insert a tracker row manually:"
    err "    docker exec -e PGPASSWORD=<pwd> ${BOOKINGS_DB_CONTAINER} psql -U ${BOOKINGS_DB_USER} -d ${BOOKINGS_DB_NAME} -c \"INSERT INTO twenty_schema_migrations (version, description, operations_count, applied_by, applied_against) VALUES ('${mig_version}', '${mig_description}', ${mig_op_count}, 'manual', '${TWENTY_BASE}');\""
    err ""
    err "Script will not attempt automatic recovery. Exiting."
    record_error "${RUN_ID}" "${mig_version}" \
      "PARTIAL_APPLY: Object '${first_obj_name}' exists in Twenty but ${mig_version} is not in tracker" \
      "{\"migrationFile\":\"${mig_file}\",\"conflictingObject\":\"${first_obj_name}\"}"
    exit 1
  fi

  op_index=0
  while IFS= read -r operation; do
    kind=$(echo "${operation}" | jq -r '.kind')
    input=$(echo "${operation}" | jq -c '.input')
    op_label="${mig_version}[${op_index}] ${kind}"

    log "  op ${op_index}: ${kind} — $(echo "${input}" | jq -r '.objectName // .nameSingular // "?"')"

    case "${kind}" in
      createObject)
        response=$(create_object "${input}")
        ;;
      createField)
        response=$(create_field "${input}")
        ;;
      updateObject)
        # Resolve nameSingular → id and call updateOneObject
        obj_name=$(echo "${input}" | jq -r '.nameSingular')
        obj_uuid="${OBJECT_UUID_MAP[${obj_name}]:-}"
        if [ -z "${obj_uuid}" ]; then
          response='{"errors":[{"message":"Object not found in state cache: '"${obj_name}"'"}]}'
        else
          update_payload=$(echo "${input}" | jq --arg id "${obj_uuid}" 'del(.nameSingular) | {"input":{"id":$id,"update":.}}')
          MUTATION=$(cat <<'GQLEOF'
mutation UpdateOneObject($input: UpdateOneObjectInput!) {
  updateOneObject(input: $input) {
    id
    isActive
    labelSingular
    labelPlural
  }
}
GQLEOF
)
          body=$(jq -n --arg q "${MUTATION}" --argjson v "${update_payload}" '{"query":$q,"variables":$v}')
          response=$(curl -s --max-time 30 \
            -X POST \
            -H "Authorization: Bearer ${TWENTY_API_KEY}" \
            -H "Content-Type: application/json" \
            "${TWENTY_BASE}/metadata" \
            -d "${body}")
        fi
        ;;
      *)
        err "  Unknown operation kind '${kind}' at index ${op_index}. Supported: createObject, createField, updateObject."
        record_error "${RUN_ID}" "${op_label}" \
          "Unknown operation kind '${kind}'" \
          "{\"version\":\"${mig_version}\",\"operationIndex\":${op_index},\"kind\":\"${kind}\"}"
        exit 1
        ;;
    esac

    # Check for resolution failure (our internal error format)
    local_error=$(echo "${response}" | jq -r '.error // empty' 2>/dev/null || true)
    if [ -n "${local_error}" ]; then
      local_detail=$(echo "${response}" | jq -r '.detail // ""' 2>/dev/null || true)
      err "  FAILED at ${op_label}: ${local_error} — ${local_detail}"
      record_error "${RUN_ID}" "${op_label}" \
        "${local_error}: ${local_detail}" \
        "{\"version\":\"${mig_version}\",\"operationIndex\":${op_index},\"kind\":\"${kind}\",\"input\":${input}}"
      err "Migration ${mig_version} NOT marked applied."
      exit 1
    fi

    # Check for GraphQL errors
    gql_errors=$(echo "${response}" | jq -r '.errors // empty' 2>/dev/null || true)
    if [ -n "${gql_errors}" ] && [ "${gql_errors}" != "null" ]; then
      first_error=$(echo "${response}" | jq -r '.errors[0].message // "unknown error"')
      err "  FAILED at ${op_label}: ${first_error}"
      err "  Full response: ${response}"
      record_error "${RUN_ID}" "${op_label}" \
        "${first_error}" \
        "{\"version\":\"${mig_version}\",\"operationIndex\":${op_index},\"kind\":\"${kind}\",\"input\":${input},\"response\":$(echo "${response}" | jq -c '.')}"
      err "Migration ${mig_version} NOT marked applied."
      exit 1
    fi

    # Update in-memory state cache with the new object/field UUID
    case "${kind}" in
      createObject)
        new_name=$(echo "${response}" | jq -r '.data.createOneObject.nameSingular // empty')
        new_uuid=$(echo "${response}" | jq -r '.data.createOneObject.id // empty')
        if [ -n "${new_name}" ] && [ -n "${new_uuid}" ]; then
          OBJECT_UUID_MAP["${new_name}"]="${new_uuid}"
          log "    Created object '${new_name}' → ${new_uuid}"
        fi
        ;;
      createField)
        field_name=$(echo "${response}" | jq -r '.data.createOneField.name // empty')
        field_uuid=$(echo "${response}" | jq -r '.data.createOneField.id // empty')
        if [ -n "${field_name}" ] && [ -n "${field_uuid}" ]; then
          log "    Created field '${field_name}' → ${field_uuid}"
        fi
        ;;
      updateObject)
        log "    Updated object."
        ;;
    esac

    op_index=$((op_index + 1))

    # Rate-limit pacing: sleep between API calls
    pace

  done < <(echo "${mig_json}" | jq -c '.operations[]')

  # All operations succeeded — record in tracker
  psql_exec "
    INSERT INTO twenty_schema_migrations (version, description, operations_count, applied_by, applied_against)
    VALUES ('${mig_version}', '${mig_description//\'/\'\'}', ${mig_op_count}, '${RUN_ID}', '${TWENTY_BASE}')
    ON CONFLICT (version) DO NOTHING;
  " >/dev/null

  log "Migration ${mig_version} applied successfully (${mig_op_count} operations)."
  SUMMARY_APPLIED+=("${mig_version} (${mig_op_count} ops)")
done

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
log ""
log "════════════════════════════════════════════"
log " apply-twenty-schema.sh — Summary"
log "════════════════════════════════════════════"

if [ ${#SUMMARY_APPLIED[@]} -gt 0 ]; then
  log " Applied:"
  for entry in "${SUMMARY_APPLIED[@]}"; do
    log "   [OK] ${entry}"
  done
else
  log " Applied:  (none)"
fi

FINAL_APPLIED=$(psql_exec "SELECT version, applied_at::text FROM twenty_schema_migrations ORDER BY version;" 2>/dev/null || true)
log ""
log " Current tracker state:"
while IFS='|' read -r ver ts; do
  [ -n "${ver}" ] && log "   ${ver}  ${ts}"
done <<< "${FINAL_APPLIED}"

log "════════════════════════════════════════════"
log "Done."
