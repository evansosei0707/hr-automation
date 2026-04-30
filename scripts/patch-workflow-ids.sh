#!/bin/bash
# Patches a-communications.json and dpa-handler.json with current subflow IDs.
# Run before each import of the main workflow.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Fetching current workflow IDs from n8n DB ==="

WA_SEND_ID=$(docker exec hr-bookings-db psql -U n8n_bookings -d n8n -tA \
  -c "SELECT id FROM workflow_entity WHERE name = 'Subflow — WA Send' ORDER BY active DESC, \"createdAt\" DESC LIMIT 1;")

CLAUDE_CALL_ID=$(docker exec hr-bookings-db psql -U n8n_bookings -d n8n -tA \
  -c "SELECT id FROM workflow_entity WHERE name = 'Subflow — Claude Call' ORDER BY active DESC, \"createdAt\" DESC LIMIT 1;")

DPA_HANDLER_ID=$(docker exec hr-bookings-db psql -U n8n_bookings -d n8n -tA \
  -c "SELECT id FROM workflow_entity WHERE name = 'Subflow — DPA Handler' ORDER BY active DESC, \"createdAt\" DESC LIMIT 1;")

BOOKINGS_CRED_ID=$(docker exec hr-bookings-db psql -U n8n_bookings -d n8n -tA \
  -c "SELECT id FROM credentials_entity WHERE name = 'Bookings DB (n8n_bookings)' LIMIT 1;")

REDIS_CRED_ID=$(docker exec hr-bookings-db psql -U n8n_bookings -d n8n -tA \
  -c "SELECT id FROM credentials_entity WHERE name = 'HRA Redis' LIMIT 1;")

echo "WA Send ID:      $WA_SEND_ID"
echo "Claude Call ID:  $CLAUDE_CALL_ID"
echo "DPA Handler ID:  $DPA_HANDLER_ID"
echo "Bookings Cred:   $BOOKINGS_CRED_ID"
echo "Redis Cred:      $REDIS_CRED_ID"

if [ -z "$WA_SEND_ID" ] || [ -z "$CLAUDE_CALL_ID" ] || [ -z "$DPA_HANDLER_ID" ]; then
  echo "ERROR: One or more subflows not found. Import subflows first."
  exit 1
fi

echo ""
echo "=== Patching JSON files ==="

python3 - "$WA_SEND_ID" "$CLAUDE_CALL_ID" "$DPA_HANDLER_ID" \
          "$BOOKINGS_CRED_ID" "$REDIS_CRED_ID" << 'PYEOF'
import sys, json, re

wa_id, cc_id, dpa_id, bookings_cred, redis_cred = sys.argv[1:6]

# ID pattern: 16-char alphanumeric
ID_PAT = re.compile(r'[A-Za-z0-9]{16}')

# Credential IDs to always preserve
PRESERVE_CREDS = {bookings_cred, redis_cred}

for filepath in [
    'n8n-workflows/communications/a-communications.json',
    'n8n-workflows/communications/dpa-handler.json',
]:
    with open(filepath) as f:
        data = json.load(f)

    content = json.dumps(data, indent=2)

    # Replace any workflow ID references by scanning Execute Workflow nodes
    # We identify which subflow each node calls by checking what the current
    # value is and mapping it to the correct current ID.
    # Since we don't know old→new mapping in advance, we patch via node names.

    for node in data.get('nodes', []):
        if node.get('type') == 'n8n-nodes-base.executeWorkflow':
            node_name = node.get('name', '')
            params = node.get('parameters', {})
            wf_id_field = params.get('workflowId', {})
            if isinstance(wf_id_field, dict):
                # Determine correct ID by node name context
                name_lower = node_name.lower()
                if any(x in name_lower for x in ['wa', 'send', 'whatsapp', 'reply', 'ack', 'retype', 'template', 'distress', 'opted']):
                    wf_id_field['value'] = wa_id
                elif any(x in name_lower for x in ['claude', 'classify', 'intent', 'generate', 'haiku', 'sonnet']):
                    wf_id_field['value'] = cc_id
                elif any(x in name_lower for x in ['dpa', 'data', 'deletion', 'access', 'gdpr']):
                    wf_id_field['value'] = dpa_id

    # Also patch credential IDs
    def patch_creds(obj):
        if isinstance(obj, dict):
            if obj.get('id') in ('PLACEHOLDER_BOOKINGS_DB_CRED',) or \
               (obj.get('id') and len(obj.get('id','')) == 16 and 
                obj.get('name') == 'Bookings DB (n8n_bookings)'):
                obj['id'] = bookings_cred
            if obj.get('id') in ('PLACEHOLDER_REDIS_CRED',) or \
               (obj.get('id') and len(obj.get('id','')) == 16 and
                obj.get('name') == 'HRA Redis'):
                obj['id'] = redis_cred
            for v in obj.values():
                patch_creds(v)
        elif isinstance(obj, list):
            for item in obj:
                patch_creds(item)

    patch_creds(data)

    with open(filepath, 'w') as f:
        json.dump(data, f, indent=2)
    print(f"Patched: {filepath}")

print("All files patched.")
PYEOF

echo ""
echo "=== Done. Now import a-communications.json into n8n. ==="
