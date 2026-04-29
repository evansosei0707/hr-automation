# Operations — Runbook

"What do I do when X breaks?" Short procedures, numbered for direct reference from alerts.

## §0 — How to look at what's happening

Before any specific procedure below, the operator's first move is usually "what does the system currently say?". Two queries answer that without leaving the terminal — copy-paste straight into psql:

```bash
source infrastructure/.env
docker exec -it -e PGPASSWORD="$BOOKINGS_DB_PASSWORD" hr-bookings-db \
  psql -U "$BOOKINGS_DB_USER" -d "$BOOKINGS_DB_NAME"
```

```sql
-- 1. What's happened in the last hour
SELECT ts, workflow_name, level, event,
       LEFT(COALESCE(message, ''), 60) AS msg
FROM event_log
WHERE ts > NOW() - INTERVAL '1 hour'
ORDER BY ts DESC;

-- 2. Anything broken right now (unacknowledged)
SELECT id, occurred_at, workflow_name, node_name,
       LEFT(error_message, 70) AS err
FROM workflow_errors
WHERE acknowledged_at IS NULL
ORDER BY occurred_at DESC
LIMIT 20;
```

For deeper investigation — execution traces, throughput, AI cost, open incidents, acknowledging errors after action — see the **"Operational queries"** section in [`observability.md`](./observability.md#operational-queries--looking-at-whats-happening). Every query there is copy-pasteable and shipped with sample output from real data.

## §1 — n8n unreachable

**Symptom:** Orchestration alert `n8n_health_failed`, or no workflows executing.

1. Check service: `docker compose -f infrastructure/docker-compose.yml ps n8n`
2. If not running: `docker compose -f infrastructure/docker-compose.yml up -d n8n`
3. If running but unhealthy, check logs: `docker compose logs --tail=200 n8n`
4. Common cause: OOM kill. Resolve by restarting; investigate memory after.
5. If still unhealthy, rotate to backup VPS (§8) if business-impacting.

## §2 — Twenty CRM unreachable

**Symptom:** Orchestration alert `twenty_health_failed`, staff cannot log in.

1. Check service: `docker compose ps twenty twenty-db`
2. Check logs. If Twenty can't reach its DB, see §3.
3. If Twenty itself is crashing, check for a recent `docker compose pull` that pulled a broken image. Pin version in compose, redeploy.

## §3 — Postgres connection failures

**Symptom:** DB health check fails, or workflows throwing connection errors.

1. Check container: `docker compose ps`
2. Disk full? `df -h` — Postgres fails to write if <5% free.
3. Too many connections? `SELECT count(*) FROM pg_stat_activity;` — default limit is 100. If we're near it, something is leaking.
4. Restart, monitor.
5. If corrupted, restore from last night's backup (§8 procedure).

## §4 — Redis unreachable

**Symptom:** Alert `redis_ping_failed`. Candidate messages pile up unprocessed because no workflow can acquire its conversation lock.

1. `docker compose ps redis`
2. If down, `docker compose up -d redis`
3. Redis has no persistent state we need — locks are short-lived, dedupe keys are short-lived.
4. After recovery, Workflow A will process the backlog. Expect a spike in execution count.

## §5 — WhatsApp integration failing

**Symptom:** Alert `whatsapp_echo_failed`, or deliveries stuck.

1. Test Meta Graph API: `curl https://graph.facebook.com/v20.0/me -H "Authorization: Bearer $WHATSAPP_TOKEN"`
2. If 401: token expired or revoked. Regenerate in Meta Business Manager, update `.env`, restart n8n.
3. If 403: permissions issue. Check the app in Meta Business Manager.
4. Quality rating dropped below GREEN? Reduce outbound template volume for 24h. Review recent template deliveries for patterns triggering the drop (candidate block rates, unsolicited messages outside session window).
5. Phone number unregistered? Should not happen spontaneously. Re-verify in Meta Business Manager.

## §6 — Claude API errors

**Symptom:** Workflow errors citing Anthropic 429 / 500 / 529.

1. 429 rate limit: the SDK retries automatically. If persistent, we may be over our tier — check usage dashboard.
2. 529 overloaded: Anthropic outage. Check status.anthropic.com. The SDK retries; no action unless prolonged.
3. 401 auth: API key issue. Rotate key, update `.env`, restart n8n.
4. If Anthropic is down for > 30 min, optionally switch to failover (not implemented v1 — note for Phase 2).

## §7 — Workflow stuck or looping

**Symptom:** Same candidate keeps appearing in error logs; a workflow execution running for > 10 minutes.

1. n8n UI → Executions → find the stuck run. Stop manually.
2. Check the conversation lock: `redis-cli --scan --pattern "hra:conv:*"` and `GET` the specific key. If stale (> 5 min old), force delete: `DEL hra:conv:{candidateId}`. (Key prefix `hra:` per [ADR-0009](../05-decisions/ADR-0009-redis-namespace-strategy.md); `--scan` is preferred over `KEYS` to avoid blocking under load.)
3. Inspect `workflow_errors` for the candidate; the pattern tells us the actual bug.
4. Patch the workflow; redeploy. Do NOT bypass the lock in the patch.

## §8 — Full VPS failure (disaster recovery)

**Symptom:** VPS unreachable, provider confirms host failure.

1. Provision new VPS (Ubuntu 24.04, same or larger size) in same region.
2. `ssh-copy-id` + `git clone <repo>`.
3. Install Docker: follow `scripts/bootstrap.sh`.
4. Restore both DBs:
   ```
   ./scripts/restore-from-backup.sh --date=latest
   ```
5. Copy `.env` from password manager. Also grab any `secrets/` files (Google service account JSON).
6. `docker compose -f infrastructure/docker-compose.yml up -d`
7. Update DNS A records to new IP. TTL should already be low (300s); wait for propagation.
8. Verify:
   - Twenty login page loads.
   - n8n UI loads and workflows show as Active.
   - Synthetic WhatsApp echo test passes.
9. Announce recovery on the staff channel.

Target time: 60–90 minutes from step 1 to step 9.

## §9 — Suspected data breach

**Symptom:** Unauthorised access log entry, credential leak detected, suspicious outbound.

Containment:
1. Immediately rotate the suspected-compromised credential (Claude API key, Meta token, DB password).
2. Force-logout all Twenty sessions. Change the Operations Lead + CEO passwords.
3. Revoke any third-party app integrations you don't recognise.

Investigation:
4. Capture logs: `event_log` and `workflow_errors` for the suspect window. Preserve them.
5. Identify scope: how many candidates? What data categories?

Notification (clock starts at detection):
6. Within 4h: Operations Lead + CEO briefed.
7. Within 24h: preliminary report drafted.
8. Within 72h: DPC notification submitted using their prescribed form.
9. If risk to candidates is high: direct WhatsApp notification to affected candidates in plain language, within 72h.

Post-incident:
10. Root cause analysis. Add controls.
11. Write an ADR documenting the incident and the controls added.
12. Review with CEO.

## §10 — AI cost surge

**Symptom:** Alert `daily_ai_cost_exceeded_10usd`.

1. Check the `ai_call_log` table for the surge source: is it one candidate (possible prompt-injection attempt or bug), one workflow, or across the board?
2. If one candidate: investigate the conversation. If abusive / flooding, block the number at the WhatsApp level.
3. If one workflow: check for retry storms, loops, or an input that triggered an expensive path.
4. Enforce the daily halt (auto-triggered at $20). Investigate calmly.
5. Tune prompts or add rate limits. Never just raise the budget without understanding the cause.

## §11 — Candidate escalation (safety concern)

**Symptom:** A candidate's message suggests distress, threat, or urgent personal crisis.

1. The system has already routed the conversation to a `ReviewTask` with `kind=compliance_flag` and sent a gentle holding message. Do NOT treat this as an automation question.
2. Operations Lead reads the full conversation.
3. If a direct risk to the candidate's safety is indicated: provide relevant helpline numbers (the Operations Lead keeps a small reference card of Ghanaian crisis resources), pause further automated messaging.
4. Document the incident outcome in the ReviewTask.
5. This is a human moment. The system's job is to not make it worse.
