# Workflow a0 — WhatsApp Webhook Handler (Phase 4 voucher) — Implementation Notes

**Workflow file:** `a0-whatsapp-webhook-handler.json`
**Authored:** 2026-04-28 (Phase 4)
**Spec sources:** `docs/03-integrations/whatsapp-cloud.md`, `docs/02-workflows/a-communications.md` step 0, `.claude/rules/n8n-workflows.md`

This is the smallest possible piece of Workflow A — it terminates at "we received Meta's webhook + verified the signature + logged it." No dedupe, no conv lock, no Claude routing, no outbound. Those land later when the full Workflow A is built.

## Pre-import setup (do this in the n8n UI BEFORE importing)

### 1. Create the Postgres credential

In n8n UI: `Settings → Credentials → New → Postgres`.

| Field | Value |
|---|---|
| Credential Name | `Bookings DB (n8n_bookings)` (must match exactly — workflow references by name) |
| Host | `bookings-db` (Docker service name; resolves on the internal network) |
| Database | from `BOOKINGS_DB_NAME` in `infrastructure/.env` (`bookings`) |
| User | from `BOOKINGS_DB_USER` (`n8n_bookings`) |
| Password | from `BOOKINGS_DB_PASSWORD` |
| Port | 5432 |
| SSL | disable |

Save. The workflow's Postgres nodes will re-bind to this credential by name on import.

### 2. Verify env vars are present

The workflow reads `$env.WHATSAPP_VERIFY_TOKEN` and `$env.WHATSAPP_APP_SECRET` directly. These must be set in the n8n container's environment — they are passed via `infrastructure/docker-compose.yml`'s n8n service environment block. Confirm by exec'ing into the container:

```bash
docker exec hr-n8n env | grep -E '^WHATSAPP_(VERIFY_TOKEN|APP_SECRET)='
```

You should see both lines. Values are not relevant for this check — just that both names exist.

**If they're not there:** the compose file does not currently propagate them to n8n. Add them to the `n8n` service environment block, recreate the container, then re-attempt. (This is a likely first-import gotcha; flag the operator to check.)

### 3. Import the workflow

In n8n UI: `Workflows → Import from File → select a0-whatsapp-webhook-handler.json`. n8n will re-bind credentials by name when it imports — you'll see the Postgres nodes pick up the credential automatically if step 1 was done correctly.

### 4. Activate

Toggle the workflow to **Active** in the top-right corner of the workflow editor. Until activated, the webhook URL responds 404.

---

## Synthetic test commands (after activation)

These hit the local Nginx → n8n path. The Phase 4 voucher script `scripts/voucher/whatsapp-webhook.sh` (forthcoming in the same commit series) bundles them.

### GET verify (echo challenge)

```bash
TOKEN=$(grep '^WHATSAPP_VERIFY_TOKEN=' infrastructure/.env | cut -d= -f2-)
curl -s -w "\nHTTP %{http_code}\n" \
  "http://localhost/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=${TOKEN}&hub.challenge=test_challenge_42"
```

Expected:
```
test_challenge_42
HTTP 200
```

### GET verify with WRONG token (expect 403)

```bash
curl -s -w "\nHTTP %{http_code}\n" \
  "http://localhost/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=test_challenge_42"
```

Expected:
```
Forbidden
HTTP 403
```

### POST with valid HMAC (logs to event_log)

```bash
SECRET=$(grep '^WHATSAPP_APP_SECRET=' infrastructure/.env | cut -d= -f2-)
BODY='{"object":"whatsapp_business_account","entry":[{"id":"test","changes":[{"value":{"messaging_product":"whatsapp","messages":[{"from":"233244000001","text":{"body":"voucher synthetic test"}}]}}]}]}'
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')
curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "http://localhost/webhook/whatsapp" \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=${SIG}" \
  -d "$BODY"
```

Expected:
```
EVENT_RECEIVED
HTTP 200
```

Then verify the row landed:
```bash
docker exec hr-bookings-db psql -U n8n_bookings -d bookings \
  -c "SELECT level, event, LEFT(message, 60) FROM event_log WHERE workflow_name='workflow_a_inbound_whatsapp' ORDER BY ts DESC LIMIT 1"
```

### POST with INVALID HMAC (expect 403 + workflow_errors row)

```bash
curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "http://localhost/webhook/whatsapp" \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=0000000000000000000000000000000000000000000000000000000000000000" \
  -d '{"object":"whatsapp_business_account"}'
```

Expected:
```
Forbidden
HTTP 403
```

Then verify the error row:
```bash
docker exec hr-bookings-db psql -U n8n_bookings -d bookings \
  -c "SELECT node_name, LEFT(error_message, 60) FROM workflow_errors WHERE workflow_name='workflow_a_inbound_whatsapp' ORDER BY occurred_at DESC LIMIT 1"
```

---

## Caveats and known gotchas

### Raw body access in the Webhook node

The HMAC validation requires the **exact bytes Meta sent** — JSON re-serialisation breaks the signature. The `WhatsApp Webhook (POST)` node has `options.rawBody: true`. The Code node (`Validate HMAC`) tries multiple raw-body access paths because n8n's surface for raw body has shifted across versions:

1. `item.binary.data.data` (base64) — most common with `rawBody: true`
2. `item.json.body` as a string — fallback
3. `JSON.stringify(item.json.body)` — last-ditch fallback (will fail signature, surfaces as workflow_errors row)

If the FIRST run from a real Meta webhook produces an HMAC mismatch on a body that's known-valid (verified with the `openssl dgst` synthetic above using the same secret), the raw-body path is the most likely culprit. Open the n8n execution log on the failing run and look at how the body is structured in the input to `Validate HMAC` — the path that has the bytes is the one to use. Adjust the Code node's `if (item.binary && ...)` block accordingly.

### Method-routing via two webhook nodes

We use **two separate webhook nodes** (one GET, one POST, same path `whatsapp`) rather than a single dual-method webhook. Reason: the prior workflow-builder dispatch flagged that single-webhook dual-method support varies across n8n versions and `$request.method` expression resolution can be unreliable. Two nodes register at the same path and Meta's actual GET vs POST traffic gets routed cleanly to the correct branch. Trade-off: small visual noise in the workflow editor.

### Postgres node parameter binding

The three Postgres nodes use `executeQuery` with `options.queryReplacement` for parameter binding. This expression-substitution syntax may need UI-side review on first run — n8n's Postgres node v2.5 parameter format is finicky. If the first synthetic POST test fails at the `Log Inbound Event` node, open it in the n8n UI and use the visual parameter binding instead of `queryReplacement`.

### Error Trigger placement

Per `.claude/rules/n8n-workflows.md` rule #1, every workflow has a top-level Error Trigger. This one's connected to a Postgres INSERT into `workflow_errors`. It does NOT respond to the inbound webhook (the HTTP response branches handle their own response codes); it just records the error for Workflow G's daily sweep.

### What this voucher does NOT do (deliberate scope)

- **No dedupe** on `wa_message_id` (Workflow A step 1 — comes later when full workflow lands)
- **No conversation lock** (step 2 — comes later)
- **No Claude routing** (steps 4-9 — comes later)
- **No outbound message** (no replies sent here)
- **No candidate creation in Twenty** (step 4 of full Workflow A)

This voucher proves: "we receive Meta's webhooks and we can verify their signature." That's the foundation everything else builds on.

---

## Open questions for the operator's UI review pass

1. **Postgres node parameter binding format** — verify `options.queryReplacement` works in n8n 1.85.0 or switch to UI-bound parameters.
2. **`webhookId` field values** — the JSON declares `webhookId: "a0-whatsapp-get"` and `"a0-whatsapp-post"`. n8n usually generates these on first activation. Pre-declared values may or may not be respected on import; if n8n complains, delete the `webhookId` field from each Webhook node and let n8n assign one.
3. **Tag re-creation** — n8n imports tags by name; if the destination instance doesn't have these tag names yet, n8n auto-creates them. No action needed.

---

## After voucher passes — what to do next

1. Run `./scripts/voucher/whatsapp-webhook.sh` (covers the synthetic GET + POST + invalid-POST suite end-to-end with assertions).
2. Update Meta's WhatsApp webhook config: paste the `WHATSAPP_VERIFY_TOKEN` value into Meta's "Verify Token" field, set callback URL to `https://<ngrok-url>/webhook/whatsapp`, click Verify and Save. Meta hits our GET handshake; on success, the page shows "Webhook subscribed."
3. From a real phone, send a WhatsApp message to the test number. Watch n8n's execution log + `event_log` for the inbound row.
4. Commit the workflow JSON + NOTES + voucher script.

---

## Build history — issues surfaced during the Phase 4 voucher iteration

Captured here for the next workflow author. Each was a real-world quirk; each is now codified in `.claude/rules/n8n-workflows.md` so it doesn't bite again.

### 1. Code node — `crypto` is NOT a sandbox global

**Surfaced**: clicking Test setup on `Validate HMAC` produced `crypto is not defined [line 53]`.

n8n 1.85.0 with `N8N_RUNNERS_ENABLED=true` blocks `require()` of stdlib modules by default AND does not expose `crypto` as a global the way `Buffer` is exposed. Two layers of access control.

**Fix**: set `NODE_FUNCTION_ALLOW_BUILTIN=crypto` on the n8n service (compose env), then `require('crypto')` works. Documented in **rule #12**.

### 2. Postgres INSERT to `workflow_errors` missing `execution_id`

**Surfaced**: clicking Test setup on `Log POST Validation Failure` produced
`null value in column "execution_id" of relation "workflow_errors" violates not-null constraint`.

V001 has `execution_id TEXT NOT NULL`. The original Postgres node didn't bind it. n8n exposes it at runtime as `$execution.id` (normal flow) or `$json.execution.id` (Error Trigger downstream).

**Fix**: every Postgres node writing to project audit/log tables must bind every NOT NULL column from the table's V-migration. Cross-checked here: all three nodes now bind `execution_id`. Documented in **rule #13**.

### 3. nginx single-file bind mount stalled after a host-side edit

**Surfaced**: ran `nginx -s reload` after editing `infrastructure/nginx/nginx.conf`; reload succeeded but the new `default_server` block was not in nginx's loaded config. `docker exec hr-nginx sha256sum /etc/nginx/nginx.conf` differed from the host file's sha256.

Root cause: single-file bind mounts (`./nginx/nginx.conf:/etc/nginx/nginx.conf`) bind to the host file's INODE. Atomic-write editors (write-to-temp-then-rename) create a NEW inode for the file. The container's mount still points at the deleted old inode and never sees subsequent edits.

**Fix**: `docker compose up -d --force-recreate --wait nginx` — fresh container = fresh inode resolution. NOT just `nginx -s reload`. Note: this is a Docker-on-WSL2 quirk; on bare Linux with a different storage driver the behaviour can differ.

**Tradeoff considered, not adopted**: bind-mounting the parent directory `./nginx/:/etc/nginx/conf.d/` instead of the single file avoids the inode trap (directory mounts re-resolve filenames on each access). For Phase 5+ if this bites again, switch to directory mounts; for now the recreate workaround is fine.

### 4. n8n's "Test setup" button is destructive against the DB

**Surfaced** (operator question, not a bug): "is there any way for n8n's Test setup button on a Postgres node to skip actual execution, or is 'Test' always destructive against the DB?"

Test setup is **always** destructive on Postgres nodes. INSERT inserts. UPDATE updates. n8n 1.85 has no built-in dry-run mode for the Postgres node. Workarounds (per-credential schema switching, transactional wrappers, comment-out-during-test) exist but are awkward. Pragmatically, audit/log table noise from Test setup is acceptable; row 27 in `workflow_errors` (the `null execution_id` row from issue #2 above) is the artefact of one such test and is left in place as legitimate diagnostic history.

**Tracked** as Phase 5 cross-cutting consideration if and when we want a real "dry run" mode for n8n Postgres nodes.
