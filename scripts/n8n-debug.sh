#!/usr/bin/env bash
# Query n8n execution logs and workflow state.
# - executions / last-error / workflow-status use the REST API.
# - execution <id> queries the n8n DB directly (execution_data table) because
#   n8n 2.x REST API returns empty runData in includeData responses.
# Usage:
#   ./scripts/n8n-debug.sh executions           — last 10 executions
#   ./scripts/n8n-debug.sh execution <id>       — all nodes + error details for one execution
#   ./scripts/n8n-debug.sh last-error           — full details of the most recent failure
#   ./scripts/n8n-debug.sh workflow-status      — all workflows with active/archived state

set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f infrastructure/.env ]; then
  echo "ERROR: infrastructure/.env not found" >&2; exit 1
fi
set -a; source infrastructure/.env; set +a

N8N_URL="${N8N_API_URL:-http://localhost:5678}"
API_KEY="${N8N_API_KEY:?'N8N_API_KEY not set in infrastructure/.env'}"

n8n_get() {
  curl -sf "$N8N_URL/api/v1/$1" -H "X-N8N-API-KEY: $API_KEY"
}

# Temp dir cleaned up on exit
TMPDIR_LOCAL=$(mktemp -d /tmp/n8n-debug-XXXXXX)
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

CMD="${1:-help}"

# ── executions ──────────────────────────────────────────────────────────────
if [ "$CMD" = "executions" ]; then
  n8n_get "executions?limit=10" > "$TMPDIR_LOCAL/execs.json"
  n8n_get "workflows"           > "$TMPDIR_LOCAL/workflows.json"
  python3 - "$TMPDIR_LOCAL/execs.json" "$TMPDIR_LOCAL/workflows.json" <<'PY'
import json, sys
from datetime import datetime

with open(sys.argv[1]) as f: executions = json.load(f).get("data", [])
with open(sys.argv[2]) as f: wf_map = {w["id"]: w["name"] for w in json.load(f).get("data", [])}

STATUS_LABEL = {
    "success": "OK     ", "error": "ERROR  ",
    "running": "RUNNING", "waiting": "WAITING", "crashed": "CRASHED",
}
print("%-6s  %-7s  %-38s  %-20s  %s" % ("ID","STATUS","WORKFLOW","STARTED (UTC)","DURATION"))
print("-" * 95)
for ex in executions:
    wf_name = wf_map.get(ex.get("workflowId",""), ex.get("workflowId","?"))[:37]
    status  = STATUS_LABEL.get(ex.get("status",""), ex.get("status","?"))
    started = (ex.get("startedAt") or "")[:19].replace("T"," ")
    dur = ""
    if ex.get("startedAt") and ex.get("stoppedAt"):
        try:
            s = datetime.fromisoformat(ex["startedAt"].replace("Z","+00:00"))
            e = datetime.fromisoformat(ex["stoppedAt"].replace("Z","+00:00"))
            dur = "%.1fs" % (e-s).total_seconds()
        except Exception:
            pass
    print("%-6s  %-7s  %-38s  %-20s  %s" % (ex["id"], status, wf_name, started, dur))
PY

# ── execution <id> ───────────────────────────────────────────────────────────
elif [ "$CMD" = "execution" ]; then
  ID="${2:?'Usage: n8n-debug.sh execution <id>'}"
  # n8n 2.x REST API returns empty runData; query the DB directly instead.
  N8N_DB_CONTAINER="${N8N_DB_CONTAINER:-hr-bookings-db}"
  N8N_DB_USER="${N8N_DB_USER:-n8n_bookings}"
  N8N_DB_NAME="${N8N_DB_NAME:-n8n}"
  # Metadata query: small fields only (no JSON blobs to avoid | collisions)
  docker exec "$N8N_DB_CONTAINER" psql -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -tA \
    -c "SELECT e.id, e.status, e.\"startedAt\", e.\"stoppedAt\",
               (d.\"workflowData\"->>'name')
        FROM execution_entity e
        JOIN execution_data d ON d.\"executionId\" = e.id
        WHERE e.id = $ID;" \
    > "$TMPDIR_LOCAL/ex_meta.txt" 2>&1
  # Data column in its own query to avoid | separator collision with JSON content
  docker exec "$N8N_DB_CONTAINER" psql -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -tA \
    -c "SELECT data FROM execution_data WHERE \"executionId\" = $ID;" \
    > "$TMPDIR_LOCAL/ex_data.txt" 2>&1
  python3 - "$TMPDIR_LOCAL/ex_meta.txt" "$TMPDIR_LOCAL/ex_data.txt" <<'PY'
import json, sys

meta_raw = open(sys.argv[1]).read().strip()
data_raw = open(sys.argv[2]).read().strip()

if meta_raw.startswith("ERROR") or meta_raw.startswith("psql:"):
    print("ERROR: DB query failed:")
    print(meta_raw)
    sys.exit(1)
if not meta_raw:
    print("ERROR: execution %s not found in n8n DB" % sys.argv[1].split("/")[-1])
    sys.exit(1)

parts = meta_raw.split("|", 4)
if len(parts) < 4:
    print("ERROR: unexpected metadata format: %r" % meta_raw)
    sys.exit(1)

ex_id    = parts[0]
status   = parts[1]
started  = parts[2]
stopped  = parts[3]
wf_name  = parts[4] if len(parts) > 4 else "?"

print("Execution : %s" % ex_id)
print("Workflow  : %s" % wf_name)
print("Status    : %s" % status)
print("Started   : %s" % started[:19].replace("T", " "))
print("Stopped   : %s" % (stopped[:19].replace("T", " ") if stopped else "—"))

# Deserialise n8n's reference-compressed execution data array.
# Format: JSON array where numeric string values are back-references by index.
if not data_raw or data_raw.startswith("psql:"):
    print("ERROR: could not fetch execution data from DB")
    sys.exit(1)
arr = json.loads(data_raw)

def deref(val, arr):
    if isinstance(val, str) and val.isdigit():
        idx = int(val)
        return deref(arr[idx], arr) if idx < len(arr) else val
    if isinstance(val, dict):
        return {k: deref(v, arr) for k, v in val.items()}
    if isinstance(val, list):
        return [deref(v, arr) for v in val]
    return val

root       = deref(arr[0], arr)
rdata      = root.get("resultData", {})
run_data   = rdata.get("runData", {}) or {}
last_node  = rdata.get("lastNodeExecuted", "")
error      = rdata.get("error")

if last_node:
    print("Last node : %s" % last_node)

if error:
    print()
    print("─── ERROR ───────────────────────────────────────")
    print("Message    : %s" % error.get("message", ""))
    print("Description: %s" % error.get("description", ""))
    node = error.get("node")
    if isinstance(node, dict):
        print("Node       : %s" % node.get("name", ""))
    elif node:
        print("Node       : %s" % node)
    ctx = error.get("context")
    if ctx:
        print("Context    :")
        print(json.dumps(ctx, indent=2)[:800])

print()
print("─── NODES EXECUTED (%d) ─────────────────────────" % len(run_data))

# Sort by executionIndex (insertion order fallback for older entries)
def sort_key(item):
    name, entries = item
    if entries and isinstance(entries, list):
        return entries[-1].get("executionIndex", 0)
    return 0

for name, entries in sorted(run_data.items(), key=sort_key):
    st = "?"
    ms = ""
    if entries and isinstance(entries, list):
        e = entries[-1]
        st = e.get("executionStatus", "?")
        ms = ("%dms" % e.get("executionTime", 0)) if e.get("executionTime") else ""
    print("  %-10s  %-6s  %s" % (st, ms, name))
PY

# ── last-error ───────────────────────────────────────────────────────────────
elif [ "$CMD" = "last-error" ]; then
  n8n_get "executions?limit=1&status=error" > "$TMPDIR_LOCAL/lasterr.json"
  ERR_ID=$(python3 - "$TMPDIR_LOCAL/lasterr.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1])).get("data",[])
print(data[0]["id"] if data else "")
PY
)
  if [ -z "$ERR_ID" ]; then
    echo "No failed executions found."
    exit 0
  fi
  echo "Most recent failed execution: $ERR_ID"
  echo ""
  exec "$0" execution "$ERR_ID"

# ── workflow-status ──────────────────────────────────────────────────────────
elif [ "$CMD" = "workflow-status" ]; then
  n8n_get "workflows" > "$TMPDIR_LOCAL/wf.json"
  python3 - "$TMPDIR_LOCAL/wf.json" <<'PY'
import json, sys

workflows = json.load(open(sys.argv[1])).get("data", [])
print("%-20s  %-6s  %-8s  %s" % ("ID","ACTIVE","ARCHIVED","NAME"))
print("-" * 80)
for wf in sorted(workflows, key=lambda w: w["name"]):
    active   = "yes" if wf.get("active")     else "no"
    archived = "yes" if wf.get("isArchived") else "no"
    print("%-20s  %-6s  %-8s  %s" % (wf["id"], active, archived, wf["name"]))
print("\nTotal: %d workflow(s)" % len(workflows))
PY

# ── cleanup ──────────────────────────────────────────────────────────────────
elif [ "$CMD" = "cleanup" ]; then
  n8n_get "workflows" > "$TMPDIR_LOCAL/wf.json"
  # Identify archived workflow IDs — these are old import versions, safe to delete
  TO_DELETE=$(python3 - "$TMPDIR_LOCAL/wf.json" <<'PY'
import json, sys

workflows = json.load(open(sys.argv[1])).get("data", [])
archived = [wf for wf in workflows if wf.get("isArchived")]
active   = [wf for wf in workflows if not wf.get("isArchived")]

print("Archived (will delete): %d" % len(archived), flush=True)
print("Active   (will keep):   %d" % len(active),   flush=True)
print("---")
for wf in archived:
    print(wf["id"])
PY
)

  # Print header lines and collect IDs
  echo "$TO_DELETE" | head -3
  IDS=$(echo "$TO_DELETE" | tail -n +4)

  if [ -z "$IDS" ]; then
    echo "Nothing to clean up."
    exit 0
  fi

  COUNT=0
  FAIL=0
  while IFS= read -r wf_id; do
    [ -z "$wf_id" ] && continue
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
           "$N8N_URL/api/v1/workflows/$wf_id" \
           -H "X-N8N-API-KEY: $API_KEY")
    if [ "$HTTP" = "200" ]; then
      COUNT=$((COUNT + 1))
    else
      echo "  WARN: DELETE $wf_id returned HTTP $HTTP" >&2
      FAIL=$((FAIL + 1))
    fi
  done <<< "$IDS"

  echo "Deleted $COUNT archived workflow(s). Failed: $FAIL"

# ── help ─────────────────────────────────────────────────────────────────────
else
  cat <<'USAGE'
Usage: ./scripts/n8n-debug.sh <command> [args]

  executions              List last 10 executions (all statuses)
  execution <id>          All nodes executed + error details (reads n8n DB directly)
  last-error              Fetch and display the most recent failed execution
  workflow-status         List all workflows with active and archived state
  cleanup                 Delete all archived (inactive) workflow versions

Reads N8N_API_KEY, N8N_API_URL from infrastructure/.env
Reads N8N_DB_CONTAINER (default: hr-bookings-db), N8N_DB_USER (default: n8n_bookings),
      N8N_DB_NAME (default: n8n) from environment or infrastructure/.env
USAGE
fi
