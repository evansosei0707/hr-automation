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
    'n8n-workflows/screening/b-screening.json',
    'n8n-workflows/screening/c-screening.json',
    'n8n-workflows/scheduling/d-scheduling.json',
    'n8n-workflows/reporting/f-reporting.json',
]:
    with open(filepath) as f:
        data = json.load(f)

    content = json.dumps(data, indent=2)

    # Replace any workflow ID references by scanning Execute Workflow nodes
    # We identify which subflow each node calls by checking what the current
    # value is and mapping it to the correct current ID.
    # Since we don't know old→new mapping in advance, we patch via node names.

    # Explicit node-name → subflow mapping. Keyword-based matching previously
    # routed "Generate Reply" to WA Send because 'reply' is in the WA keyword
    # list. Explicit names eliminate that whole class of bug.
    NODE_TO_SUBFLOW = {
        # WA Send
        'Send Consent Refusal Ack': wa_id,
        'Send Already Opted-Out Reply': wa_id,
        'Send Please Retype — Local Language': wa_id,
        'Send Please Retype — Low Quality': wa_id,
        'Send Distress Holding Reply': wa_id,
        'Send Reply — WA': wa_id,
        'Send Holding Reply — Calibration': wa_id,
        # Claude Call
        'Generate Reply — Claude Sonnet': cc_id,
        'Classify Intent — Claude Haiku': cc_id,
        # DPA Handler
        'Handle DPA Before Consent': dpa_id,
        'Handle DPA Request': dpa_id,
        'Send Data Access Ack': wa_id,
        'Send Deletion Ack': wa_id,
        # Workflow B — Screening
        'Extract Structured Facts — Claude Sonnet': cc_id,
        'Score Against Rubric — Claude Sonnet': cc_id,
        'Send WA Ack': wa_id,
        # Workflow C — Blue-Collar Screening
        'Send Question 0 — WA': wa_id,
        'Send Next Question': wa_id,
        'Send Clarifier — WA': wa_id,
        'Send Closing Message': wa_id,
        'Send Reminder Template': wa_id,
        'Send Withdrawal Template': wa_id,
        'Normalise Answer — Haiku': cc_id,
        # Workflow D — Scheduling
        'Send Slots Expired — WA': wa_id,
        'Send Reprompt — WA': wa_id,
        'Parse Reply — Haiku Fallback': cc_id,
        'Send Slot Taken — WA': wa_id,
        'Send Confirmation — Candidate WA': wa_id,
        'Send Offer — WA': wa_id,
        # Workflow F — Weekly Reporting
        'Claude Haiku Narrative': cc_id,
        'Send to Staff WA': wa_id,
    }

    for node in data.get('nodes', []):
        if node.get('type') == 'n8n-nodes-base.executeWorkflow':
            node_name = node.get('name', '')
            params = node.get('parameters', {})
            wf_id_field = params.get('workflowId', {})
            if isinstance(wf_id_field, dict) and node_name in NODE_TO_SUBFLOW:
                wf_id_field['value'] = NODE_TO_SUBFLOW[node_name]
            elif isinstance(wf_id_field, dict):
                print(f"  WARN: no subflow mapping for node {node_name!r}", file=sys.stderr)

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
