#!/usr/bin/env bash
# Query n8n execution logs and workflow state via the REST API.
# Usage:
#   ./scripts/n8n-debug.sh executions           — last 10 executions
#   ./scripts/n8n-debug.sh execution <id>       — error details for one execution
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
  n8n_get "executions/$ID?includeData=true" > "$TMPDIR_LOCAL/ex.json"
  python3 - "$TMPDIR_LOCAL/ex.json" <<'PY'
import json, sys

with open(sys.argv[1]) as f: ex = json.load(f)
wf_name = (ex.get("workflowData") or {}).get("name") or ex.get("workflowId","?")
print("Execution : %s" % ex["id"])
print("Workflow  : %s" % wf_name)
print("Status    : %s" % ex.get("status","?"))
print("Started   : %s" % (ex.get("startedAt") or "?")[:19].replace("T"," "))
print("Stopped   : %s" % (ex.get("stoppedAt") or "?")[:19].replace("T"," "))

rdata = (ex.get("data") or {}).get("resultData") or {}
last_node = rdata.get("lastNodeExecuted")
if last_node:
    print("Last node : %s" % last_node)

err = rdata.get("error")
if err:
    print()
    print("─── ERROR ───────────────────────────────────────")
    print("Message    : %s" % err.get("message",""))
    print("Description: %s" % err.get("description",""))
    node = err.get("node")
    if isinstance(node, dict):
        print("Node       : %s" % node.get("name",""))
    elif node:
        print("Node       : %s" % node)
    ctx = err.get("context")
    if ctx:
        print("Context    :")
        print(json.dumps(ctx, indent=2)[:800])
else:
    print()
    print("No top-level error. Run data summary (last 8 nodes):")
    run_data = rdata.get("runData") or {}
    for name in list(run_data.keys())[-8:]:
        entries = run_data[name]
        st = entries[-1].get("executionStatus","?") if entries else "?"
        print("  %-42s %s" % (name, st))
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
  execution <id>          Full error/run details for a specific execution ID
  last-error              Fetch and display the most recent failed execution
  workflow-status         List all workflows with active and archived state
  cleanup                 Delete all archived (inactive) workflow versions

Reads N8N_API_KEY and N8N_API_URL from infrastructure/.env
USAGE
fi
