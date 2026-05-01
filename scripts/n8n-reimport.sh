#!/usr/bin/env bash
# Delete the existing n8n workflow with the same name and re-import from JSON.
# Patches subflow IDs first, then activates the imported workflow.
#
# Cascade behaviour: if the imported file is a known subflow (WA Send, Claude Call,
# DPA Handler), the script automatically re-runs patch-workflow-ids.sh and reimports
# a-communications.json afterward, since subflow IDs change on every import.
#
# Usage:
#   ./scripts/n8n-reimport.sh n8n-workflows/communications/wa-send.json
#   ./scripts/n8n-reimport.sh n8n-workflows/communications/a-communications.json

set -euo pipefail
cd "$(dirname "$0")/.."

JSON_FILE="${1:?'Usage: n8n-reimport.sh <path-to-workflow.json>'}"
MAIN_WORKFLOW="n8n-workflows/communications/a-communications.json"

if [ ! -f "$JSON_FILE" ]; then
  echo "ERROR: file not found: $JSON_FILE" >&2; exit 1
fi
if [ ! -f infrastructure/.env ]; then
  echo "ERROR: infrastructure/.env not found" >&2; exit 1
fi
set -a; source infrastructure/.env; set +a

N8N_URL="${N8N_API_URL:-http://localhost:5678}"
API_KEY="${N8N_API_KEY:?'N8N_API_KEY not set in infrastructure/.env'}"

# ── helpers ──────────────────────────────────────────────────────────────────
n8n_get() {
  curl -sf "$N8N_URL/api/v1/$1" -H "X-N8N-API-KEY: $API_KEY"
}
n8n_post() {
  curl -sf -X POST "$N8N_URL/api/v1/$1" \
    -H "X-N8N-API-KEY: $API_KEY" -H "Content-Type: application/json" "${@:2}"
}
n8n_delete() {
  curl -sf -X DELETE "$N8N_URL/api/v1/$1" -H "X-N8N-API-KEY: $API_KEY"
}

_import_one() {
  local file="$1"
  local WF_NAME
  WF_NAME=$(python3 -c "import json; print(json.load(open('$file'))['name'])")

  echo ""
  echo "━━━ Importing: $WF_NAME ($file)"

  # ── Find and delete ALL existing workflows with same name ────────────────
  # Must deactivate before deleting — active workflows hold webhook endpoints
  # and the new import can't activate on the same URL while they're running.
  echo "  [1/3] Checking for existing workflows named '$WF_NAME'..."
  ALL_IDS=$(n8n_get "workflows" | python3 -c "
import sys, json
name = '$WF_NAME'
for wf in json.load(sys.stdin).get('data', []):
    if wf['name'] == name:
        print(wf['id'], wf.get('active','false'))
" 2>/dev/null || true)

  if [ -z "$ALL_IDS" ]; then
    echo "  [1/3] No existing workflows — clean import."
  else
    while IFS=" " read -r wf_id wf_active; do
      [ -z "$wf_id" ] && continue
      if [ "$wf_active" = "True" ] || [ "$wf_active" = "true" ]; then
        echo "  [1/3] Deactivating active ID: $wf_id"
        n8n_post "workflows/$wf_id/deactivate" > /dev/null 2>&1 || true
      fi
      echo "  [1/3] Deleting ID: $wf_id"
      n8n_delete "workflows/$wf_id" > /dev/null 2>&1 \
        || echo "  WARN: delete $wf_id returned non-200"
    done <<< "$ALL_IDS"
  fi

  # ── Strip read-only fields and build import payload ───────────────────────
  echo "  [2/3] Building import payload..."
  IMPORT_JSON=$(python3 - <<PYEOF
import json, sys
with open('$file') as f:
    wf = json.load(f)
# These fields are rejected by the API as read-only on POST
for key in ('id', 'createdAt', 'updatedAt', 'versionId',
            'active', 'meta', 'pinData', 'staticData', 'tags'):
    wf.pop(key, None)
print(json.dumps(wf))
PYEOF
)

  # ── POST to create ────────────────────────────────────────────────────────
  RESPONSE=$(echo "$IMPORT_JSON" | n8n_post "workflows" -d @-)
  if ! echo "$RESPONSE" | python3 -c "import sys,json; r=json.load(sys.stdin); assert 'id' in r" 2>/dev/null; then
    echo "  ERROR: import failed. API response:" >&2
    echo "$RESPONSE" >&2
    return 1
  fi
  NEW_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  echo "  [2/3] Imported — new ID: $NEW_ID"

  # ── Activate ──────────────────────────────────────────────────────────────
  echo "  [3/3] Activating..."
  ACT_RESP=$(curl -s -X POST "$N8N_URL/api/v1/workflows/$NEW_ID/activate" \
    -H "X-N8N-API-KEY: $API_KEY" -H "Content-Type: application/json")
  ACTIVE=$(echo "$ACT_RESP" | python3 -c "
import sys,json
r=json.load(sys.stdin)
if 'message' in r and r.get('active') is None:
    print('ERROR: ' + r['message'], file=sys.stderr)
    print('false')
else:
    print(str(r.get('active','')).lower())
" 2>/dev/null || echo "false")
  if [ "$ACTIVE" != "true" ]; then
    echo "  WARN: activate returned active=$ACTIVE"
    echo "  Response: $(echo "$ACT_RESP" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('message','?'))" 2>/dev/null)"
  else
    echo "  [3/3] Active. Done: $WF_NAME @ $NEW_ID"
  fi
  echo "$NEW_ID"
}

# ── Step 1: patch subflow + credential IDs ───────────────────────────────────
echo "=== Step 1: patching workflow IDs ==="
./scripts/patch-workflow-ids.sh

# ── Step 2: import the requested file ────────────────────────────────────────
echo ""
echo "=== Step 2: importing requested workflow ==="
_import_one "$JSON_FILE"

# ── Step 3: cascade if this is a subflow ────────────────────────────────────
WF_NAME=$(python3 -c "import json; print(json.load(open('$JSON_FILE'))['name'])")
SUBFLOW_NAMES=("Subflow — WA Send" "Subflow — Claude Call" "Subflow — DPA Handler"
               "Subflow — WA Send" "Subflow — Claude Call" "Subflow — DPA Handler")

IS_SUBFLOW=false
for sname in "${SUBFLOW_NAMES[@]}"; do
  if [ "$WF_NAME" = "$sname" ]; then
    IS_SUBFLOW=true; break
  fi
done

if [ "$IS_SUBFLOW" = "true" ] && [ "$JSON_FILE" != "$MAIN_WORKFLOW" ]; then
  echo ""
  echo "=== Step 3: subflow detected — cascading to re-import main workflow ==="
  echo "    (subflow IDs changed; re-patching before importing a-communications)"
  echo ""
  echo "--- Re-running patch-workflow-ids.sh ---"
  ./scripts/patch-workflow-ids.sh
  _import_one "$MAIN_WORKFLOW"
else
  echo ""
  echo "=== Step 3: not a subflow — no cascade needed ==="
fi

echo ""
echo "=== All done ==="
