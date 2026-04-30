# Rule — when touching `n8n-workflows/`

Load this rule when reading or editing any file under `n8n-workflows/`.

## Conventions this project enforces in n8n workflows

1. **Every workflow has a top-level Error Trigger** that writes to the bookings DB `workflow_errors` table with: workflow name, execution ID, node name, error message, error stack, and the input data that triggered it.

2. **Every HTTP Request node has:**
   - Explicit timeout (10–30s depending on the endpoint).
   - Retry config: 2 retries with exponential backoff, only on 5xx and 429.
   - On-error behaviour: branch to the error handler, not "continue on fail".

3. **Every Postgres node** uses n8n's credential system. Never inline connection strings.

4. **Redis lock pattern (when used):**
   - Acquire: `SET hra:conv:{candidateId} {executionId} NX PX 60000`. Branch on failure → enqueue retry.
   - Heartbeat: Lua `PEXPIRE` CAS, scheduled every 15s while the workflow is holding the lock.
   - Release: Lua `DEL` CAS, run in both the success path and the error path.
   - Key prefix `hra:conv:` per [ADR-0009](../../docs/05-decisions/ADR-0009-redis-namespace-strategy.md).

5. **Dedupe on inbound webhooks:**
   - First node after the Webhook is a Redis SETNX on `hra:dedupe:{external_event_id}` with 24h TTL.
   - If key already exists → return 200 and exit.
   - Key prefix `hra:dedupe:` per [ADR-0009](../../docs/05-decisions/ADR-0009-redis-namespace-strategy.md).

6. **Claude calls** go through a subflow (reusable node group), not ad-hoc HTTP Request nodes. The subflow handles model routing, budget gating, and `ai_call_log` writes.

7. **Outbound WhatsApp sends** also go through a subflow that enforces the 24h service window and falls back to a template if free-form fails with error code 131047.

8. **Node naming:** human-readable, describes the action. "Fetch Candidate by Phone" ✓, "HTTP Request 4" ✗.

9. **Workflow tags:** every workflow carries tags `hr-automation`, its letter (`workflow-a` through `workflow-h`), and `version-Nmm` as a pointer to the spec version. Tags are a weak form of version linkage but help when debugging.

10. **Credentials in JSON exports:** NEVER committed. The export process in `n8n-workflows/README.md` uses n8n's export-without-credentials option; if the JSON contains a credential field with a non-empty value, the pre-commit hook blocks the commit.

11. **`ReviewTask.subject` polymorphic invariant.** `ReviewTask` uses two optional `MANY_TO_ONE` fields — `subjectCandidate` and `subjectApplication` — instead of a single MORPH_RELATION (see ADR-0005). On every write path that creates or updates a `ReviewTask`, the workflow MUST assert exactly one of those two fields is set: never both, never neither. The DB does not enforce this; n8n is the only line of defence. Read paths must defensively check both fields and treat "neither set" or "both set" as a data-integrity error → log to `workflow_errors` and skip.

12. **Code nodes: stdlib access is gated by `NODE_FUNCTION_ALLOW_BUILTIN`.** n8n's Code node runs in a sandbox that BY DEFAULT blocks `require()` of Node.js stdlib modules. To enable a module, add it to the comma-separated env var on the n8n service:
    
    ```yaml
    NODE_FUNCTION_ALLOW_BUILTIN: "crypto,url,querystring"   # explicit allowlist
    NODE_FUNCTION_ALLOW_BUILTIN: "*"                          # permit all (broader attack surface)
    ```
    
    Currently set on this project: `crypto` (for HMAC validation in webhook handlers). Adding more modules: edit `infrastructure/docker-compose.yml` n8n service env, recreate the container.
    
    **What's available WITHOUT allowlisting:**
    - `Buffer` — Node.js default global (e.g. `Buffer.from(...)`, no require)
    - `JSON`, `Math`, `Date`, regex, `URL`, `URLSearchParams` — standard JS globals
    - `process.env` — NOT directly accessible; use `$env.VAR_NAME` (n8n's expression sugar) instead
    - n8n-specific: `$input`, `$json`, `$env`, `$execution`, `$workflow`, `$node`
    
    **What needs allowlisting + require():**
    - `crypto` — HMAC, hashing, sign/verify, randomBytes
    - `buffer` — only the buffer module's named exports beyond the global Buffer (rarely needed)
    - `url`, `querystring`, `path`, `os`, `util` — standard stdlib
    
    Third-party npm packages need `NODE_FUNCTION_ALLOW_EXTERNAL` (different env var) AND the package available in the n8n container's node_modules (usually requires a custom Dockerfile or a volume mount). Non-trivial; needs an architect ADR before adoption. For Workflow A through H, prefer Postgres functions or subflows over Code-node-with-external-deps.
    
    **Surfaced 2026-04-28** during Phase 4 voucher work — initial guess that `crypto` was a sandbox global (it isn't); WhatsApp webhook handler's HMAC validator threw "crypto is not defined" until the env var was set.

13. **Postgres nodes writing to project audit/log tables MUST bind every NOT NULL column from the destination table's V-migration.** Cross-check against the migration file BEFORE generation, not after. n8n's Test Setup against a malformed Postgres INSERT trips the NOT NULL constraint at the DB and produces a confusing failure mode (the node "succeeds" through query construction but the DB rejects).
    
    Common runtime-supplied bindings:
    - `$execution.id` — n8n's expression for current execution ID. Works in normal-flow nodes.
    - `$json.execution.id` — Error Trigger downstream. The execution context here is the FAILED execution surfaced via `$json` from the Error Trigger output, NOT the current Error Trigger execution.
    - `$workflow.name`, `$workflow.id` — workflow metadata as expression variables.
    - `NOW()` or column DEFAULT — let the DB fill timestamps; don't synthesise client-side.
    
    Cross-cut against the project schema:
    - **`workflow_errors`** NOT NULL: `workflow_name`, `execution_id`, `error_message`. (V001)
    - **`event_log`** NOT NULL: `workflow_name`, `level`, `event`. (V001) `execution_id` is nullable but bind it anyway for traceability.
    - **`system_incident`** NOT NULL: `kind`, `severity` (CHECK ∈ info/warning/critical), `summary`. (V001)
    - **`twenty_schema_migrations`** NOT NULL: `version`, `description`, `operations_count`, `applied_by`, `applied_against`. (V004) — apply-script-owned, not workflow-touched.
    - **`ai_call_log`** NOT NULL: `workflow_name`, `model`. (V005)
    
    **Surfaced 2026-04-28** by an INSERT into workflow_errors omitting execution_id — n8n's Test Setup tripped the NOT NULL constraint; row 27 in workflow_errors is the artefact.

14. **All Redis keys written by HRA app code MUST use the `hra:` prefix.** Flat `hra:<kind>:<id>` shape (e.g. `hra:conv:{candidateId}`, `hra:dedupe:{external_event_id}`). The shared `hr-redis` instance is also used by Twenty (`bull:` for BullMQ queues, `engine:` for workspace cache, `module:` for workflow scheduler partitions); the `hra:` prefix is the namespace boundary that prevents collision today and stays stable across future Twenty version bumps. The Phase 5 conv-lock test (`scripts/test-conv-lock.sh`) uses a test-scoped prefix (`test:lock:conv-test:$$`) and is exempt. See [ADR-0009](../../docs/05-decisions/ADR-0009-redis-namespace-strategy.md) for the full evidence trail (cited Twenty source files + observed Redis key counts).

15. **Conv-lock token must be `$execution.id` alone — not `$execution.id + ':' + random`.** The execution ID is globally unique per n8n execution. Random suffixes create token-tracking inconsistencies when the same token must be passed to the acquire node, the `event_log` write, and all CAS DEL release nodes. The Phase 5 conv-lock test used `uuidgen` to simulate two competing processes — that's the only scenario where distinct random tokens per-locker matter. Within a single n8n execution, use the execution ID only.

16. **n8n 1.85.0 Redis node does NOT support `executeCommand`.** Available operations: Delete, Get, Increment, Info, Keys, Pop, Publish, Push, Set. The Set operation supports Expire (TTL in seconds) but has **no NX flag**.

    **Use two-step patterns instead:**
    - **SETNX behaviour (dedupe, lock acquire):** Redis Get → If (value empty) → Redis Set with Expire. TOCTOU race window exists but is acceptable at v1 volume.
    - **CAS DEL behaviour (lock release):** Redis Get → If (value === expected token) → Redis Delete. Same TOCTOU caveat.
    
    **Redis Get output:** The Get operation stores the result in a property named by the node's `propertyName` parameter (default: `"propertyName"`, producing `$json.propertyName`). Always set `propertyName: "value"` explicitly on every Redis Get node so downstream If nodes can use `$json.value ?? ''`. Key not found → `$json.value` is `null`.
    
    **Redis Set parameters:** `key`, `value`, `expire` (boolean), `ttl` (seconds when expire is true).
    
    Both patterns have TOCTOU races — document as known v1 limitations in the workflow NOTES file and add T2 items for the atomic upgrade path. T2-18 (acquire) and T2-19 (release) are the current tracking items for Workflow A.
    
    **Surfaced 2026-04-30** during Workflow A live test — all 14 `executeCommand` Redis nodes had to be replaced post-commit.

17. **n8n 2.x blocks `$env.*` access in expressions by default.** The n8n service must have `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` set in `infrastructure/docker-compose.yml` to allow env var access in expressions. All workflows that read API keys via `$env.ANTHROPIC_API_KEY`, `$env.WHATSAPP_TOKEN`, `$env.GROQ_API_KEY`, etc. depend on this setting. Without it, every expression referencing `$env.*` silently resolves to `undefined` at runtime, causing silent API call failures. Set once on the container; no per-workflow change needed.

    **Surfaced 2026-04-30** during n8n 2.18.5 live test re-import — claude-call.json HTTP Request headers evaluated `$env.ANTHROPIC_API_KEY` to `undefined`.

## Before committing an n8n workflow

Run the validator:

```
./scripts/validate-n8n-workflow.sh n8n-workflows/<path>.json
```

If it fails, fix in the n8n UI and re-export. Do not hand-edit to bypass.
