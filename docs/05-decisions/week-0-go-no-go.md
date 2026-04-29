# Week 0 Go/No-Go Review

**Decision:** GO to Week 1.
**Date:** 2026-04-29
**Reviewer:** HRA Project Lead, in pair-mode with Claude Code.
**Scope:** Week 0 — Validation Gate (Phases 1–6). Output is a go / no-go for the start of Week 1 (Workflow A v1 build).

This document is the auditable record of the review. It captures what Week 0 verified, what was explicitly deferred and where, every risk that surfaced during reconnaissance with its disposition, the close-out work that landed, and the conditions under which the GO is granted.

---

## 1. What Week 0 verified

| Phase | Evidence | Primary artifact |
|---|---|---|
| 1 — Local bring-up | `6a4f302` + `42680aa` (NODE_ENV fix) | All 7 services healthy on WSL Docker Compose; 6 scaffolding gaps surfaced + fixed (`.claude/memory/decisions.md` 2026-04-26 §"Phase 1 scaffolding fixes"). |
| 2 — Twenty schema | `a532774..7ae9083` (8 commits, 4 RED rounds → GREEN) | 10 custom objects, 84 ops, tester 11/11 GREEN. Real journey codified in `scripts/audit-twenty-schema.py` — the structural antibody that prevents recurrence of the four enforcement-rule bug classes (`job` reserved-name, UPPER_SNAKE_CASE values, SQL-literal single-quoted defaults, auto-name TEXT). |
| 3 — Bookings concurrency | `8521fda` + `90cdd8a` | `scripts/test-bookings-concurrency.sh`: 10/10 PASS (5 offer-race + 5 claim-race). Both safety legs verified — partial unique index `uq_slot_no_double_claim` on the offer side + WHERE-clause guard on the claim side. Loser is rowcount=0 cleanly with no error / rollback / serialization noise. |
| 4 — External vouchers | `42680aa..65f8935` (9 commits) | 6 active green / 1 parked-superseded (ADR-0006) / 2 ADR-deferred (0007 IG, 0008 X). Real Ghana traffic verified end-to-end on the WhatsApp webhook (`event_log` row 13: +233 532 751 040, HMAC-validated). Three structural antibodies landed: `audit-twenty-schema.py` carry-over from Phase 2, n8n rules #11–#13, Nginx default_server pattern. |
| 5 — Cross-cutting | `6a7bf01..3256497` + `ac6f418` | conv-lock 20/20 PASS via `scripts/test-conv-lock.sh` (min PTTL=48196ms during 45s production-canary call); operational queries with real evidence in `observability.md` + runbook §0; backup drill three-DB green (twenty 245KB / bookings 7.8KB / n8n 42KB). |
| 6 — Go/no-go review | `5bd25c3..1980c4c` (this review's 4 commits) | Reconnaissance findings triaged: 16 items reviewed, 13 closed in commits during this review, 3 explicitly carried forward with target windows. See §3 below. |

The story across six phases is coherent. Every external dependency was verified or has a documented ADR-tracked deferral. The two cross-cutting invariants Workflow A relies on (Redis conv-lock + atomic-claim) hold under contention. The recovery path produces restorable artifacts. No critical-path question remains unresolved.

---

## 2. Known deferrals

Eleven items deliberately deferred from v1 / Week 0, each with a tracking artifact:

| Deferral | Reference | Re-trigger / window |
|---|---|---|
| LinkedIn integration | [ADR-0002](ADR-0002-defer-linkedin.md) | Re-evaluate after launch + 3 months. Manual posting via Twenty `SocialPost` draft until then. |
| Instagram integration | [ADR-0007](ADR-0007-defer-instagram.md) | Two re-trigger paths: different IG Business account in different Meta Business Manager, OR Workflow E v2 prioritization with paid alternative ADR. |
| X integration | [ADR-0008](ADR-0008-defer-x.md) | 30-day re-trigger at 2026-05-27. Approval-lands trigger anytime before that. |
| OpenAI Whisper transcription | [ADR-0006](ADR-0006-groq-whisper-pivot.md) — superseded | Replaced by Groq Whisper. Voucher artifacts kept as historical "what we tried." |
| Full restore drill (live RTO measurement) | [T2-8](../../plans/tier-2-followups.md#t2-8-full-backup-restore-drill-live-rto-measurement) | First Monday of Week 2. Produces `scripts/restore-from-backup.sh` and the live RTO number. |
| Production-grade backup script | [T2-7](../../plans/tier-2-followups.md#t2-7-production-grade-backup-script-cron--b2--rotation--alerting) | Week 4. Adds cron + B2 sync + rotation + paging on top of today's local-drill bones. |
| Real Pidgin transcription quality — pre-launch catastrophic-check | [T2-6](../../plans/tier-2-followups.md#t2-6-pidgin-transcription-quality-sanity-check-groq-whisper--pre-launch-catastrophic-check) | Pre-Workflow-A build (Week 2 or 3). Catches garbage transcripts before they reach production. |
| Real Pidgin transcription quality — post-launch calibration | [ADR-0006 §Trade-offs](ADR-0006-groq-whisper-pivot.md#consequences) | First two weeks post-launch. Threshold tuning against real candidate audio. |
| Redis isolation | [ADR-0009](ADR-0009-redis-namespace-strategy.md) | Resolved via `hra:` prefix mandate. Future scaling precondition (n8n queue mode) flagged in Claim 3. |
| Rules consolidation pass | [T2-9](../../plans/tier-2-followups.md#t2-9-rules-consolidation-pass-after-week-1-close) | After Week 1 close. RC1–RC5 codified in one batch. |
| observability.md aspirational refs | [T2-10](../../plans/tier-2-followups.md#t2-10-observabilitymd-aspirational-references--annotate-or-remove) | Post-Week-0 docs-gardening pass. |
| ghana-context.md holiday list drift | [T2-11](../../plans/tier-2-followups.md#t2-11-ghana-contextmd-holiday-list-drift-from-google-calendar-source-of-truth) | Post-Week-0 or Week 4 batch. Cosmetic — Google Calendar is authoritative per ADR-0003. |

Two items in the Pidgin row are intentional companions, not duplicates: T2-6 verifies "is the system working at all on Pidgin" before shipping; ADR-0006's calibration window tunes "how much can we trust each transcript" once shipped. Both paths land in their appropriate windows.

The cumulative pattern of three platform-onboarding deferrals (LinkedIn 0002, Instagram 0007, X 0008) was flagged in ADR-0008 §Consequences. Phase 6 explicitly accepts the structural pattern; revisit trigger is "channel-mix gap becomes a business problem during the first 60 days of operation."

---

## 3. Risks reviewed and disposition

Full disposition for every R / SD / C / RC item surfaced in Pass 1 reconnaissance. This table is the auditable record — every finding either closed by a commit during this review or explicitly carried forward with a tracking item.

| ID | Description | Disposition | Closed by |
|---|---|---|---|
| **R1** | Shared Redis with no key-prefix isolation | Closed | `8759b6c` — ADR-0009 + `hra:` prefix mandate; 5 spec edits + 2 unsolicited improvements (KEYS→--scan; dedupe key made literal) |
| **R2** | Twenty schema half-init recovery missing from runbook | Closed | `8117c29` — runbook §12 added with full procedure, source incident cited |
| **R3** | n8n credentials manual export status unknown | Closed | Operator-side. SQL dump + encryption key + restore procedure saved to password manager 2026-04-29 |
| **R4** | Pidgin transcription strategy double-pathed | Closed | `8117c29` — T2-6 reframed as pre-launch catastrophic-check; ADR-0006 §Trade-offs reframed as post-launch calibration. Both paths intentional, owners explicit |
| **R5** | Three-deferral pattern (LinkedIn + IG + X all blocked at platform-onboarding wall) | Carried forward | Accepted as structural; revisit trigger documented above. No new ADR — pattern is captured in ADR-0008 §Consequences |
| **SD1** | CLAUDE.md invariant #5 names superseded `gpt-4o-mini-transcribe` | Closed | `5bd25c3` — invariant rewritten to reference Groq `whisper-large-v3-turbo` per ADR-0006, with inline supersession trail |
| **SD2** | CLAUDE.md project-layout `twenty-sdk` reference | Closed | `8117c29` — replaced with "JSON migrations applied via apply-twenty-schema.sh per ADR-0005" |
| **SD3** | infrastructure.md image pins read as `:latest` | Closed | `8117c29` — table now states actual pins (`twentycrm/twenty:v2.1.0`, `n8nio/n8n:1.85.0`) |
| **SD4** | infrastructure.md "two Postgres instances" misses n8n DB | Closed | `8117c29` — Bookings Postgres row updated to acknowledge n8n DB co-residence |
| **SD5** | ADR-0005 "Open Q1" stale claim contradicted by commit `6f83125` | Closed | `8117c29` — ADR-0005 Resolution log appended (original body unchanged per ADR convention); two entries: Q1 closed, Redis deferral resolved by ADR-0009 |
| **SD6** | runbook §8 step 4 references nonexistent `restore-from-backup.sh` | Closed | `8117c29` — step 4 now acknowledges script doesn't yet exist (T2-8 produces it), points at `backup-dr.md` manual `pg_restore` procedure |
| **SD7** | infrastructure.md backup section duplicates backup-dr.md | Closed | `8117c29` — infrastructure.md backup reduced to one-line summary + pointer to authoritative spec |
| **SD8** | ghana-context.md static holiday list drifts from Google Calendar | Carried forward | T2-11 (`1980c4c`). Authoritative source is Google Calendar per ADR-0003; cosmetic cleanup |
| **C1** | Restore-drill cadence inconsistent across three docs | Closed | `8117c29` — backup-dr.md "Restore drills" rewritten to distinguish three activities (T2-8 baseline RTO / monthly production / ad-hoc DR); script names rationalised; runbook §8 + infrastructure.md aligned |
| **C2** | observability.md references aspirational `metrics-exporter.py` + `metrics_daily` | Carried forward | T2-10 (`1980c4c`). Annotate as Phase 2 or remove section |
| **RC1** | Nginx default_server pattern not codified as a rule | Carried forward | T2-9 (`1980c4c`). Phase 4 incident captured in conversation; rule wording deferred to post-Week-1 batch |
| **RC2** | Docker single-file bind-mount + atomic-write inode quirk | Carried forward | T2-9 (`1980c4c`). Same batch as RC1 |
| **RC3** | n8n Webhook node `options.rawBody` toggle | Carried forward | T2-9 (`1980c4c`). Mentioned in workflow notes; rule wording deferred |
| **RC4** | Twenty data-API resolver naming (no `One` infix) | Carried forward | T2-9 (`1980c4c`). In ADR-0005 + schema doc; rule cross-reference deferred |
| **RC5** | Twenty `RESERVED_METADATA_NAME_KEYWORDS` — class-of-keywords awareness | Carried forward | T2-9 (`1980c4c`). Audit script catches programmatically; rule mention deferred |

Counts: 20 findings reviewed → 13 closed during this review (10 in commits, 3 ADR-cross-referenced) → 7 carried forward with concrete tracking. None silently dropped, none deferred without an artifact.

---

## 4. Phase 6 close-out work summary

Four commits landed during this go/no-go review, in this order:

```
5bd25c3  docs(CLAUDE.md): invariant #5 — supersede gpt-4o-mini-transcribe with Groq whisper-large-v3-turbo per ADR-0006
8759b6c  docs: ADR-0009 — Redis namespace strategy + hra: prefix mandate (R1 closed)
8117c29  chore: Phase 6 close-out fix-ups — Pidgin framing + restore-drill reconciliation + ADR-0005 resolution + layout fixes + runbook §12
1980c4c  chore(plans): T2-9/T2-10/T2-11 added — rules consolidation + observability cleanup + holiday list drift
```

**`5bd25c3` — Item A (the project-constitution fix).** CLAUDE.md non-negotiable invariant #5 was naming a vendor that ADR-0006 had already retired. Project constitution is loaded every session; cannot carry stale vendor names. Five-minute edit, big trust signal.

**`8759b6c` — Item B (the namespace ADR).** R1 was a real risk that decisions.md and ADR-0005 had both deferred to "if observed." The 15-minute investigation produced source-cited evidence (`bullmq.driver.ts:80`, `message-queue.module-factory.ts:28-29`) plus empirical Redis state (2032 Twenty keys observed across `bull:`/`engine:`/`module:`; zero of our intended `conv:`/`dedupe:` exist). ADR-0009 documents the de facto separation, mandates the `hra:` prefix going forward, and identifies the n8n queue-mode hazard as a future-scaling precondition. Five spec files migrated forward-only (no production traffic to migrate). Two unsolicited improvements applied during the same edit: `KEYS "conv:*"` → `--scan --pattern "hra:conv:*"` in runbook §7 (KEYS blocks Redis under load — documented antipattern); dedupe key made literal in a-communications.md step 1 (was narrative-only).

**`8117c29` — Items 4–8 (the close-out fix-up batch).** Five small docs-coherence fixes, batched because they touched independent files: Pidgin two-path framing made explicit in T2-6 + ADR-0006; restore-drill cadence reconciled across `backup-dr.md` + `infrastructure.md` + `runbook.md` §8 + T2-8 (three distinct activities now named: T2-8 baseline RTO / monthly production / ad-hoc DR); ADR-0005 Resolution log appended for two post-acceptance closures; CLAUDE.md `twenty-sdk` reference + `infrastructure.md` image pins corrected; runbook §12 added with the Twenty `core` schema half-init recovery procedure (carried a "TODO: add to runbook" marker since Phase 1).

**`1980c4c` — T2-9/T2-10/T2-11 (the explicit deferrals).** Three Tier 2 items added with target windows so the carry-forwards are tracked, not lost: T2-9 rules consolidation after Week 1 close (RC1–RC5 batched); T2-10 observability.md aspirational refs cleanup; T2-11 ghana-context.md static holiday list drift.

Net change across the four commits: 14 files, +351 / -28 lines, 1 new ADR, 1 new runbook section, 3 new Tier 2 items, 0 net drift introduced (every fix tightens correspondence between docs and reality).

---

## 5. Decision: GO to Week 1

GO is granted with four explicit conditions, all met:

- [x] **All blocking items (Items A, B, C) closed before any Week 1 workflow-builder dispatch.** A in `5bd25c3`; B in `8759b6c`; C operator-side, confirmed 2026-04-29 (SQL dump + encryption key + restore procedure saved to password manager as a single secure note).
- [x] **Five close-out fix-up items landed.** Items 4–8 in `8117c29`. Disposition table §3 shows R2/R4/SD2/SD3/SD4/SD5/SD6/SD7/C1 all closed by this commit.
- [x] **Three Tier 2 items added with target windows.** T2-9/T2-10/T2-11 in `1980c4c`. Disposition table §3 shows SD8/C2/RC1–RC5 carried forward via these items.
- [x] **Operator confirmed n8n credentials exported to password manager.** R3 closed 2026-04-29.

No outstanding blockers. Week 1 may begin.

The decision is auditable: anyone reading this document can verify each condition by reading the cited commit, the cited file, or the operator's explicit confirmation in this review's record.

---

## 6. Week 1 immediate-next-step plan

The first Week 1 dispatch is an `architect` design pass for Workflow A v1, followed by `schema-designer` for V003 (`candidate_facts` table) per the "schema close to workflow" principle established in Phase 3 (V003 was deliberately deferred from Phase 3 so the table shape gets designed alongside the workflow that consumes it, not two weeks ahead of need).

### Workflow A v1 architectural inputs

The architect dispatch can build on these eight Week-0 artifacts without re-research:

1. **Phase 4 webhook handler** — `n8n-workflows/communications/a0-whatsapp-webhook-handler.json`, commit `9f4241d`. The verify (GET) + HMAC (POST) handlers are production-bound. Real Ghana traffic verified end-to-end. Workflow A's first nodes inherit this exactly; the workflow extends the POST branch with dedupe → conv-lock acquire → candidate resolve → ...
2. **Conv-lock pattern** — `scripts/test-conv-lock.sh` + ADR-0009, commit `6a7bf01` (test) + `8759b6c` (prefix). 20/20 PASS at production timing (60s TTL, 15s heartbeat, 45s synthetic call, min PTTL 48196ms). Lua heartbeat + CAS release scripts ready to embed; production keys use `hra:conv:{candidateId}` per ADR-0009.
3. **Audit script** — `scripts/audit-twenty-schema.py`, landed in the Phase 2 RED→GREEN arc (introduced in `37e7934`, extended in `7ae9083`). Prevents recurrence of the four Twenty enforcement-rule bug classes when Workflow A's design surfaces new schema needs (V003 included).
4. **WhatsApp env vars + Code-node sandbox** — all 5 `WHATSAPP_*` env vars are in the n8n container (per `infrastructure/docker-compose.yml`), and `NODE_FUNCTION_ALLOW_BUILTIN: "crypto"` is set so `require('crypto')` works in Code nodes for HMAC validation. No env churn needed for Workflow A's webhook path.
5. **Bookings DB credential** — bound in n8n (operator confirmed). `event_log`, `workflow_errors`, `ai_call_log`, `system_incident` all reachable from Workflow A's Postgres nodes without further setup.
6. **Twenty schema** — 10 custom objects applied + verified, including `Candidate` with the composite `whatsappNumber: PHONES` AND flat `whatsappNumberE164: TEXT` (unique, indexed) for O(1) lookups. Workflow A's "match inbound on existing Candidate" step is a single GraphQL query against the flat field.
7. **Groq Whisper voucher** — `scripts/voucher/groq-transcribe.sh`, commit `e0fd320`. Wire shape proven; English/Pidgin transcription path ready for Workflow A's voice-note branch. Pre-launch real-Pidgin quality check is T2-6 (gates the auto-handling shipment, not the workflow design).
8. **`ai_call_log` table** — V005 migration applied. Workflow A's Claude calls should write here from the very first run; cost-tracking starts as the workflow does.

### Recommended dispatch order for Week 1

1. **`architect`** — design pass for Workflow A v1. Inputs: `docs/02-workflows/a-communications.md` (the spec), the eight artifacts above, ADR-0009 (Redis prefix), rule #11–#14 in `.claude/rules/n8n-workflows.md`. Output: ADR or design note covering node-graph shape, candidate-resolution branching, consent-state-machine handling, error-branch wiring, and the V003 `candidate_facts` table shape (handed to schema-designer next).
2. **`schema-designer`** — V003 migration based on the architect's design note. Apply via `scripts/apply-twenty-schema.sh` (audit script gates the apply). Update `docs/01-data-model/twenty-crm-schema.md` if any new custom Twenty object is required (probably not; `candidate_facts` lives in the bookings DB).
3. **`workflow-builder`** — Workflow A v1 JSON, extending the Phase 4 webhook handler. Output: `n8n-workflows/communications/a-communications.json` plus a NOTES.md alongside.
4. **`tester`** — verify Workflow A v1 against acceptance criteria from `docs/02-workflows/a-communications.md`.
5. **`code-reviewer`** — review against invariants + rules + ADR-0009 prefix discipline.

Days 1–2 of Week 1 are realistically the architect dispatch + V003 design. Days 3–5 are the build + test + review loop.

---

## References

- `plans/active-plan.md` — Week 0 plan, Phases 1–6.
- `.claude/memory/status.md` — current build state.
- `.claude/memory/decisions.md` — chronological decision log.
- `plans/tier-2-followups.md` — every deferral with a target window.
- `docs/05-decisions/` — all 9 ADRs (0001–0009).
- `CLAUDE.md` — project constitution; six non-negotiable invariants.
- Phase 6 reconnaissance findings — in conversation history (2026-04-29 Pass 1).
- Phase 6 close-out commits: `5bd25c3`, `8759b6c`, `8117c29`, `1980c4c`.
