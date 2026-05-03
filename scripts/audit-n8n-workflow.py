#!/usr/bin/env python3
"""audit-n8n-workflow.py — static analysis for known n8n bug classes.

Usage:
    python3 scripts/audit-n8n-workflow.py <workflow.json> [<workflow2.json> ...]

Exit codes:
    0 — no issues found
    1 — one or more issues found
"""

import json
import re
import sys
from pathlib import Path

# ──────────────────────────────────────────────
# Known NOT-NULL columns per migration version
# ──────────────────────────────────────────────
REQUIRED_BINDINGS = {
    "workflow_errors": {"workflow_name", "execution_id", "error_message"},
    "event_log":       {"workflow_name", "level", "event"},
    "ai_call_log":     {"workflow_name", "model"},
    "system_incident": {"kind", "severity", "summary"},
}

# Table name fragments → canonical table name mapping
TABLE_FRAGMENTS = {
    "workflow_errors":  "workflow_errors",
    "event_log":        "event_log",
    "ai_call_log":      "ai_call_log",
    "system_incident":  "system_incident",
}

# Columns that contain user/error text and should use array-form queryReplacement
TEXT_COLUMNS = {
    "error_message", "error_stack", "message_body", "content",
    "payload", "summary", "details", "event", "label", "note",
    "last_error", "failure_reason",
}

issues: list[dict] = []


def flag(node_name: str, node_id: str, check: str, detail: str) -> None:
    issues.append({"node": node_name, "id": node_id, "check": check, "detail": detail})


def node_label(n: dict) -> str:
    return f'"{n["name"]}" (id: {n.get("id", "?")})'


# ──────────────────────────────────────────────
# Check 1 — IF nodes with isEmpty on Redis GET output
# ──────────────────────────────────────────────
def check_isempty_on_redis_output(nodes: list[dict]) -> None:
    for n in nodes:
        if n.get("type") != "n8n-nodes-base.if":
            continue
        conditions = n.get("parameters", {})
        # Handle both old-style (conditions.conditions) and new-style (conditions.options)
        raw = json.dumps(conditions)
        if "isEmpty" in raw and ("$json.value" in raw or "propertyName" in raw.lower() or "redis" in raw.lower()):
            flag(n["name"], n.get("id", ""), "ISEMPTY_ON_REDIS",
                 "IF node uses isEmpty — n8n 2.18.5 evaluates null as NOT empty. "
                 "Use operator 'equals' with rightValue '' instead.")
        # Also catch any isEmpty that references a .value property (Redis GET output pattern)
        if "isEmpty" in raw and ".value" in raw:
            flag(n["name"], n.get("id", ""), "ISEMPTY_ON_VALUE",
                 "IF node uses isEmpty on a .value expression — "
                 "use 'equals \"\"' to handle null from Redis GET correctly.")
        # Catch boolean-equal operator used with JS expression in leftValue.
        # In n8n 2.18.5, operator 'equal' with type:'boolean' and a JS boolean expression
        # in leftValue routes ALL items to false regardless of the expression value.
        # Use string notEmpty (leftValue: $json.field ?? '', operator: notEmpty) instead.
        if '"equal"' in raw and '"boolean"' in raw:
            # Check if leftValue contains a JS expression (starts with ={{ )
            for cond_list in n.get("parameters", {}).get("conditions", {}).get("conditions", []):
                lv = cond_list.get("leftValue", "")
                if lv.startswith("={{") and cond_list.get("operator", {}).get("type") == "boolean":
                    flag(n["name"], n.get("id", ""), "BOOLEAN_EQUAL_JS_EXPR",
                         f"IF node uses boolean-equal operator with JS expression leftValue='{lv}'. "
                         "n8n 2.18.5 routes all items to false. "
                         "Use string notEmpty: leftValue={{ $json.field ?? '' }}, operator=notEmpty.")


# ──────────────────────────────────────────────
# Check 2 — alwaysOutputData inside parameters.options (not at node root)
# ──────────────────────────────────────────────
def check_alwaysoutputdata_location(nodes: list[dict]) -> None:
    for n in nodes:
        if "postgres" not in n.get("type", "").lower():
            continue
        options = n.get("parameters", {}).get("options", {})
        if options.get("alwaysOutputData"):
            flag(n["name"], n.get("id", ""), "ALWAYSOUTPUTDATA_IN_OPTIONS",
                 "alwaysOutputData is inside parameters.options — n8n ignores it there. "
                 "Move to node root level.")
        # Also warn if missing entirely on query nodes
        op = n.get("parameters", {}).get("operation", "")
        if op == "executeQuery" and not n.get("alwaysOutputData"):
            flag(n["name"], n.get("id", ""), "MISSING_ALWAYSOUTPUTDATA",
                 "Postgres executeQuery node is missing alwaysOutputData:true at root level. "
                 "Zero-row results will halt the execution chain.")


# ──────────────────────────────────────────────
# Check 3 — Set nodes with typeVersion < 3.3 using assignments format
# ──────────────────────────────────────────────
def check_set_node_typeversion(nodes: list[dict]) -> None:
    for n in nodes:
        if n.get("type") != "n8n-nodes-base.set":
            continue
        tv = n.get("typeVersion", 0)
        params = n.get("parameters", {})
        if "assignments" in params and tv < 3.3:
            flag(n["name"], n.get("id", ""), "SET_NODE_OLD_TYPEVERSION",
                 f"Set node uses 'assignments' format but typeVersion={tv}. "
                 "n8n reads assignments only at typeVersion>=3.3. Bump to 3.4.")


# ──────────────────────────────────────────────
# Check 4 — Execute Workflow nodes using fields.values instead of workflowInputs.value
# ──────────────────────────────────────────────
def check_execute_workflow_format(nodes: list[dict]) -> None:
    for n in nodes:
        if "executeWorkflow" not in n.get("type", ""):
            continue
        params = n.get("parameters", {})
        if "fields" in params and "values" in params.get("fields", {}):
            flag(n["name"], n.get("id", ""), "EW_FIELDS_VALUES",
                 "Execute Workflow node uses fields.values (old format) — "
                 "subflow receives no input. Use workflowInputs.value resourceMapper format.")
        wi = params.get("workflowInputs", {})
        if wi and "value" not in wi:
            flag(n["name"], n.get("id", ""), "EW_MISSING_VALUE_KEY",
                 "Execute Workflow workflowInputs exists but has no 'value' key. "
                 "Required shape: {mappingMode, value: {key: expr}, schema: [...]}")


# ──────────────────────────────────────────────
# Check 5 — queryReplacement string form with potential comma-splitting text
# ──────────────────────────────────────────────
def check_queryreplacement_form(nodes: list[dict]) -> None:
    for n in nodes:
        if "postgres" not in n.get("type", "").lower():
            continue
        params = n.get("parameters", {})
        qr = params.get("options", {}).get("queryReplacement", "")
        if not qr:
            continue
        # Array form is safe: starts with ={{ [
        if re.match(r"^\s*=\s*\{\{\s*\[", qr):
            continue
        # String form — check if it references anything that could contain commas
        dangerous_patterns = [
            r"\$json\.error",
            r"\.message",
            r"\.stack",
            r"messageBody",
            r"message_body",
            r"content",
            r"payload",
            r"summary",
            r"\$json\.[a-zA-Z]+body",
        ]
        for pat in dangerous_patterns:
            if re.search(pat, qr, re.IGNORECASE):
                flag(n["name"], n.get("id", ""), "QUERYREPLACEMENT_STRING_FORM",
                     f"queryReplacement is a string expression referencing potentially comma-containing "
                     f"data (matched: {pat}). Use array form: ={{{{ [v1, v2, ...] }}}} to prevent "
                     "parameter corruption from comma-splitting.")
                break


# ──────────────────────────────────────────────
# Check 6 — splitInBatches wiring (manual review flag)
# ──────────────────────────────────────────────
def check_splitinbatches_wiring(nodes: list[dict], connections: dict) -> None:
    for n in nodes:
        if "splitInBatches" not in n.get("type", ""):
            continue
        tv = n.get("typeVersion", 1)
        node_conns = connections.get(n["name"], {}).get("main", [])
        output0_targets = [c.get("node") for c in (node_conns[0] if len(node_conns) > 0 else [])]
        output1_targets = [c.get("node") for c in (node_conns[1] if len(node_conns) > 1 else [])]

        note = (f"splitInBatches typeVersion={tv}. "
                f"v3 semantics: output[0]=done (exit loop), output[1]=loop (process item). "
                f"output[0]→{output0_targets}, output[1]→{output1_targets}. "
                "Verify: output[0] exits to post-loop logic; output[1] enters loop body.")

        # Flag loop-back names on done branch as likely bug
        for target in output0_targets:
            if target and ("loop" in target.lower() or "back" in target.lower()):
                flag(n["name"], n.get("id", ""), "SPLITINBATCHES_DONE_LOOPS_BACK",
                     f"output[0] (done) routes to '{target}' — name suggests a loop-back. "
                     "In v3, output[0] fires when all batches are exhausted. "
                     "It should exit to post-loop logic, not loop back.")

        # Always emit an informational flag for manual review
        flag(n["name"], n.get("id", ""), "SPLITINBATCHES_REVIEW",
             note)


# ──────────────────────────────────────────────
# Check 7 — NOT NULL column coverage for audit/log tables
# ──────────────────────────────────────────────
def check_not_null_coverage(nodes: list[dict]) -> None:
    for n in nodes:
        if "postgres" not in n.get("type", "").lower():
            continue
        params = n.get("parameters", {})
        query = params.get("query", "")
        if not query or "INSERT" not in query.upper():
            continue
        query_upper = query.upper()
        for frag, table in TABLE_FRAGMENTS.items():
            # Use word-boundary match so 'event_log' does not match 'booking_event_log'
            if re.search(r'\b' + re.escape(frag.upper()) + r'\b', query_upper):
                required = REQUIRED_BINDINGS[table]
                missing = []
                for col in required:
                    # Check if the column name appears in the INSERT column list
                    # Simple heuristic: col name in the query string
                    if col not in query.lower():
                        missing.append(col)
                if missing:
                    flag(n["name"], n.get("id", ""), "MISSING_NOT_NULL_COLS",
                         f"INSERT into {table}: NOT NULL column(s) not found in query: "
                         f"{missing}. Bind all required columns.")


# ──────────────────────────────────────────────
# Check 8 — Redis GET nodes missing propertyName: "value"
# ──────────────────────────────────────────────
def check_redis_get_propertyname(nodes: list[dict]) -> None:
    for n in nodes:
        if "redis" not in n.get("type", "").lower():
            continue
        params = n.get("parameters", {})
        if params.get("operation") != "get":
            continue
        pn = params.get("propertyName", "")
        if pn != "value":
            flag(n["name"], n.get("id", ""), "REDIS_GET_PROPERTYNAME",
                 f"Redis Get node has propertyName='{pn}' (or missing). "
                 "Set propertyName='value' so downstream nodes can reference $json.value consistently.")


# ──────────────────────────────────────────────
# Check 9 — HTTP Request nodes missing timeout or retry config
# ──────────────────────────────────────────────
def check_http_request_config(nodes: list[dict]) -> None:
    for n in nodes:
        if n.get("type") != "n8n-nodes-base.httpRequest":
            continue
        params = n.get("parameters", {})
        options = params.get("options", {})
        # Check timeout
        if not options.get("timeout") and not params.get("timeout"):
            flag(n["name"], n.get("id", ""), "HTTP_MISSING_TIMEOUT",
                 "HTTP Request node has no explicit timeout. Set timeout in options (10000-30000ms).")
        # Check retry
        retry = options.get("retry", {})
        if not retry.get("maxTries") and not options.get("retryOnFail"):
            flag(n["name"], n.get("id", ""), "HTTP_MISSING_RETRY",
                 "HTTP Request node has no retry config. Add retry.maxTries=2 with exponential backoff.")


# ──────────────────────────────────────────────
# Check 10 — HTTP Request nodes with sendBody:true missing specifyBody:"json"
# Without specifyBody:"json", n8n typeVersion 4.x defaults to "keypair" and
# sends an empty body regardless of jsonBody content (Rule #31).
# ──────────────────────────────────────────────
def check_http_specify_body(nodes: list[dict]) -> None:
    for n in nodes:
        if n.get("type") != "n8n-nodes-base.httpRequest":
            continue
        params = n.get("parameters", {})
        if params.get("sendBody") and params.get("specifyBody") != "json":
            flag(n["name"], n.get("id", ""), "HTTP_MISSING_SPECIFY_BODY",
                 "HTTP Request node has sendBody:true but specifyBody is not 'json'. "
                 "n8n typeVersion 4.x defaults to 'keypair' format and sends an empty body, "
                 "ignoring jsonBody entirely. Add specifyBody:'json' to parameters (Rule #31).")


# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
def audit_file(path: str) -> int:
    global issues
    issues = []

    with open(path) as f:
        wf = json.load(f)

    nodes = wf.get("nodes", [])
    connections = wf.get("connections", {})
    node_names = {n["name"] for n in nodes}

    print(f"\n{'='*60}")
    print(f"Auditing: {path}")
    print(f"  Workflow: {wf.get('name', '(unnamed)')}")
    print(f"  Nodes: {len(nodes)}")
    print(f"{'='*60}\n")

    check_isempty_on_redis_output(nodes)
    check_alwaysoutputdata_location(nodes)
    check_set_node_typeversion(nodes)
    check_execute_workflow_format(nodes)
    check_queryreplacement_form(nodes)
    check_splitinbatches_wiring(nodes, connections)
    check_not_null_coverage(nodes)
    check_redis_get_propertyname(nodes)
    check_http_request_config(nodes)
    check_http_specify_body(nodes)

    # Deduplicate by (node, check) — keep first occurrence
    seen = set()
    deduped = []
    for issue in issues:
        key = (issue["node"], issue["check"])
        if key not in seen:
            seen.add(key)
            deduped.append(issue)

    # Separate actionable from informational
    info_checks = {"SPLITINBATCHES_REVIEW"}
    actionable = [i for i in deduped if i["check"] not in info_checks]
    informational = [i for i in deduped if i["check"] in info_checks]

    if actionable:
        print(f"ACTIONABLE ISSUES ({len(actionable)}):")
        for issue in actionable:
            print(f"\n  [{issue['check']}]")
            print(f"  Node: {issue['node']} (id: {issue['id']})")
            print(f"  Detail: {issue['detail']}")
    else:
        print("ACTIONABLE ISSUES: none")

    if informational:
        print(f"\nINFORMATIONAL / MANUAL REVIEW ({len(informational)}):")
        for issue in informational:
            print(f"\n  [{issue['check']}]")
            print(f"  Node: {issue['node']} (id: {issue['id']})")
            print(f"  Detail: {issue['detail']}")

    print(f"\n{'='*60}")
    if actionable:
        print(f"RESULT: FAIL — {len(actionable)} actionable issue(s) found.")
    else:
        print("RESULT: PASS — no actionable issues.")
    print(f"{'='*60}\n")

    return 1 if actionable else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <workflow.json> [...]")
        sys.exit(1)

    exit_code = 0
    for path in sys.argv[1:]:
        exit_code |= audit_file(path)

    sys.exit(exit_code)
