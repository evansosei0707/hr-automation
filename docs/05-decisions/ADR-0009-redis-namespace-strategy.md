# ADR-0009: Redis namespace strategy — `hra:` prefix mandate, document Twenty's de facto separation

**Status:** Accepted
**Date:** 2026-04-29
**Deciders:** HRA Project Lead

## Context

Three tenants share the single Redis instance (`hr-redis`, `redis:7-alpine`) defined in `infrastructure/docker-compose.yml`:

1. **Twenty CRM** — uses Redis for BullMQ message queues, workspace cache (RBAC + ORM metadata + GraphQL operation cache), and workflow scheduler partitions.
2. **n8n** — uses Redis only when `EXECUTIONS_MODE=queue` (BullMQ-driven scaling). **Currently in `regular` mode (default), so n8n writes nothing to Redis.**
3. **Our app** (HRA workflows + helpers) — needs Redis for conversation locks (CLAUDE.md non-negotiable invariant #3), inbound-webhook dedupe markers (rule #5 of `.claude/rules/n8n-workflows.md`), and any future short-lived state.

Phase 1's `decisions.md` (2026-04-26 §"Phase 1 scaffolding fixes") flagged this as an open question:

> "Open question deferred to ADR: shared-vs-dedicated Redis. Currently all three tenants (Twenty BullMQ, n8n BullMQ, our app's locks) share one Redis with no key-prefix isolation. Acceptable for Phase 1; needs an architect ADR before production if collisions are observed in workflow testing."

ADR-0005 §"Neutral / follow-up" carried the same item forward. Phase 6 reconnaissance (2026-04-29, R1) elevated it to a Week-1 precondition because workflow-builder dispatches start adding Redis traffic from our app in Week 1.

### Investigation (2026-04-29)

A 15-minute investigation produced concrete evidence rather than the conjecture the original deferral assumed.

**Twenty's Redis usage — source-confirmed:**

- `~/Sandbox/twenty/packages/twenty-server/src/engine/core-modules/message-queue/drivers/bullmq.driver.ts:80` — `new Queue(queueName, this.options)` passes only `connection` to BullMQ. **No custom prefix is set.** BullMQ's library default `'bull'` is used.
- `~/Sandbox/twenty/packages/twenty-server/src/engine/core-modules/message-queue/message-queue.module-factory.ts:28-29` — confirms only `connection: redisClientService.getQueueClient()` is propagated. No prefix-related option.
- `~/Sandbox/twenty/packages/twenty-server/src/engine/core-modules/message-queue/message-queue.constants.ts` — `MessageQueue` enum defines 17 queue names: `task-assigned-queue`, `messaging-queue`, `webhook-queue`, `cron-queue`, `email-queue`, `calendar-queue`, `contact-creation-queue`, `billing-queue`, `workspace-queue`, `entity-events-to-db-queue`, `workflow-queue`, `delayed-jobs-queue`, `delete-cascade-queue`, `logic-function-queue`, `trigger-queue`, `ai-queue`, `ai-stream-queue`. All become `bull:<queue-name>:*`.
- There is no `QUEUE_BULL_PREFIX`-style env var in Twenty's source. The prefix is fixed at the BullMQ library level, not configurable from outside.

**Twenty's Redis usage — empirically observed (2026-04-29, live `hr-redis`):**

```
prefix    keys     observed owner
------    ----     --------------
bull      1946     Twenty BullMQ — 17 queues, all under bull:<queue-name>:*
engine      83     Twenty workspace cache — engine:workspace:flat-maps:..., engine:workspace:orm:..., engine:workspace:graphql:operations:...
module       3     Twenty workflow scheduler partitions — module:workflow:workflow-run-enqueue:last-partition etc.
                   (other prefixes)
TOTAL     2032
```

Reproduce with: `docker exec hr-redis redis-cli --scan | awk -F: '{print $1}' | sort | uniq -c | sort -rn`

**n8n's Redis usage — empirically observed:**

- `EXECUTIONS_MODE` is not set in our compose → defaults to `regular` (single-process, no queue mode).
- `QUEUE_BULL_REDIS_HOST/PORT` are configured (compose lines 173-174) but inert in regular mode.
- `N8N_RUNNERS_ENABLED: "true"` enables the task runner subsystem, which uses local IPC, not Redis.
- **No n8n-specific prefix is observable in the live `hr-redis` keyspace** — n8n is genuinely not writing keys today.

**Our app's intended key shapes — spec evidence:**

- `conv:{candidateId}` — conversation lock (5 spec/rule references: `.claude/rules/n8n-workflows.md:17`, `docs/02-workflows/a-communications.md:38`, `docs/03-integrations/claude-api.md:42` and `:54`, `docs/04-operations/runbook.md:95`).
- `dedupe:{external_event_id}` — implied by rule #5 (text says "Redis SETNX on the external event ID"; no literal key shown).

The Phase 5 conv-lock test (`scripts/test-conv-lock.sh`) used `test:lock:conv-test:$$` (PID-scoped) — intentionally test-only and won't conflict with anything.

**Collision analysis as of 2026-04-29:**

- **Today: no collision.** Twenty owns `bull:` / `engine:` / `module:`. Our intended `conv:` and `dedupe:` would land in clean namespace. n8n doesn't touch Redis.
- **Latent hazard:** if n8n is ever switched to queue mode (`EXECUTIONS_MODE=queue`), it inherits BullMQ's default `bull:` prefix and would share namespace with Twenty's queue keys. Whether that becomes a real problem depends on whether queue *names* collide (different names = different `bull:<queueName>:*` subspaces, fine; same name = corruption). Worth flagging as a future-scaling precondition rather than a present problem.

## Decision

Three claims, accepted as one decision.

### Claim 1 — Document the de facto separation

Twenty's Redis namespace usage as of v2.1.0 is:

| Prefix | Owner | Source | Notes |
|---|---|---|---|
| `bull:*` | Twenty BullMQ | `bullmq.driver.ts:80` (uses BullMQ default) | 17 queue names enumerated in `message-queue.constants.ts` |
| `engine:*` | Twenty workspace cache | `engine/core-modules/redis-client/` (per-workspace ORM/RBAC/GraphQL cache) | Hashed by workspace ID |
| `module:*` | Twenty workflow scheduler | `engine/.../workflow-run-enqueue/` (cron-driven partition state) | Small footprint |

This separation is observable, reproducible (`docker exec hr-redis redis-cli --scan`), and stable across normal Twenty operation. Future Phase 6+ audits should re-run the empirical check; if Twenty introduces a new prefix in a future version, it gets added to the table above and any conflicting hra: usage is renamed.

### Claim 2 — Mandate `hra:` prefix for all our app's Redis keys

All Redis keys written by HRA workflows or helper scripts MUST use the `hra:` prefix with the flat shape `hra:<kind>:<id>`.

Concrete migrations from current spec:

| Old (spec-only; nothing in production yet) | New |
|---|---|
| `conv:{candidateId}` | `hra:conv:{candidateId}` |
| `dedupe:{external_event_id}` | `hra:dedupe:{external_event_id}` |

Future kinds follow the same `hra:<kind>:<id>` pattern. No category nesting (`hra:lock:conv:...`) — speculation about future taxonomy isn't worth the keystrokes. Migration A→B (flat → nested) is one rename if we ever discover we want it.

The Phase 5 conv-lock test prefix (`test:lock:conv-test:$$`) is exempt — it's test-scoped, ephemeral, intentionally distinct from production.

### Claim 3 — n8n queue-mode is a precondition for future scaling

If Workflow G or any Phase 2+ work ever moves n8n to `EXECUTIONS_MODE=queue`, the prefix-isolation question must be deliberately resolved BEFORE the change ships. Two viable resolutions:

1. **Set `QUEUE_BULL_PREFIX`** on n8n via env override (n8n exposes it; Twenty does not). This pushes n8n's keys to `bull-n8n:*` (or whatever value), keeping Twenty's `bull:*` intact.
2. **Split Twenty onto a dedicated Redis** instance. Higher infra cost, full isolation. Reach for this if `QUEUE_BULL_PREFIX` proves insufficient (e.g., shared coordination keys outside per-queue namespaces).

This claim is not an action today — n8n is in `regular` mode. It's a guard: any future ADR or compose change that flips `EXECUTIONS_MODE=queue` must reference this ADR and pick one of the two paths.

## Consequences

**Positive:**

- Eliminates a class of latent bug (silent key collisions across tenants on the shared Redis). Migration cost is small because no production traffic uses the bare prefixes yet — this is a forward-only mandate caught before Week 1's workflow-builder dispatches add real traffic.
- Makes the namespace boundary auditable. Any future operator can run the same `redis-cli --scan` enumeration and verify Twenty owns `bull:`/`engine:`/`module:` and we own `hra:`.
- The `hra:` prefix gives `KEYS hra:*` / `SCAN MATCH hra:*` a clean enumeration of everything our app wrote. Useful for runbook §7 stale-lock cleanup, debugging, and DR scenarios.
- Defends against future Twenty version drift — if Twenty v2.x ever introduces an `engine:conv:*` cache, our `hra:conv:*` is unaffected.

**Negative / trade-offs accepted:**

- Five spec/rule files require a one-line edit each (covered in the same commit). All future workflow specs and rules cite the `hra:` shape.
- One extra prefix segment per key (5 chars + colon = 6 bytes per key in Redis). Negligible at our scale (forecast ~50-200 active keys at peak).
- Documents Twenty's INTERNAL prefix names (`bull:`, `engine:`, `module:`) which could change between Twenty releases. If Twenty v3 renames `engine:` → `cache:`, the empirical-evidence section here goes stale; the audit procedure (re-run `redis-cli --scan` after any Twenty version bump) catches it.

**Neutral / follow-up:**

- The four spec edits and one new rule (#14 in `.claude/rules/n8n-workflows.md`) ship in the same commit as this ADR.
- `docs/00-foundations/infrastructure.md` Redis row gets a one-line cross-reference to this ADR.
- Phase 6 reconnaissance R1 closed by this ADR.
- Re-verify the empirical key counts after any Twenty version bump (T2 candidate: "Twenty version-bump checklist — re-confirm Redis prefix observations" — reach for this at the next minor or major Twenty version pin).

## Alternatives considered

- **Bare `conv:` and `dedupe:` (status quo, defer enforcement).** Rejected: works today by lucky non-overlap with Twenty; provides no defense against future Twenty additions or workflow-builder dispatches that pick obvious-but-conflicting prefixes (e.g., `module:`, `cache:`, `lock:`). The whole point of the ADR is to convert luck into discipline.
- **Three-segment hierarchy (`hra:lock:conv:{id}`, `hra:dedupe:event:{id}`).** Rejected: speculative taxonomy. We have two key kinds. Designing a category structure for two items is over-engineering; reach for it if the kind count grows past ~5-6.
- **Dedicated Redis instance for our app (split Twenty off entirely).** Rejected: doubles the Redis footprint for a problem that doesn't exist today. Reserve as the "Claim 3 escape hatch" if `QUEUE_BULL_PREFIX` ever proves insufficient.
- **Rely on Twenty never changing its prefixes.** Rejected: Twenty is on the v1.x → v2.x trajectory; further breaks are likely. The `hra:` prefix decouples our keys from Twenty's choices.
- **Use a Redis logical DB (`SELECT 1`, `SELECT 2`).** Rejected: BullMQ and most clients pin DB 0 implicitly; Twenty doesn't expose a DB selector; introduces a config divergence between tenants. Prefix-based separation is portable across all clients.

## References

- `infrastructure/docker-compose.yml` — `hr-redis` service definition (single shared instance).
- `~/Sandbox/twenty/packages/twenty-server/src/engine/core-modules/message-queue/drivers/bullmq.driver.ts:80` — Twenty's BullMQ Queue construction (no custom prefix).
- `~/Sandbox/twenty/packages/twenty-server/src/engine/core-modules/message-queue/message-queue.module-factory.ts:28-29` — Twenty's BullMQ options factory.
- `~/Sandbox/twenty/packages/twenty-server/src/engine/core-modules/message-queue/message-queue.constants.ts` — Twenty's 17 queue-name enum.
- `.claude/memory/decisions.md` 2026-04-26 §"Phase 1 scaffolding fixes" #7 — original deferral.
- ADR-0005 §"Neutral / follow-up" — carried-forward item.
- Phase 6 reconnaissance findings (2026-04-29) — R1 elevated this from "if observed" to "Week-1 precondition."
- CLAUDE.md non-negotiable invariant #3 — Redis conv-lock pattern (60s TTL + 15s heartbeat + Lua CAS release).
- `.claude/rules/n8n-workflows.md` rule #4 (lock pattern), rule #5 (dedupe), new rule #14 (added in this commit — `hra:` prefix mandate).
- `scripts/test-conv-lock.sh` — Phase 5 verification of the lock pattern's correctness; uses test-scoped prefix, exempt from this mandate.
- BullMQ docs: https://docs.bullmq.io/guide/queues — confirms `'bull'` is the library default prefix, configurable via `prefix` option (which Twenty does not set).
