---
name: validate-n8n-workflow
description: Validate an exported n8n workflow JSON against project conventions before committing. Catches missing error branches, hardcoded secrets, missing lock patterns.
---

# /validate-n8n-workflow

## When to use

After exporting a workflow from the n8n UI and before committing its JSON to `n8n-workflows/`.

## What it checks

The skill runs `scripts/validate-n8n-workflow.sh <path>` which does:

1. **Parse validity.** JSON must parse.
2. **Credential leak check.** Searches for anything that looks like a real API key, access token, password, or AWS credential. Fails if any found.
3. **Error branch presence.** Every workflow must have at least one node connecting to an errorTrigger or equivalent path.
4. **Redis lock pattern.** If the workflow references the conversation-lock Redis keys (`conv:`), verify acquire + heartbeat + release nodes are all present.
5. **DB writes have corresponding error handling.** Every Postgres node's "on error" is not set to "continue on fail" without an explicit error branch downstream.
6. **Node naming.** Node names are human-readable, not `HTTP Request 1`, `Function 3`. At most 10% of nodes can have default names.
7. **Environment variables.** No literal URLs like `https://graph.facebook.com/...` outside an expression that references `{{$env.META_...}}`. URLs come from env.
8. **Timeout config.** Every HTTP Request node has an explicit timeout set.

## Usage

```
/validate-n8n-workflow n8n-workflows/communications/a1-whatsapp-inbound.json
```

## Output

PASS → the workflow meets conventions.
FAIL → list of specific issues, each with the JSON path where it occurs.

## Do not bypass

If validation fails, fix the workflow in the n8n UI and re-export. Do not edit the JSON by hand to trick the validator — you will miss something a UI edit would catch.
