# HR Automation — Lessons Learned

**Date closed:** 2026-05-03  
**Scope:** Weeks 0–1, Workflows A–H v1, ADRs 0001–0012  
**Every claim below is traceable to a file, commit, or ADR in this repository.**

---

## Part 1 — Stack & Version Pinning

### Component versions (pinned in `infrastructure/docker-compose.yml`)

| Component | Pinned version | Why pinned |
|---|---|---|
| Twenty CRM | `twentycrm/twenty:v2.1.0` | v0.60 does not exist on Docker Hub; v2.1.0 is current stable at time of bring-up (ADR-0005, 2026-04-26) |
| n8n | `n8nio/n8n:2.18.5` | The version running when the project was first deployed; **many** node type-version defaults changed between 1.x and 2.x — pinning prevents silent regressions on the next `docker pull` |
| Postgres (two instances) | `postgres:16` | 16 was the LTS release available at time of first bring-up (V001 applied 2026-04-26) |
| Redis | `redis:7-alpine` | 7.x LTS; `--appendonly no --save ""` (no persistence — ephemeral lock/dedupe state by design per ADR-0009) |
| Nginx | `nginx:stable-alpine` | stable channel, not mainline, for production proxy |

**Rule:** Never use `:latest` in production deployments — this is explicitly noted in `infrastructure/docker-compose.yml` line 2.

### What changed between n8n 1.85.0 and 2.18.5

The Phase 4 bring-up used n8n 1.85.0. When the project was re-imported against 2.18.5 during Workflow A live testing (2026-04-30), five compatibility categories of breakage emerged simultaneously. Each became a numbered rule in `.claude/rules/n8n-workflows.md`:

1. **Execute Workflow node schema changed.** Rule #19 — `fields.values` silently ignored; new format is `workflowInputs.value` (resourceMapper). All 13 Execute Workflow nodes in `a-communications.json` had to be converted.
2. **Set node typeVersion semantics split at 3.3.** Rule #20 — typeVersion 3 reads `fields.values` (legacy); `assignments` format only works with typeVersion ≥ 3.3. Silent transparent pass-through is the failure mode: node emits `{}` with no error.
3. **`$env.*` access blocked by default.** Rule #17 — `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` is required in the n8n service env to restore expression-level access to `$env.VAR`.
4. **Redis node no longer has `executeCommand`.** Rule #16 — all 14 Lua/SETNX Redis nodes had to be replaced with two-step GET+IF+SET/DELETE patterns.
5. **`queryReplacement` comma-splitting on user text.** Rule #18 — Postgres node evaluates each `{{ }}` block and calls `stringToArray()` on non-JSON results, splitting on commas. Array form `={{ [v1, v2] }}` bypasses this.

---

## Part 2 — n8n 2.x Rules

Each rule below corresponds to a numbered rule in `.claude/rules/n8n-workflows.md`. The SYMPTOM is what you observe when you violate it. The DISCOVERY is the date and context from the rule's "Surfaced" note.

**Rule 1 — Error Trigger writes to `workflow_errors`.**  
Every workflow has a top-level Error Trigger node that inserts into `workflow_errors` with `workflow_name`, `execution_id`, `node_name`, `error_message`, `error_stack`, and input context.  
SYMPTOM: unhandled errors disappear silently with no audit trail.  
DISCOVERY: built-in from initial scaffold; V001 schema, 2026-04-24.

**Rule 2 — HTTP Request node: explicit timeout + retry + onError behaviour.**  
10–30s timeout; 2 retries with exponential backoff on 5xx/429 only; `onError` must be set explicitly.  
SYMPTOM: slow endpoints cause execution hangs; transient failures are not retried; errors that should branch instead throw to the Error Trigger.

**Rule 3 — Postgres nodes use n8n credential system.**  
Never inline connection strings.  
SYMPTOM: credentials in exported JSON would trigger the pre-commit hook block.

**Rule 4 — Redis lock pattern.**  
Acquire: `SET hra:conv:{candidateId} {executionId} NX PX 60000`. Release: Lua CAS DEL on all exit paths. Key prefix `hra:conv:` per ADR-0009. v1 deviation: 180s flat TTL (no heartbeat) — see NOTES file §1 and T2-12.

**Rule 5 — Dedupe on inbound webhooks.**  
First node after webhook: Redis SETNX on `hra:dedupe:{external_event_id}` with 24h TTL. If key exists: return 200 and exit.

**Rule 6 — Claude calls through subflow.**  
`claude-call.json` handles model routing, budget gating, `ai_call_log` writes. No ad-hoc HTTP Request to Anthropic.

**Rule 7 — Outbound WhatsApp through subflow.**  
`wa-send.json` enforces the 24h service window and falls back to a template on error 131047 (out-of-window).

**Rule 8 — Human-readable node naming.**  
"Fetch Candidate by Phone" ✓, "HTTP Request 4" ✗.

**Rule 9 — Workflow tags.**  
Every workflow carries `hr-automation`, its letter (`workflow-a` etc.), and `version-Nmm`.

**Rule 10 — No credentials in exported JSON.**  
Pre-commit hook blocks any JSON export that contains a non-empty credential value.

**Rule 11 — `ReviewTask.subject` polymorphic invariant.**  
Exactly one of `subjectCandidate` or `subjectApplication` must be set — never both, never neither. The DB does not enforce this; n8n is the only gatekeeper.  
SYMPTOM: ReviewTask created with `subjectCandidate.id = ''` (T2-13 edge case).

**Rule 12 — Code nodes: `NODE_FUNCTION_ALLOW_BUILTIN` required for stdlib.**  
Default sandbox blocks `require()` of all Node.js stdlib. `crypto` is currently allowlisted for HMAC validation. `Buffer`, `JSON`, `Math`, `Date`, `URL`, `URLSearchParams` are available without allowlisting.  
SYMPTOM: `crypto is not defined` in the webhook HMAC validator.  
DISCOVERY: 2026-04-28 during Phase 4 voucher work.

**Rule 13 — Postgres NOT NULL columns must all be bound before INSERT.**  
Cross-check the destination table's V-migration before writing a Postgres node. In the Error Trigger downstream, use `$json.execution.id` (the FAILED execution), not `$execution.id`.  
SYMPTOM: n8n Test Setup "succeeds" through query construction then the DB rejects with a NOT NULL constraint violation; row 27 in `workflow_errors` is the artifact.  
DISCOVERY: 2026-04-28.

NOT NULL columns by table (from V001, V005):
- `workflow_errors`: `workflow_name`, `execution_id`, `error_message`
- `event_log`: `workflow_name`, `level`, `event`
- `system_incident`: `kind`, `severity` (CHECK ∈ info/warning/critical), `summary`
- `ai_call_log`: `workflow_name`, `model`

**Rule 14 — All Redis keys use `hra:` prefix.**  
Flat shape: `hra:<kind>:<id>`. The shared `hr-redis` is also used by Twenty: `bull:*` (BullMQ), `engine:*` (workspace cache), `module:*` (workflow scheduler). Source-verified in ADR-0009.  
SYMPTOM: future key collisions with Twenty's namespaces; un-namespaced keys in a shared Redis are silent corruption vectors.

**Rule 15 — Conv-lock token is `$execution.id` only.**  
Do not append random suffixes. Random tokens break the Get→Check→Delete CAS release chain when the same token must match across multiple release nodes.  
DISCOVERY: T2-18/T2-19 analysis and Phase 5 conv-lock test.

**Rule 16 — n8n 1.85.0 Redis node has no `executeCommand` or NX flag.**  
Available operations: Delete, Get, Increment, Info, Keys, Pop, Publish, Push, Set.  
SETNX behaviour: Redis Get → If (value empty) → Redis Set with Expire.  
CAS DEL behaviour: Redis Get → If (value === token) → Redis Delete.  
Always set `propertyName: "value"` on every Redis Get node (`$json.value ?? ''`).  
SYMPTOM: all 14 `executeCommand` nodes threw at runtime.  
DISCOVERY: 2026-04-30 during Workflow A live test.

**Rule 17 — n8n 2.x blocks `$env.*` by default.**  
Set `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` in the n8n service environment block.  
SYMPTOM: `$env.ANTHROPIC_API_KEY` silently evaluates to `undefined`; all Claude API calls fail silently.  
DISCOVERY: 2026-04-30 during n8n 2.18.5 re-import.

**Rule 18 — `queryReplacement` comma-splitting.**  
Non-JSON strings containing commas (user text, error messages, stack traces) are split on commas by `stringToArray()`. Use array form `={{ [v1, v2, v3] }}` for any TEXT column that can hold user-supplied or system-generated content. Truncate stack traces to first line (`error.stack?.split('\n')[0]`).  
SYMPTOM: `Store Inbound Message` body and `Store Outbound Message` content with commas corrupted parameter counts; `Log DPA Error` full stack trace broke similarly.  
DISCOVERY: 2026-04-30 during Workflow A live test.

**Rule 19 — Execute Workflow nodes use `workflowInputs.value` (resourceMapper), NOT `fields.values`.**  
Required shape:
```json
"workflowInputs": {
  "mappingMode": "defineBelow",
  "value": { "key1": "={{ expr }}" },
  "schema": [ { "id": "key1", "displayName": "key1", "type": "string" } ]
}
```
SYMPTOM: subflow receives no input data; `$('Claude Call Trigger').first()?.json` is empty.  
DISCOVERY: 2026-04-30 and 2026-05-01; all 13 Execute Workflow nodes in `a-communications.json` had `fields.values`.

**Rule 20 — Set node `typeVersion` must be ≥ 3.3 for `assignments` format.**  
`typeVersion: 3` with `assignments` parameters silently builds `newData = {}` via `composeReturnItem` (source: `manual.mode.js` in n8n nodes-base). Node becomes a transparent pass-through.  
SYMPTOM: `Return Claude Response`, `Budget Exceeded — Return Empty`, `Return Empty Response`, `Set Candidate Context` all emitted `{success: true}` (the Postgres INSERT passthrough) until bumped to `typeVersion: 3.4`.  
DISCOVERY: 2026-05-01; diagnosed via exec runData inspection and reading `manual.mode.js` source in the container.

**Rule 21 — `patch-workflow-ids.sh` uses explicit node-name → subflow mapping.**  
Keyword-based matching misroutes nodes whose names contain words from another subflow's keyword list.  
SYMPTOM: "Generate Reply — Claude Sonnet" was patched to the WA Send subflow ID because 'reply' matched the WA Send keyword list.  
DISCOVERY: 2026-04-30.

**Rule 22 — Read source data from the producing node; never rely on a Set node as an intermediary.**  
Authoritative sources:
- `phoneE164` → `$('Normalise Phone Number').first()?.json?.phoneE164`
- `candidateId` → `$('Resolve Candidate by Phone').first()?.json?.data?.candidates?.edges?.[0]?.node?.id`
- `messageBody` → `$('Normalise Phone Number').first()?.json?.messageBody`

SYMPTOM: Set Candidate Context was a transparent pass-through (Rule #20 bug); all downstream expressions reading from it got empty values.  
DISCOVERY: 2026-05-01 as a consequence of the Set node typeVersion bug.

**Rule 23 — `consentStatus` must be read from the GraphQL result node.**  
IF/Switch nodes gating consent flow must reference `$('Resolve Candidate by Phone').first()?.json?.data?.candidates?.edges?.[0]?.node?.consentStatus` directly.  
SYMPTOM: consent flow routed GRANTED candidates to the PENDING branch — `null` or `undefined` is falsy in loose-mode IF nodes.  
DISCOVERY: 2026-05-01.

**Rule 24 — `alwaysOutputData: true` at node ROOT LEVEL, not inside `parameters.options`.**  
Placing it inside `parameters.options` has no effect. Correct shape: `{ "name": "...", "alwaysOutputData": true, "parameters": {...} }`.  
SYMPTOM: `Claim Inbox Row` returned zero rows on an empty inbox and halted execution instead of flowing to the `Row Claimed?` IF node false branch.  
DISCOVERY: 2026-05-01 during Workflow B v1 live test.

**Rule 25 — Add every new workflow file to `patch-workflow-ids.sh`'s file list.**  
SYMPTOM: `b-screening.json` retained stale Claude Call subflow IDs after wa-send was reimported; `"Workflow does not exist"` at runtime.  
DISCOVERY: 2026-05-01.

**Rule 27 — HTTP Request nodes with a designed failure branch must have `"onError": "continueErrorOutput"` at root level AND the error output (`main[1]`) wired in `connections`.**  
SYMPTOM: `Create Google Calendar Event` had `onError: continueErrorOutput` set but `connections.main` only had `[0]` wired; Google credential errors threw to the Error Trigger instead of the Calendar failure branch.  
DISCOVERY: 2026-05-02 during Workflow D build.

**Rule 28 — When `alwaysOutputData: true`, IF nodes check field existence, not `$items().length`.**  
Zero-row result emits one empty item `{}`. `$items().length` sees 1 and evaluates true. Correct: `{{ $json.id ?? '' }}` with `string / notEmpty` operator.  
SYMPTOM: zero-row slot queries routed into the "has slots" branch instead of the "no slots" exit.  
DISCOVERY: 2026-05-02 during Workflow D build.

**Rule 29 — `$env.*` vars must be present in the n8n service `environment:` block in `docker-compose.yml`, not just in `.env`.**  
`.env` is consumed by Docker Compose for its own variable substitution. A var in `.env` not referenced in the n8n service `environment:` block is invisible inside the container.  
SYMPTOM: FB URL evaluated to `.../undefined/feed`; Telegram URL to `.../botundefined/sendMessage`.  
DISCOVERY: 2026-05-03 during Workflow E live test.

**Rule 30 — Never use GraphQL named variable references (`$varName`) inside n8n expression strings.**  
n8n's expression engine parses `$status` inside a quoted GQL string as an n8n variable reference (undefined), not a GQL variable declaration.  
SYMPTOM: `Query New Open JobPostings` and `Query Expired Offers` both sent `{"": null}` to Twenty.  
FIX: Inline all values via string concatenation; remove GQL `variables:` entirely.  
DISCOVERY: 2026-05-03 during Workflow H tester round 1.

**Rule 31 — HTTP Request nodes with `sendBody: true` must have `specifyBody: "json"` explicitly.**  
Without it, node defaults to `"keypair"` format; `jsonBody` expression is never evaluated; POST body is `{}`.  
SYMPTOM: all 5 HTTP nodes in Workflow H sent empty bodies to Twenty; HTTP 400 on every execution; `continueRegularOutput` masked failures as zero-item results.  
DISCOVERY: 2026-05-03 during Workflow H tester round 2.

**Rule 32 — Cross-node `$('NodeName')` references fail silently inside SplitInBatches loop bodies.**  
The expression evaluator cannot resolve references to nodes outside the current loop context. The expression fails with `{error: "invalid syntax"}`, swallowed silently.  
FIX: Insert a Set node (typeVersion 3.4) before the SplitInBatches node that bakes cross-loop values into `$json.fieldName`. Inside the loop, reference `$json.fieldName`.  
SYMPTOM: `Query Eligible Applications` inside SplitInBatches returned `{error: "invalid syntax"}` on every execution; `Filter Candidates` received empty data; no candidate was ever processed.  
DISCOVERY: 2026-05-03 during Workflow H tester round 4.

**Rule 33 — Twenty GraphQL mutations always return HTTP 200 even on failure.**  
Error shape: `{ "data": { "fieldName": null }, "errors": [{ "message": "..." }] }`. Source: `twenty-server/src/engine/api/graphql/direct-execution/direct-execution.service.ts` lines 265–274 and 330–337.  
`onError: continueErrorOutput` only fires on non-2xx responses — it will NEVER fire for a Twenty GQL failure.  
FIX: Use `onError: continueRegularOutput` on all Twenty HTTP Request nodes. After each mutation, add an IF node checking `($json.errors?.length ?? 0) > 0`.  
DISCOVERY: 2026-05-03 during Workflow H tester round 4.

---

## Part 3 — Twenty CRM v2.1.0 Integration

Source: ADR-0005 (2026-04-26), `reference/twenty-v2.1.0-api.md` (774 lines, source-cited).

### Three distinct endpoints

| Endpoint | Purpose |
|---|---|
| `/graphql` | Per-workspace data CRUD (generated resolvers per custom object) |
| `/metadata` | Schema management — create/update/delete objects and fields |
| `/rest/*` | REST proxy to the same operations |

### Mutation naming conventions

- **Data API:** `createCandidate`, `updateCandidate`, `candidates`, `deleteCandidate` — NO `One`/`Many` infix. Verified against `get-resolver-name.util.ts` and tester run 2026-04-26.
- **Metadata API:** `createOneObject`, `updateOneField`, `deleteOneObject` — always includes `One` or `Many` infix.
- Confusing these was the root cause of `tester round 4` failures in Phase 2 (code-reviewer catch, commit `c90db9c`).

### Field type renames from v0.60 to v2.1.0

| Old | New |
|---|---|
| `PHONE` | `PHONES` (composite) |
| `EMAIL` | `EMAILS` (composite) |
| `JSON` | `RAW_JSON` |
| `URL` | `LINKS` (composite) |
| `MANY_TO_MANY` | Does not exist — model as junction object with two `MANY_TO_ONE` relations |

Source: `packages/twenty-shared/src/types/FieldMetadataType.ts` and `RelationType.ts`.

### Soft-delete trap (T2-20)

If a candidate has been soft-deleted (e.g., DPA erasure) and then messages again, `Resolve Candidate by Phone` returns empty edges (Twenty hides soft-deleted records) AND `Create Candidate in Twenty` fails with a "duplicate entry" error on the unique `whatsappNumberE164` constraint (which ignores `deletedAt`). Both legs evaluate to `null`, producing `candidateId = null` for all downstream writes. Surfaced 2026-05-01 during live testing — test candidate had been manually soft-deleted during early runs. Fix tracked as T2-20 in `plans/tier-2-followups.md`.

### HTTP 200 always — never use `onError: continueErrorOutput` for GQL error detection

See Rule #33. Use `($json.errors?.length ?? 0) > 0` in a downstream IF node.

### GQL `$varName`-as-n8n-variable trap

See Rule #30. The `$` character in a quoted string inside `={{ }}` is parsed by n8n as a variable reference. All GQL queries in this project use inline string concatenation; there are no `variables:` payloads that contain GQL-style `$varName` declarations.

### Rate limit

100 requests/minute per workspace. Bulk operations must paginate. Source: `docs.twenty.com/developers/extend/capabilities/apis` (cited in ADR-0005).

### SELECT option values

Must be UPPER_SNAKE_CASE. `defaultValue` must be SQL-literal single-quoted, not JSON-encoded. Source: `serialize-default-value.util.ts:66-70`. Phase 2 RED rounds R2 and R3.

### RESERVED_METADATA_NAME_KEYWORDS

`job`/`jobs` is reserved. Using a reserved name produces a Twenty enforcement error. `scripts/audit-twenty-schema.py` catches this locally before apply.

---

## Part 4 — WhatsApp Cloud API

### Meta test account restrictions

- The WhatsApp Business test phone number can only send messages to verified test numbers during the sandbox phase.
- HMAC validation is required for all inbound webhooks. `X-Hub-Signature-256` header. `crypto` stdlib module must be allowlisted via `NODE_FUNCTION_ALLOW_BUILTIN=crypto` (Rule #12).
- Webhook verify token handshake (`hub.mode=subscribe`, `hub.challenge`) must be handled before any message processing can begin.
- Real Ghana traffic verified end-to-end on event_log row 13: +233 532 751 040, HMAC-validated, commit `9f4241d`.

### Service window enforcement

The `wa-send.json` subflow enforces Meta's 24-hour customer service window:
- `Fetch Last Inbound Time` queries `conversation_message` for the most recent inbound message by this candidate.
- `Service Window Open?` IF node checks whether that message was within 24 hours.
- If window is closed: falls back to a pre-approved template (`templateName` parameter from the caller). Error code 131047 is the Meta code for "out-of-window free-form message."
- If `templateName` is absent and the window is closed: T2-14 tracks a bug where `still_interested_10d` (a re-engagement template) is used as a default — semantically wrong for most callers.

### Error codes

| Code | Meaning |
|---|---|
| 131047 | Message rejected — outside 24h service window; free-form send not permitted |
| 131030 | Recipient phone number not registered on WhatsApp |

### Template approval process

From `.claude/rules/whatsapp-templates.md`:
1. Draft in `reference/whatsapp-templates/<name>.md` with purpose, category, body, variables.
2. Submit manually via Meta Business Manager (no API automation in v1).
3. Approval: typically under 1 hour, up to 48 hours.
4. On APPROVED: update doc status.
5. On REJECTED: revise. Meta's rejection reason points to specific language to change.

Templates in use: `consent_request`, `interview_reminder_24h`, `interview_reminder_2h`, `re_engagement_v1`, `still_interested_10d`, `data_access_delivery`.

Pre-launch blockers: `screening_reminder_24h`, `screening_withdrawn_72h` (T2-21), `weekly_report` (T2-F-1) not yet approved.

### Variable rules

- `{{1}}` is always the candidate first name.
- `{{2}}`, `{{3}}` are role-specific, documented per template.
- Maximum 4 variables.
- No links to web forms. No sensitive data requests. No emojis in body.

### Cost at $0.014/utility message (Ghana)

- 500 templates/month → ~$7/month
- 2000 templates/month → ~$28/month
- Workflow G monitors pace and alerts if projected monthly cost exceeds $30.

---

## Part 5 — Architecture Patterns

### Subflow pattern

Three subflows are reused across all workflows:

| Subflow | File | Purpose |
|---|---|---|
| `Subflow — WA Send` | `n8n-workflows/communications/wa-send.json` | 24h service window enforcement, template fallback on 131047 |
| `Subflow — Claude Call` | `n8n-workflows/communications/claude-call.json` | Model routing, $10/day budget gate, `ai_call_log` write, Workflow A exemption |
| `Subflow — DPA Handler` | `n8n-workflows/communications/dpa-handler.json` | DATA/ACCESS and DELETE/FORGET intents — ack message + Twenty mutation + event_log |

All three are referenced via `executeWorkflow` with `PLACEHOLDER_*_WORKFLOW_ID` values in committed JSON. `patch-workflow-ids.sh` resolves live IDs from the n8n DB before each import.

After importing a subflow, its ID changes. `n8n-reimport.sh` has a cascade behaviour: when it detects a subflow import, it automatically re-runs `patch-workflow-ids.sh` and re-imports `a-communications.json`.

### Conv-lock pattern (Workflow A, C, D)

- Key format: `hra:conv:{candidateId}` (ADR-0009)
- Token: `$execution.id` only — no random suffix (Rule #15)
- v1 TTL: 180s flat (no heartbeat) — n8n 1.85.0 sequential execution model prevents a parallel heartbeat. True Lua CAS PEXPIRE heartbeat deferred to T2-12.
- Acquire: Redis Get → If (value empty) → Redis Set (expire 180s). TOCTOU race accepted at v1 volume (T2-18).
- Release: Redis Get → If (value === token) → Redis Delete. TOCTOU race accepted (T2-19).
- Release runs on all six exit paths (Rule #4; `a-communications-NOTES.md` §4 documents all 6).
- Error path reads the lock token from `event_log` (not `$execution.customData`, which is read-only — see NOTES §2).

### Dedupe pattern

- Key format: `hra:dedupe:{external_event_id}` (ADR-0009)
- TTL: 24h
- First node after Webhook trigger. If key exists: return 200 immediately and halt.
- Example: `hra:dedupe:' + $('Normalise Phone Number').first()?.json?.waMessageId`

### Screening inbox / poll pattern (Workflows A→B, A→C, A→D)

Workflow A does not call Workflow B/C/D directly. It inserts a row into `screening_inbox` with a `trigger_kind`. Downstream workflows poll on a 60-second Cron, claim a row with `FOR UPDATE SKIP LOCKED`, and process it. This decouples Workflow A's latency from the processing workflows and prevents double-processing via the partial unique index `uq_screening_inbox_candidate_active` (V008).

Trigger kinds used:
- `new_application` — CV submission for white-collar screening (Workflow B)
- `blue_collar_new` — new blue-collar application (Workflow C)
- `blue_collar_reply` — candidate reply during active blue-collar Q&A session (Workflow C)
- `scheduling_reply` — candidate reply selecting an interview slot (Workflow D)
- `re_engagement_reply` — candidate YES/NO reply to re-engagement offer (Workflow H, via T2-H-1)

### Actual Redis key formats observed in production

From `grep -rh "hra:" n8n-workflows/ --include="*.json"`:

```
hra:conv:{candidateId}          — conversation locks (Workflows A, B, C, D)
hra:dedupe:{waMessageId}        — WhatsApp inbound message dedupe (Workflow A)
hra:social:{postId}             — social post processing lock (Workflow E)
```

---

## Part 6 — Docker Compose

### n8n service environment block (verbatim from `infrastructure/docker-compose.yml`)

```yaml
N8N_HOST: ${N8N_HOST}
N8N_PORT: 5678
N8N_PROTOCOL: https
WEBHOOK_URL: ${N8N_WEBHOOK_URL}
GENERIC_TIMEZONE: Africa/Accra
TZ: Africa/Accra
N8N_LOG_LEVEL: info
DB_TYPE: postgresdb
DB_POSTGRESDB_HOST: bookings-db
DB_POSTGRESDB_PORT: 5432
DB_POSTGRESDB_DATABASE: ${N8N_DB_NAME}
DB_POSTGRESDB_USER: ${N8N_DB_USER}
DB_POSTGRESDB_PASSWORD: ${N8N_DB_PASSWORD}
N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
N8N_USER_MANAGEMENT_JWT_SECRET: ${N8N_JWT_SECRET}
QUEUE_BULL_REDIS_HOST: redis
QUEUE_BULL_REDIS_PORT: 6379
EXECUTIONS_DATA_PRUNE: "true"
EXECUTIONS_DATA_MAX_AGE: "336"   # 14 days in hours
N8N_RUNNERS_ENABLED: "true"
N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"
TWENTY_API_URL: http://twenty:3000
TWENTY_API_KEY: ${TWENTY_API_KEY}
GROQ_API_KEY: ${GROQ_API_KEY}
ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}
WHATSAPP_ACCESS_TOKEN: ${WHATSAPP_TOKEN}
CALIBRATION_WINDOW_ACTIVE: "false"
NODE_FUNCTION_ALLOW_BUILTIN: "crypto"
WHATSAPP_TOKEN: ${WHATSAPP_TOKEN}
WHATSAPP_PHONE_NUMBER_ID: ${WHATSAPP_PHONE_NUMBER_ID}
WHATSAPP_BUSINESS_ACCOUNT_ID: ${WHATSAPP_BUSINESS_ACCOUNT_ID}
WHATSAPP_VERIFY_TOKEN: ${WHATSAPP_VERIFY_TOKEN}
WHATSAPP_APP_SECRET: ${WHATSAPP_APP_SECRET}
META_PAGE_ID: ${META_PAGE_ID}
META_PAGE_ACCESS_TOKEN: ${META_PAGE_ACCESS_TOKEN}
TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHANNEL_ID: ${TELEGRAM_CHANNEL_ID}
STAFF_WHATSAPP_NUMBER: ${STAFF_WHATSAPP_NUMBER}
```

### Every env var — what it is and what breaks without it

| Variable | What it is | Breaks without it |
|---|---|---|
| `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` | Restores `$env.*` expression access (n8n 2.x blocks by default) | All API key reads silently `undefined`; every external API call fails silently |
| `NODE_FUNCTION_ALLOW_BUILTIN: "crypto"` | Allowlists `require('crypto')` in Code nodes | HMAC validation throws `crypto is not defined` |
| `TWENTY_API_URL` | Base URL for Twenty GraphQL calls | All Twenty HTTP Request nodes fail |
| `TWENTY_API_KEY` | Bearer token for Twenty data+metadata API | HTTP 401 on all Twenty requests |
| `ANTHROPIC_API_KEY` | Bearer token for Claude Messages API | Claude Call subflow fails silently with `undefined` key |
| `GROQ_API_KEY` | Bearer token for Groq Whisper | Voice note transcription fails; Workflow A routes voice notes to error queue |
| `WHATSAPP_TOKEN` / `WHATSAPP_ACCESS_TOKEN` | Meta Cloud API bearer token (duplicated for compatibility) | Outbound WhatsApp sends fail; webhook processing can succeed but sends fail |
| `WHATSAPP_PHONE_NUMBER_ID` | Meta's identifier for the registered WA number | Send API URL construction fails |
| `WHATSAPP_BUSINESS_ACCOUNT_ID` | Meta business account ID for billing/quotas | Some Meta API calls fail |
| `WHATSAPP_VERIFY_TOKEN` | Shared secret for webhook GET verification | Webhook verify handshake fails; Meta stops delivering messages |
| `WHATSAPP_APP_SECRET` | Meta app secret for HMAC signature validation | HMAC validator rejects all inbound messages as untrusted |
| `META_PAGE_ID` | Facebook Page identifier for post publishing | FB URL evaluates to `.../undefined/feed` — discovered Workflow E live test 2026-05-03 |
| `META_PAGE_ACCESS_TOKEN` | Page-level access token for Graph API posting | FB post fails; URL constructed but API rejects no-auth request |
| `TELEGRAM_BOT_TOKEN` | Bot token from @BotFather | URL evaluates to `.../botundefined/sendMessage` |
| `TELEGRAM_CHANNEL_ID` | Numeric channel ID (must start `-100` for broadcast channels) | Messages delivered to wrong chat or not at all |
| `N8N_ENCRYPTION_KEY` | Key for encrypting stored credentials | On container restart, all credentials become unreadable |
| `CALIBRATION_WINDOW_ACTIVE` | `"true"` during 2-week human review window | All review gates pass through automatically when not active |
| `STAFF_WHATSAPP_NUMBER` | E.164 number for weekly report delivery (Workflow F) | Report cannot be sent to staff |

### The `pg_isready` healthcheck

All Postgres services use `pg_isready -U ${USER}` as the healthcheck command. This uses the standard PostgreSQL health probe; dependent services wait for `service_healthy` before starting. The bookings-db healthcheck gates both n8n and the `migrate-bookings` one-shot runner.

### n8n stores its own data in bookings-db

The n8n service uses `hr-bookings-db` for its own internal data (`n8n_bookings` user, `n8n` database — separate from the bookings DB user/schema). This means a backup drill must dump three databases: `hr-twenty-db`, `hr-bookings-db` (bookings schema), and `hr-bookings-db` (n8n schema). The original backup spec missed the n8n database — corrected 2026-04-29 per `backup-dr.md` audit.

---

## Part 7 — Build Process & Harness

### Agent dispatch cycle

From `CLAUDE.md §"How we work"`:
1. Read active plan → identify current workflow
2. Dispatch `architect` → receives an ADR in `docs/05-decisions/`
3. Dispatch `workflow-builder` → produces JSON in `n8n-workflows/`
4. Dispatch `tester` → runs acceptance criteria
5. If RED: fix → re-dispatch tester
6. Dispatch `code-reviewer` → checks invariants
7. If flagged: fix → re-dispatch code-reviewer
8. Update `.claude/memory/status.md` and close the plan

A feature is NOT done until both `tester` GREEN and `code-reviewer` APPROVE.

### The three scripts

**`scripts/patch-workflow-ids.sh`**  
Fetches live subflow IDs and credential IDs from the n8n Postgres DB, then patches all workflow JSON files in a Python heredoc. Uses an explicit `NODE_TO_SUBFLOW` dict (not keyword matching — Rule #21). Prints a `WARN` to stderr for any Execute Workflow node name not in the dict. Run before every import.

Files it patches: `a-communications.json`, `dpa-handler.json`, `b-screening.json`, `c-screening.json`, `d-scheduling.json`, `f-reporting.json`, `h-job-alerts.json`.

When adding a new workflow: add its file path to the `for filepath in [...]` list AND add each Execute Workflow node name → subflow mapping to `NODE_TO_SUBFLOW`.

**`scripts/n8n-reimport.sh`**  
Accepts a single JSON file path. Steps:
1. Runs `patch-workflow-ids.sh`
2. Deactivates and deletes any existing workflow with the same name (active workflows hold webhook endpoints)
3. Strips read-only fields (`id`, `createdAt`, `updatedAt`, `versionId`, `active`, `meta`, `pinData`, `staticData`, `tags`) and POSTs to n8n REST API
4. Activates the imported workflow
5. If the workflow has `settings.errorWorkflow == "PLACEHOLDER_H_SELF_REF"`, patches it to the new ID (used for workflows that serve as their own error handler)
6. Cascade: if the imported file is a known subflow, re-runs `patch-workflow-ids.sh` and re-imports `a-communications.json` (because subflow IDs change on every import)

**`scripts/n8n-debug.sh`**  
Four subcommands:
- `executions` — last 10 executions via REST API, formatted table
- `execution <id>` — queries the n8n DB directly (REST API returns empty `runData` in n8n 2.x); decodes n8n's reference-compressed execution data array; prints all nodes executed with timing and status
- `last-error` — fetches most recent failed execution and delegates to `execution <id>`
- `workflow-status` — all workflows with active/archived state

**Important:** `execution <id>` uses `docker exec hr-bookings-db psql` rather than the REST API because n8n 2.x's `includeData=true` REST response returns empty `runData`. The DB-direct query reads from `execution_data` table, deserialises n8n's reference-compressed JSON array (indexed back-references), and extracts `resultData.runData` for per-node status display. The reference-compression decompressor uses single-chain resolution (not full tree expansion) to avoid exponential blowup on shared scalars like timestamps.

Commit `561b3f1` fixed a RecursionError in the decompressor for large executions (full tree expansion hit Python recursion limit).

### `patch-workflow-ids.sh`: why keyword matching was wrong (Rule #21)

The original v1 approach used a keyword list (`['reply', 'send', 'wa']` → WA Send; `['claude', 'generate', 'extract', 'score', 'classify']` → Claude Call). The node name "Generate Reply — Claude Sonnet" contains `'reply'` (WA Send keyword list) and `'claude'` (Claude Call keyword list). Which keyword wins? Depends on evaluation order. The fix committed at `d920ac9` replaced the keyword dict with an explicit `NODE_TO_SUBFLOW` map keyed by exact node name.

### `n8n-reimport.sh`: cascade logic and self-reference patch

The cascade exists because n8n assigns a new random ID to every imported workflow. When `wa-send.json` is re-imported, its ID changes. All workflows that call it via `executeWorkflow` now point to a stale ID. The cascade automatically re-patches and re-imports `a-communications.json` to pick up the new WA Send ID.

The `PLACEHOLDER_H_SELF_REF` pattern is used by Workflow H (which is its own error handler — `settings.errorWorkflow` must point to itself). Since the ID is unknown before import, the placeholder is written in the committed JSON and patched post-import via a PUT to the n8n REST API.

---

## Part 8 — Failure Mode Table

| # | Symptom | Root Cause | Fix | Rule/Commit |
|---|---|---|---|---|
| 1 | Subflow receives no input data; `$json` is bare trigger output | n8n 2.x Execute Workflow uses `workflowInputs.value`, not `fields.values` | Convert all Execute Workflow nodes to resourceMapper format | Rule #19, commit `b97b9f0` |
| 2 | Set node is a transparent pass-through; downstream expressions get `{}` | Set node `typeVersion: 3` with `assignments` params reads `fields.values` (empty) | Bump typeVersion to `3.4` on all Set nodes using `assignments` | Rule #20, commit `29aeb5f` |
| 3 | "Generate Reply — Claude Sonnet" calls WA Send instead of Claude Call | Keyword-based subflow routing matched 'reply' to WA Send keyword list | Replace keyword dict with explicit `NODE_TO_SUBFLOW` map | Rule #21, commit `d920ac9` |
| 4 | All `$env.*` expressions resolve to `undefined`; API calls fail silently | n8n 2.x blocks env access by default | Add `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` to docker-compose.yml n8n env | Rule #17, commit `5185437` |
| 5 | Postgres INSERT fails with extra parameters; user message text corrupted | `queryReplacement` `stringToArray()` splits on commas in user text | Use array form `={{ [v1, v2] }}` for all TEXT columns | Rule #18, commit `af11cee` |
| 6 | `crypto is not defined` in HMAC validator Code node | n8n Code node sandbox blocks `require('crypto')` | Add `NODE_FUNCTION_ALLOW_BUILTIN: "crypto"` to docker-compose.yml | Rule #12, 2026-04-28 |
| 7 | INSERT into `workflow_errors` fails NOT NULL constraint | `execution_id` not bound; Error Trigger uses `$json.execution.id` not `$execution.id` | Bind all NOT NULL columns; use correct execution context reference | Rule #13, 2026-04-28 |
| 8 | Consent flow routes GRANTED candidates to PENDING branch | `consentStatus` read from Set node (which was a transparent pass-through) | Read directly from `$('Resolve Candidate by Phone')` result | Rule #23, commit `ba9821c` |
| 9 | `Claim Inbox Row` halts execution on empty inbox instead of branching | `alwaysOutputData: true` placed inside `parameters.options` (ignored) | Move to node root level | Rule #24, commit `09b6838` |
| 10 | `"Workflow does not exist"` at runtime after subflow reimport | New workflow file not added to `patch-workflow-ids.sh` file list | Add file path AND node name mappings to the script | Rule #25, 2026-05-01 |
| 11 | Calendar credential error bypasses designed failure branch | `onError: continueErrorOutput` set but `connections.main[1]` not wired | Wire the error output branch in `connections` | Rule #27, commit `b5b86ff` |
| 12 | Zero-row slot query routes into "has slots" branch | IF node uses `$items().length > 0` (sees 1 empty item from `alwaysOutputData`) | Change to `$json.id ?? ''` with `string / notEmpty` operator | Rule #28, commit `8698a8e` |
| 13 | FB URL is `.../undefined/feed`; Telegram URL is `.../botundefined/sendMessage` | `META_PAGE_ID` etc. in `.env` but not in n8n service `environment:` block | Add all missing vars to docker-compose.yml n8n env block | Rule #29, commit `5185437` |
| 14 | Twenty HTTP nodes send `{}` as POST body; all receive HTTP 400 | `sendBody: true` without `specifyBody: "json"` — defaults to keypair format | Add `specifyBody: "json"` + `contentType: "json"` to all Twenty HTTP Request nodes | Rule #31, commit `5a86d42` |
| 15 | GQL queries send `{"": null}` to Twenty | `$varName` inside quoted GQL string parsed as n8n variable (undefined) | Remove GQL variable declarations; inline values via string concatenation | Rule #30, commit `7027130` |
| 16 | SplitInBatches loop body receives `{error: "invalid syntax"}`; no candidates processed | Cross-node `$('NodeName')` reference fails inside loop context | Bake values into items with a Set node (typeVersion 3.4) before the loop | Rule #32, commit `8e9e1bd` |
| 17 | Twenty GQL mutation error branch structurally dead; mutations fail silently | `onError: continueErrorOutput` never fires on Twenty (HTTP 200 always) | Use `onError: continueRegularOutput` + downstream IF checking `$json.errors?.length` | Rule #33, commit `6a8068d` |
| 18 | n8n-debug.sh `execution <id>` returns empty node list | n8n 2.x REST API returns empty `runData` in includeData responses | Switch to direct DB query against `execution_data` table | Commit `1f28f9d` |
| 19 | n8n-debug.sh RecursionError on large executions | Full tree expansion of reference-compressed JSON hits Python recursion limit | Use single-chain resolution (follow refs only for specific fields needed) | Commit `561b3f1` |
| 20 | Soft-deleted candidate re-messages; `candidateId = null` on all downstream writes | Twenty hides soft-deleted records; Create mutation fails with duplicate unique constraint | Add IF + re-resolve path for soft-deleted candidates | T2-20, surfaced 2026-05-01 |
| 21 | `job`/`jobs` custom object name rejected by Twenty | Reserved in `RESERVED_METADATA_NAME_KEYWORDS` | Rename to `jobPosting`/`JobPosting` | Phase 2 R1, commit `54ca502` |
| 22 | SELECT field option values rejected by Twenty | Options must be UPPER_SNAKE_CASE (not lowercase) | Rewrite all 16 SELECT fields; `audit-twenty-schema.py` now catches this | Phase 2 R2, commit `8a6c88c` |
| 23 | `defaultValue` rejected by Twenty on SELECT fields | Must be SQL-literal single-quoted, not JSON-encoded | Fix quoting; add audit check | Phase 2 R3, commit `37e7934` |
| 24 | Instagram integration structurally blocked | Meta Business Manager refuses the Page↔IG account link | Deferred per ADR-0007; voucher script skip-gates on empty `META_IG_USER_ID` | ADR-0007 |
| 25 | OpenAI Whisper billing blocked on Ghanaian card | OpenAI card-acceptance failure (Ghana-region) | Pivoted to Groq Whisper per ADR-0006 | ADR-0006 |

---

## Part 9 — Pre-Launch Checklist

### From CLAUDE.md §"Non-negotiable invariants"

- [ ] All Twenty reads and writes go through Twenty's GraphQL API — never write directly to Twenty's Postgres database
- [ ] No rollups, formula fields, or action-button webhooks assumed in Twenty — compute derived fields in n8n; use Manual-triggered workflows for server-side logic
- [ ] Redis conv-locks use 60-second TTL (v1: 180s flat); Lua CAS release on all exit paths (v1: two-step GET+IF+DELETE); full heartbeat deferred to T2-12
- [ ] Social posting uses free native APIs only — Meta Graph API, X API free tier, Telegram Bot API; no Blotato; no LinkedIn
- [ ] Ghanaian local-language voice notes routed to human review queue — Groq `whisper-large-v3-turbo` handles English and Ghanaian Pidgin only
- [ ] Every user-facing output reviewed by a human for the first two weeks after launch (calibration window)

### From `.claude/rules/n8n-workflows.md`

- [ ] Every workflow has a top-level Error Trigger writing to `workflow_errors`
- [ ] Every HTTP Request node has explicit timeout (10–30s), 2 retries on 5xx/429, and correct `onError` behaviour
- [ ] All Postgres nodes use n8n credential system — no inline connection strings
- [ ] Redis lock pattern: `hra:conv:{candidateId}`, acquire + release on all exit paths
- [ ] Dedupe: Redis SETNX on `hra:dedupe:{external_event_id}` as first node after Webhook
- [ ] Claude calls through `claude-call.json` subflow
- [ ] WhatsApp sends through `wa-send.json` subflow
- [ ] Human-readable node names
- [ ] Workflow tags: `hr-automation`, workflow letter, version
- [ ] No credentials in exported JSON (pre-commit hook enforces)
- [ ] ReviewTask.subject: exactly one of subjectCandidate or subjectApplication — never both, never neither
- [ ] `NODE_FUNCTION_ALLOW_BUILTIN: "crypto"` in docker-compose.yml n8n env
- [ ] All NOT NULL columns bound in every Postgres INSERT (cross-check V-migration before generating nodes)
- [ ] All Redis keys use `hra:` prefix
- [ ] Conv-lock token is `$execution.id` only
- [ ] Execute Workflow nodes use `workflowInputs.value` (resourceMapper format)
- [ ] Set nodes that use `assignments` format have `typeVersion: 3.4`
- [ ] `patch-workflow-ids.sh` updated with any new workflow files and node-name mappings
- [ ] `alwaysOutputData: true` at node root level — not inside `parameters.options`
- [ ] IF nodes checking for zero-row results use field-existence test, not `$items().length`
- [ ] `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` in docker-compose.yml
- [ ] Every `$env.SOME_VAR` expression has a matching line in the n8n service `environment:` block
- [ ] HTTP Request nodes with error branches have `"onError": "continueErrorOutput"` at root AND error output (`main[1]`) wired in `connections`
- [ ] SplitInBatches loop bodies use `$json.fieldName` for cross-loop values (baked by a Set node before the loop)
- [ ] Twenty HTTP Request nodes use `onError: continueRegularOutput` + downstream IF checking `$json.errors?.length`
- [ ] All HTTP Request nodes with `sendBody: true` have `specifyBody: "json"` explicitly set
- [ ] No GQL `$varName` declarations inside n8n expression strings — inline values via string concatenation
- [ ] `queryReplacement` uses array form for any TEXT column that can contain user-supplied or system-generated text

### WhatsApp templates

- [ ] `consent_request` — approved
- [ ] `interview_reminder_24h` / `interview_reminder_2h` — approved
- [ ] `re_engagement_v1` — approved
- [ ] `still_interested_10d` — approved
- [ ] `data_access_delivery` — approved
- [ ] `screening_reminder_24h` — T2-21: submit and obtain approval before Workflow C go-live
- [ ] `screening_withdrawn_72h` — T2-21: same
- [ ] `weekly_report` — T2-F-1: submit and obtain approval before Workflow F go-live

### Pre-launch blockers (not yet resolved)

- [ ] T2-14: Fix `still_interested_10d` as default template fallback in wa-send — semantic mismatch for most callers
- [ ] T2-15: Store outbound messages in `conversation_message` for DPA audit trail
- [ ] T2-16: Document or cap Workflow A's permanent Claude budget exemption
- [ ] T2-20: Soft-deleted candidate re-entry null candidateId bug
- [ ] T2-21: WhatsApp template approvals for Workflow C
- [ ] T2-D-4: Calibration-gate ReviewTask for Workflow D outbound WA sends
- [ ] T2-E-1: Explicit `isApproved` gate for Workflow E SocialPost publishing (V016 migration + poll filter)
- [ ] T2-F-1: `weekly_report` WhatsApp template approval
- [ ] T2-F-2: Calibration-window pre-send ReviewTask gate on Workflow F Claude Haiku narrative
- [ ] T2-H-1: Workflow A `re_engagement_reply` routing branch before first live Workflow H run
- [ ] T2-H-2: Workflow H pre-send ReviewTask gate (calibration window)

---

## Part 10 — T2 Backlog

Full text in `plans/tier-2-followups.md`. Grouped by workflow below.

### Infrastructure / Cross-cutting

- **T2-1.** Wire `audit-twenty-schema.py` as a git pre-commit hook. Target: Week 0 close (not yet done).
- **T2-2.** Remove dead `sed '/^[[:space:]]*\/\//d'` from `scripts/apply-twenty-schema.sh`. Target: post-Week-0.
- **T2-3.** Annotate stale items in `twenty-schema/IMPLEMENTATION_NOTES.md`. Target: post-Week-0.
- **T2-4.** Fix `README.md` `applied_by` doc/code drift. Target: post-Week-0.
- **T2-5.** Extend `audit-twenty-schema.py` to validate composite-typed defaults (CURRENCY, PHONES, EMAILS, etc.). Target: Week 0 close or at first need.
- **T2-7.** Production-grade backup script (cron + B2 + rotation + alerting). Target: Week 4.
- **T2-8.** Full backup-restore drill with live RTO measurement. Target: first Monday of Week 2.
- **T2-9.** Rules consolidation pass (RC1–RC5: Nginx default_server, Docker single-file bind-mount, n8n Webhook rawBody toggle, Twenty data-API resolver naming, RESERVED_METADATA_NAME_KEYWORDS). Target: after Week 1 close.
- **T2-10.** `observability.md` aspirational references — annotate `scripts/metrics-exporter.py` as not-yet-shipped. Target: post-Week-0.
- **T2-11.** `ghana-context.md` holiday list drift — annotate as illustrative only; Google Calendar is authoritative per ADR-0003. Target: post-Week-0.

### Workflow A

- **T2-12.** Implement true conv-lock heartbeat (Lua PEXPIRE-CAS every 15s). Target: post-Week-1; natural trigger is n8n queue-mode adoption.
- **T2-13.** ReviewTask error path — rule #11 edge case when no `candidateId` before lock acquisition. Target: post-Week-1.
- **T2-14.** Fix wrong template fallback in wa-send.json "Force Template — Window Expired". **Pre-launch.** Target: pre-launch.
- **T2-15.** Store outbound messages in `conversation_message`. **Pre-launch.** Target: pre-launch.
- **T2-16.** Document or cap Workflow A's Claude budget exemption. **Pre-launch.** Target: pre-launch.
- **T2-17.** Reduce `ai_call_log` `prompt_excerpt` from 200 to 40 chars. Target: pre-launch.
- **T2-18.** Replace two-step GET+SET conv-lock acquire with atomic SETNX. Target: post-Week-1; same trigger as T2-12.
- **T2-19.** Replace two-step GET+DELETE conv-lock release with atomic Lua CAS DEL. Target: post-Week-1; bundle with T2-18.
- **T2-20.** Soft-deleted candidate re-messages — null candidateId bug. **Pre-launch (before DPA deletion handler enabled).** Target: pre-launch.
- **T2-6.** Pidgin transcription quality sanity-check (Groq Whisper, 5–10 real voice note samples). Target: pre-Workflow-A voice-note auto-handling.

### Workflow C

- **T2-21.** WhatsApp template approvals for `screening_reminder_24h` + `screening_withdrawn_72h`. **Blocking pre-launch.** Submit immediately.
- **T2-23.** Workflow C — `createCandidateSkillTag` loop deferred (no `skillTagId` source in v1). Target: post-launch Week 2.

### Workflow D

- **T2-D-4.** Calibration-gate ReviewTask for all four Workflow D outbound WA send paths. **Blocking pre-launch.** Target: before first production use.

### Workflow E

- **T2-E-1.** Explicit `isApproved` gate for SocialPost publishing (V016 migration). **Blocking pre-launch.** Target: before Workflow E goes live on real traffic.

### Workflow F

- **T2-F-1.** `weekly_report` WhatsApp template approval. **Blocking pre-launch.** Submit immediately.
- **T2-F-2.** Calibration-window pre-send ReviewTask gate on Claude Haiku narrative. **Blocking pre-launch.** Target: before Workflow F goes live during calibration window.

### Workflow H

- **T2-H-1.** Workflow A `re_engagement_reply` routing branch. **Blocking pre-launch.** Apply immediately after Workflow H build.
- **T2-H-2.** Workflow H pre-send ReviewTask gate (calibration window). **Blocking pre-launch.** Before first live re-engagement run.

---

## Part 11 — The 10 Biggest Lessons

### 1. n8n 2.x has silent breaking changes that produce no error at import time

When the project moved from n8n 1.85.0 to 2.18.5, **five separate silent compatibility breaks** appeared simultaneously during the first live test (2026-04-30): Execute Workflow schema (`workflowInputs.value`), Set node typeVersion split, env var access block, Redis `executeCommand` removal, and Postgres `queryReplacement` comma-splitting. None produced an error at import time. The symptom in every case was "node runs and produces wrong output." The diagnostic path is `n8n-debug.sh execution <id>` → inspect `runData` → check actual node output vs expected. **Lesson: Pin n8n version. Never upgrade without a full regression run. Read the changelog for any node typeVersion defaults.**

### 2. Twenty GraphQL always returns HTTP 200 — you cannot rely on HTTP status for error detection

This bit Workflow H on tester round 4 (2026-05-03). `Create Application` had `onError: continueErrorOutput` — which can NEVER fire for a Twenty mutation failure because Twenty wraps all errors in `{ "data": null, "errors": [...] }` inside an HTTP 200. The error branch was structurally dead. The fix is always `onError: continueRegularOutput` on Twenty nodes plus a downstream IF checking `$json.errors?.length`. Rule #33. **Lesson: For any GraphQL backend, HTTP status is not an error signal — check the response body.**

### 3. `$env.*` access in n8n expressions must be explicitly re-enabled in n8n 2.x

`N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` in the n8n service env block is required. Without it, `$env.ANTHROPIC_API_KEY`, `$env.WHATSAPP_TOKEN`, and every other credential read silently resolves to `undefined`. The API call is made with `Authorization: Bearer undefined` — no error, no warning. The symptom is silent API failures. And separately (Rule #29): `.env` vars are NOT automatically available inside containers — they must be explicitly referenced in the service `environment:` block. FB published to `…/undefined/feed` and Telegram to `…/botundefined/sendMessage` until this was discovered during Workflow E live test (2026-05-03). **Lesson: For every `$env.VAR` in workflow JSON, verify the var exists in the n8n service `environment:` block in docker-compose.yml, not just in `.env`.**

### 4. Subflow ID management requires an explicit, maintained mapping — keyword matching breaks

The `patch-workflow-ids.sh` script originally used keyword lists to map node names to subflow IDs. "Generate Reply — Claude Sonnet" contains `'reply'` (a WA Send keyword) and `'claude'` (a Claude Call keyword). The script routed it to WA Send (2026-04-30). The fix: an explicit `NODE_TO_SUBFLOW` dict keyed by exact node name. Rule #21. **Lesson: Any automated renaming/routing scheme based on substring matching will eventually encounter an ambiguous name. Explicit maps are the only safe approach.**

### 5. The `alwaysOutputData` flag must be at node root level and the downstream IF must test field existence

Two separate bugs with the same root mechanism. `alwaysOutputData: true` inside `parameters.options` is silently ignored (Rule #24). And when `alwaysOutputData: true` IS correctly set at root level, a zero-row result emits one empty item `{}`. `$items().length` sees 1 and evaluates true (Rule #28). Both bugs produce the same symptom: a branch that should handle "no data found" never runs, and the "data found" branch executes with empty input. The Workflow B inbox polling (`Claim Inbox Row`) and the Workflow D slot query (`Got Offered Slots?`) both hit these bugs. **Lesson: Zero-row results in n8n require two coordinated fixes — placement of the flag AND the correct downstream comparison operator.**

### 6. The shared Redis is used by Three tenants — namespace discipline prevents silent data corruption

The `hr-redis` instance is shared by Twenty (keys `bull:*`, `engine:*`, `module:*`), n8n (nothing in regular mode), and HRA workflows (keys `hra:*`). Without the `hra:` prefix mandate (ADR-0009, Rule #14), an HRA workflow using `conv:candidateId` as a key would accidentally share namespace with any future Twenty internal key that happens to start with `conv:`. This was caught ahead of need during Phase 6 reconnaissance (2026-04-29) by empirically observing the live Redis keyspace. **Lesson: Any system where multiple tenants share a Redis instance needs a prefix mandate established before the first production write, not after.**

### 7. Twenty CRM v2.x has a completely different API surface from v0.60-era documentation

Three endpoint surfaces, field type renames (`PHONE` → `PHONES`, `JSON` → `RAW_JSON`, etc.), mutation naming convention split between data API (no `One` infix) and metadata API (`createOneObject`), reserved object names (`job`/`jobs`), UPPER_SNAKE_CASE option values, SQL-literal single-quoted `defaultValue`. None of this was documented in the original spec — it was all discovered through a systematic `researcher` pass against the v2.1.0 source checkout (ADR-0005). The Phase 2 tester produced four RED rounds before green, each surfacing a real Twenty enforcement rule. **Lesson: Before building against a CRM or database API, do a source-level research pass, not just the public docs. Write the findings down (ADR + reference doc) so every subsequent agent and developer can self-serve.**

### 8. SplitInBatches loop bodies cannot reference nodes outside the loop context

Cross-node `$('NodeName').first()` expressions fail with `{error: "invalid syntax"}` inside a SplitInBatches iteration body. This is swallowed silently if `onError: continueRegularOutput` is set. The node outputs the error object as a normal item and execution continues with corrupted data — no visible error. Rule #32. The fix requires a Set node (typeVersion 3.4) BEFORE the SplitInBatches node that bakes all needed cross-loop values into each item. Inside the loop, reference `$json.fieldName`. This burned Workflow H tester round 4 (2026-05-03). **Lesson: Any data that a loop body needs from outside the loop must be baked into items before the loop starts — never referenced by cross-node expression inside the loop.**

### 9. The script/reimport harness eliminates a full class of manual errors

Before `scripts/n8n-reimport.sh` and `scripts/n8n-debug.sh` existed (commit `d7c43b6`, 2026-05-01), the workflow import cycle required: manually finding the old workflow in the n8n UI, deleting it, copy-pasting JSON, activating, then using the n8n UI execution inspector to diagnose failures. The UI execution inspector also has the known bug that `runData` is empty for `includeData=true` REST responses in 2.x. The debug script bypasses this by querying the DB directly. **Lesson: Investment in tooling that automates the import/debug cycle pays back on the very first bug after the harness exists. The human factors of manual UI copy-paste are a significant source of import errors.**

### 10. OpenAI is not reliably accessible from Ghana — Groq Whisper is the drop-in replacement

Two billing failures on a Ghanaian-issued card (2026-04-27 and 2026-04-28, ADR-0006) blocked Workflow A's voice-note path. Groq uses the same OpenAI-compatible API wire shape (`POST .../openai/v1/audio/transcriptions`, same multipart fields, same `{"text": "..."}` response) — the integration required only an env-var swap. Groq's free tier (480 audio-min/day) covers production volume with ~95% headroom at forecast scale. Additionally, `verbose_json` from Groq returns per-segment `avg_logprob` and `no_speech_prob` — confidence gate primitives that OpenAI's `gpt-4o-mini-transcribe` does not return. **Lesson: Ghana-market infrastructure decisions (payment processing, API access) differ materially from US/EU defaults. Verify card acceptance with each API provider before building a dependency on it. Always have an alternative in the design.**

---

*Document derived from: CLAUDE.md, `.claude/rules/n8n-workflows.md`, `.claude/rules/whatsapp-templates.md`, `.claude/memory/status.md`, `plans/active-plan.md`, `plans/tier-2-followups.md`, ADRs 0001–0012, `n8n-workflows/communications/a-communications-NOTES.md`, `scripts/patch-workflow-ids.sh`, `scripts/n8n-reimport.sh`, `scripts/n8n-debug.sh`, `infrastructure/docker-compose.yml`, `database/migrations/V001__create_bookings_core.sql`, `database/migrations/V008__screening_inbox.sql`, and git log `f811dd6`..`de84cfc`.*
