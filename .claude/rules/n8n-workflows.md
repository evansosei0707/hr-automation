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
   - Acquire: `SET conv:{candidateId} {executionId} NX PX 60000`. Branch on failure → enqueue retry.
   - Heartbeat: Lua `PEXPIRE` CAS, scheduled every 15s while the workflow is holding the lock.
   - Release: Lua `DEL` CAS, run in both the success path and the error path.

5. **Dedupe on inbound webhooks:**
   - First node after the Webhook is a Redis SETNX on the external event ID with 24h TTL.
   - If key already exists → return 200 and exit.

6. **Claude calls** go through a subflow (reusable node group), not ad-hoc HTTP Request nodes. The subflow handles model routing, budget gating, and `ai_call_log` writes.

7. **Outbound WhatsApp sends** also go through a subflow that enforces the 24h service window and falls back to a template if free-form fails with error code 131047.

8. **Node naming:** human-readable, describes the action. "Fetch Candidate by Phone" ✓, "HTTP Request 4" ✗.

9. **Workflow tags:** every workflow carries tags `hr-automation`, its letter (`workflow-a` through `workflow-h`), and `version-Nmm` as a pointer to the spec version. Tags are a weak form of version linkage but help when debugging.

10. **Credentials in JSON exports:** NEVER committed. The export process in `n8n-workflows/README.md` uses n8n's export-without-credentials option; if the JSON contains a credential field with a non-empty value, the pre-commit hook blocks the commit.

11. **`ReviewTask.subject` polymorphic invariant.** `ReviewTask` uses two optional `MANY_TO_ONE` fields — `subjectCandidate` and `subjectApplication` — instead of a single MORPH_RELATION (see ADR-0005). On every write path that creates or updates a `ReviewTask`, the workflow MUST assert exactly one of those two fields is set: never both, never neither. The DB does not enforce this; n8n is the only line of defence. Read paths must defensively check both fields and treat "neither set" or "both set" as a data-integrity error → log to `workflow_errors` and skip.

## Before committing an n8n workflow

Run the validator:

```
./scripts/validate-n8n-workflow.sh n8n-workflows/<path>.json
```

If it fails, fix in the n8n UI and re-export. Do not hand-edit to bypass.
