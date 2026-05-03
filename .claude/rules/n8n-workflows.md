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

18. **`queryReplacement` splits on commas — never pass values that can produce commas.** The Postgres node (typeVersion ≥ 2.5) evaluates each `{{ }}` block individually. For each result it calls `isJSON(result)`: if true (valid JSON object/array/string) it passes the value as-is; if false it calls `stringToArray(result)` which splits on `,`. Any non-JSON expression that evaluates to a string containing a comma (user message text, error messages, stack traces) will silently produce extra parameters and corrupt the query.

    **Rules:**
    - **Never use `JSON.stringify(obj)` with multi-key objects** in queryReplacement — the output `{"a":1,"b":2}` would pass `isJSON` in v2.5+ but is brittle; use a hand-crafted minimal string instead: `'{"node":"' + nodeName + '"}'` .
    - **For JSONB context columns**, write only what is needed: `'{"count":' + n + '}'` for a single numeric fact. Do not serialize full objects.
    - **For any TEXT column that can contain user-supplied or system-generated text** (message bodies, error messages, stack traces), use the **array form** which bypasses all comma-splitting:

    ```
    "queryReplacement": "={{ [val1, val2, val3] }}"
    ```

    When `queryReplacement` is a single expression that returns a JavaScript array, n8n routes it via `Array.isArray(queryReplacement) → values = queryReplacement` and each element is bound directly as a Postgres `$N` parameter with no splitting.

    - **Stack traces**: always truncate to first line (`error.stack?.split('\n')[0]`) — full traces have commas and are noisy in log tables. Use the array form regardless.

    **Surfaced 2026-04-30** during Workflow A live test — `Store Inbound Message` body and `Store Outbound Message` content both receive user/LLM text with commas, corrupting parameter counts. `Log DPA Error` full stack trace broke similarly.

19. **Execute Workflow nodes in n8n 2.x use `workflowInputs.value` (resourceMapper format), NOT `fields.values`.** In n8n typeVersion 1.3, the Execute Workflow node reads `workflowInputs.value` — a resourceMapper schema with `{mappingMode, value: {key: expr}, schema: [...]}`. The old `fields.values` key is silently ignored at runtime: the subflow receives no input data, and `$('Claude Call Trigger').first()?.json` is empty or only the bare trigger output. This affects every Execute Workflow node that passes parameters to a subflow.

    **Required shape:**
    ```json
    "workflowInputs": {
      "mappingMode": "defineBelow",
      "value": { "key1": "={{ expr }}", "key2": "={{ expr }}" },
      "schema": [ { "id": "key1", "displayName": "key1", "type": "string", ... }, ... ]
    }
    ```

    **Surfaced 2026-04-30 and 2026-05-01** during Workflow A live test — all 13 Execute Workflow nodes had `fields.values`; subflows received no parameters until converted.

20. **Set node `typeVersion` must be ≥ 3.3 for the `assignments` format to work.** `manual.mode.js` in n8n nodes-base branches on `node.typeVersion < 3.3`: the old path reads `fields.values` (legacy schema), the new path reads `assignments` (assignmentCollection schema). A Set node with `typeVersion: 3` and `assignments` in its parameters silently reads an empty `fields.values`, builds `newData = {}`, and returns the input item unchanged via `composeReturnItem`. This makes the node a transparent pass-through with no visible error.

    **Fix:** set `typeVersion: 3.4` (current n8n default) on every Set node that uses the `assignments` parameter format. Verify in exported JSON: `"typeVersion": 3` + `"assignments": {...}` = broken. `"typeVersion": 3.4` + `"assignments": {...}` = correct.

    **Surfaced 2026-05-01** — `Return Claude Response`, `Budget Exceeded — Return Empty`, `Return Empty Response` (claude-call.json), and `Set Candidate Context` (a-communications.json) all emitted `{success: true}` (the Postgres INSERT passthrough) until bumped to 3.4. Diagnosed via exec runData inspection + reading `manual.mode.js` source in the container.

21. **`patch-workflow-ids.sh` uses explicit node-name → subflow mapping, NOT keyword matching.** Any keyword-based matching scheme will misroute nodes whose names contain a word from another subflow's keyword list (e.g. "Generate Reply" contains 'reply' — a WA Send keyword). The script at `scripts/patch-workflow-ids.sh` maintains an explicit `NODE_TO_SUBFLOW` dict. When adding new Execute Workflow nodes to any workflow, add the exact node name → subflow ID mapping to that dict. Nodes not in the dict print a warning to stderr and are NOT patched — verify the warning output after every patch run.

    **Surfaced 2026-04-30** — "Generate Reply — Claude Sonnet" was patched to the WA Send subflow ID because 'reply' matched the WA Send keyword list; Claude Call received its own previous ID (stale), causing silent wrong-subflow routing.

22. **Read source data directly from the node that produced it — never rely on Set Candidate Context as an intermediary for downstream expressions.** In n8n 2.x, a Set node that silently fails (see Rule #20) or that runs in a different branch produces stale or absent data when referenced from a downstream node via `$('Set Candidate Context').first()?.json.*`. Use the authoritative source node instead:
    - `phoneE164` → `$('Normalise Phone Number').first()?.json?.phoneE164`
    - `candidateId` / `consentStatus` → `$('Resolve Candidate by Phone').first()?.json?.data?.candidates?.edges?.[0]?.node?.id` (or `.consentStatus`)
    - `messageBody` → `$('Normalise Phone Number').first()?.json?.messageBody`

    **How to apply:** audit every expression referencing `$('Set Candidate Context')` and replace with the direct source. Set nodes are fine for building payloads to send downstream (e.g. to a subflow), but they are an unreliable re-reference target in a long execution chain.

    **Surfaced 2026-05-01** as a consequence of the Set node typeVersion bug — Set Candidate Context was a transparent pass-through whose outputs were used by multiple downstream nodes.

23. **`consentStatus` must be read from the candidate query result node, not from any Set node.** IF/Switch nodes that gate the consent flow should reference `$('Resolve Candidate by Phone').first()?.json?.data?.candidates?.edges?.[0]?.node?.consentStatus` directly. Routing errors (e.g. always routing to PENDING when status is GRANTED) are the failure mode when the reference resolves to `null` or `undefined`, because loose-mode IF nodes treat those as falsy and fall through to the wrong branch.

    **Surfaced 2026-05-01** — consent flow was routing GRANTED candidates to PENDING branch until `Is Consent Granted?` IF node was updated to read from the GraphQL result node directly.

24. **`alwaysOutputData: true` on Postgres executeQuery nodes must be at the NODE ROOT LEVEL, not inside `parameters.options`.** Any Postgres node that may return zero rows (e.g. a poll that finds no work, a lookup that finds no match) will halt the execution chain if it emits no items. Setting `alwaysOutputData` inside `parameters.options` has no effect — n8n reads it only from the node's top-level JSON object.

    **Correct JSON shape:**
    ```json
    {
      "name": "Claim Inbox Row",
      "type": "n8n-nodes-base.postgres",
      "alwaysOutputData": true,
      "parameters": { ... }
    }
    ```

    **Wrong (silently ignored):**
    ```json
    {
      "name": "Claim Inbox Row",
      "type": "n8n-nodes-base.postgres",
      "parameters": {
        "options": { "alwaysOutputData": true }
      }
    }
    ```

    **Surfaced 2026-05-01** during Workflow B v1 live test — `Claim Inbox Row` (FOR UPDATE SKIP LOCKED) returned zero rows on an empty inbox and halted the execution instead of flowing to the `Row Claimed?` IF node's false branch.

25. **Add every new workflow file that references subflow IDs to `scripts/patch-workflow-ids.sh`'s file list.** The patch script only processes the files explicitly listed in its Python heredoc. A workflow file that is not in the list will retain stale subflow IDs after reimport, causing `"Workflow does not exist"` errors at runtime whenever a subflow is reimported and its ID changes.

    **When adding a new workflow that calls Execute Workflow nodes:** add the file path to the `for filepath in [...]` list in `patch-workflow-ids.sh` AND add each Execute Workflow node name → subflow ID mapping to the `NODE_TO_SUBFLOW` dict (rule #21).

    **Surfaced 2026-05-01** — `b-screening.json` was not in the patch script's file list after initial build; `Extract Structured Facts — Claude Sonnet` and `Score Against Rubric — Claude Sonnet` retained stale Claude Call subflow IDs after wa-send was reimported, causing `"Workflow does not exist"` on the first happy-path test run.

27. **HTTP Request nodes that have a designed failure branch MUST have `"onError": "continueErrorOutput"` at the node root level.** Without it, credential errors and HTTP 500s bypass the designed branch entirely and throw directly to the Error Trigger, leaving the failure path dead. Setting `continueRegularOutput` or omitting the field has the same effect: only 2xx responses follow the main output; all errors short-circuit to the global error handler.

    **Correct shape:**
    ```json
    {
      "name": "Create Google Calendar Event",
      "type": "n8n-nodes-base.httpRequest",
      "onError": "continueErrorOutput",
      "parameters": { ... }
    }
    ```

    The error output (`main[1]`) must also have a connection in the `connections` object — setting `onError` without wiring `branch[1]` leaves the error items with nowhere to go and produces a silent no-op.

    **Surfaced 2026-05-02** during Workflow D build — `Create Google Calendar Event` had `onError: continueErrorOutput` but `connections.main` only had `[0]` wired to `Calendar Created?`. The `[1]` error branch was unwired; Google credential errors bypassed `Calendar Created?` entirely and threw to the Error Trigger.

28. **When `alwaysOutputData: true` is set on a Postgres `executeQuery` node, downstream IF nodes checking for results MUST test field existence (`$json.id ?? '' !== ''`), NOT `$items().length > 0`.** When the query returns zero rows, `alwaysOutputData: true` emits one empty item `{}` with no fields. `$items().length` sees 1 item and evaluates to `true`, routing every zero-row result as if data was found. The correct check tests for the presence of a specific field from the expected row (e.g. `id`, `status`, `candidate_id`).

    **Correct IF condition:**
    ```
    leftValue:  {{ $json.id ?? '' }}
    operator:   string / notEmpty
    ```

    **Wrong (always true on zero-row):**
    ```
    leftValue:  {{ $items().length > 0 }}
    operator:   boolean / equal / true
    ```

    **Surfaced 2026-05-02** during Workflow D build — `Got Offered Slots?` used the length-check form; zero-row slot queries (candidates with no offered slots) routed into the "has slots" branch instead of the "no slots" exit.

29. **When a workflow uses external API credentials via `$env.*`, verify those vars are present in the n8n container env block in `docker-compose.yml` — not just in `.env`.** Variables in `.env` are consumed by Docker Compose for its own substitution (e.g. `${META_PAGE_ID}` in the compose file becomes the service env var). A var in `.env` that is NOT referenced in the n8n service `environment:` block is invisible inside the container. `$env.META_PAGE_ID` in an n8n expression will resolve to `undefined` at runtime, causing silent API call failures with no import-time error or n8n validation warning.

    **Pre-import checklist:** for every `$env.SOME_VAR` expression in the workflow JSON, confirm the n8n service `environment:` block in `infrastructure/docker-compose.yml` has a line `SOME_VAR: ${SOME_VAR}`. If missing, add it and recreate the container (`docker compose up -d --force-recreate n8n`) before the first live test.

    **Already mapped (as of 2026-05-03):** `TWENTY_API_URL`, `TWENTY_API_KEY`, `GROQ_API_KEY`, `ANTHROPIC_API_KEY`, `WHATSAPP_*` (5 vars), `META_PAGE_ID`, `META_PAGE_ACCESS_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHANNEL_ID`, `N8N_BLOCK_ENV_ACCESS_IN_NODE`, `NODE_FUNCTION_ALLOW_BUILTIN`.

    **Surfaced 2026-05-03** during Workflow E live test — `META_PAGE_ID`, `META_PAGE_ACCESS_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHANNEL_ID` were in `.env` but absent from the n8n service env block. FB URL evaluated to `…/undefined/feed`; Telegram URL to `…/botundefined/sendMessage`. Both publish nodes failed silently until the vars were added and the container recreated.

30. **Never use GraphQL named variable references (`$varName`) inside n8n expression strings.** In an n8n expression like `={{ { query: 'query Foo($status: Enum!) { ... }', variables: { status: $json.val } } }}`, the `$status` inside the single-quoted GQL string is treated by n8n's expression engine as a variable reference (`$status` → undefined), not a literal GQL variable declaration. The resulting HTTP body is either `{"": ...}` (key becomes empty string) or malformed JSON, causing Twenty 400 errors.

    **Fix:** Inline all values directly via string concatenation. Remove named GQL variable declarations entirely:
    ```
    // Wrong — $windowStart is treated as n8n var reference:
    { query: 'query Foo($windowStart: DateTime!) { ... filter: { gte: $windowStart } }', variables: { windowStart: $json.windowStart } }
    
    // Correct — inline value via string concat:
    { query: '{ jobPostings(filter: { postedAt: { gte: \"' + $json.windowStart + '\" } }) { edges { node { id } } } }' }
    ```

    This applies to any `$` followed by an identifier inside a single- or double-quoted string within an n8n `={{ }}` expression. The `variables` object field is safe only if none of the GQL query string's own `$varName` tokens are present.

    **Surfaced 2026-05-03** during Workflow H tester round 1 — `Query New Open JobPostings` and `Query Expired Offers` both sent `{"": null}` to Twenty because `$windowStart`, `$status`, `$cutoff` were parsed as n8n variables (all undefined).

## Before committing an n8n workflow

Run the validator:

```
./scripts/validate-n8n-workflow.sh n8n-workflows/<path>.json
```

If it fails, fix in the n8n UI and re-export. Do not hand-edit to bypass.
