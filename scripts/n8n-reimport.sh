#!/usr/bin/env bash
# Delete the existing n8n workflow with the same name and re-import from JSON.
# Patches subflow IDs first, then activates the imported workflow.
#
# Usage:
#   ./scripts/n8n-reimport.sh n8n-workflows/communications/a-communications.json
#   ./scripts/n8n-reimport.sh n8n-workflows/communications/wa-send.json

set -euo pipefail
cd "$(dirname "$0")/.."

JSON_FILE="${1:?'Usage: n8n-reimport.sh <path-to-workflow.json>'}"

if [ ! -f "$JSON_FILE" ]; then
  echo "ERROR: file not found: $JSON_FILE" >&2; exit 1
fi

if [ ! -f infrastructure/.env ]; then
  echo "ERROR: infrastructure/.env not found" >&2; exit 1
fi
set -a; source infrastructure/.env; set +a

N8N_URL="${N8N_API_URL:-http://localhost:5678}"
API_KEY="${N8N_API_KEY:?'N8N_API_KEY not set in infrastructure/.env'}"

n8n_api() {
  local method="$1"; local path="$2"; shift 2
  curl -sf -X "$method" "$N8N_URL/api/v1/$path" \
    -H "X-N8N-API-KEY: $API_KEY" \
    -H "Content-Type: application/json" \
    "$@"
}

# ── Step 1: patch subflow + credential IDs ───────────────────────────────────
echo "=== Step 1: patching workflow IDs ==="
./scripts/patch-workflow-ids.sh

# ── Step 2: read workflow name from JSON ─────────────────────────────────────
WF_NAME=$(python3 -c "import json; print(json.load(open('$JSON_FILE'))['name'])")
echo ""
echo "=== Step 2: importing '$WF_NAME' from $JSON_FILE ==="

# ── Step 3: find and delete any existing workflow with this name ──────────────
echo ""
echo "=== Step 3: looking for existing workflow named '$WF_NAME' ==="
EXISTING=$(n8n_api GET "workflows" | python3 -c "
import sys, json
name = '$WF_NAME'
for wf in json.load(sys.stdin).get('data', []):
    if wf['name'] == name:
        print(wf['id'])
        break
")

if [ -n "$EXISTING" ]; then
  echo "Found existing workflow ID: $EXISTING — deleting..."
  n8n_api DELETE "workflows/$EXISTING" | python3 -c "
import sys, json
r = json.load(sys.stdin)
if r.get('id') or r.get('success'):
    print('Deleted.')
else:
    print('Delete response:', json.dumps(r))
" || echo "Delete returned non-JSON (may still have succeeded)"
else
  echo "No existing workflow found — clean import."
fi

# ── Step 4: strip local ID and import ────────────────────────────────────────
echo ""
echo "=== Step 4: importing workflow ==="
IMPORT_JSON=$(python3 - <<PYEOF
import json, sys

with open('$JSON_FILE') as f:
    wf = json.load(f)

# Remove fields n8n assigns on creation
for key in ('id', 'createdAt', 'updatedAt', 'versionId'):
    wf.pop(key, None)

# Ensure not active on import (we activate separately)
wf['active'] = False

print(json.dumps(wf))
PYEOF
)

NEW_ID=$(echo "$IMPORT_JSON" | n8n_api POST "workflows" -d @- | python3 -c "
import sys, json
r = json.load(sys.stdin)
if 'id' not in r:
    print('ERROR: import failed:', json.dumps(r), file=sys.stderr)
    sys.exit(1)
print(r['id'])
")

echo "Imported with new ID: $NEW_ID"

# ── Step 5: activate ─────────────────────────────────────────────────────────
echo ""
echo "=== Step 5: activating workflow $NEW_ID ==="
n8n_api POST "workflows/$NEW_ID/activate" | python3 -c "
import sys, json
r = json.load(sys.stdin)
active = r.get('active', False)
print('Active:', active)
if not active:
    print('WARNING: workflow did not activate — check n8n UI for trigger errors')
"

echo ""
echo "=== Done: '$WF_NAME' is live at ID $NEW_ID ==="
