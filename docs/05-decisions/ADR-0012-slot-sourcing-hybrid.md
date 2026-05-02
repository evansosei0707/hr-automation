# ADR-0012: Workflow D Slot Sourcing — Hybrid Generator with Calendar Veto

**Status:** Accepted
**Date:** 2026-05-02
**Deciders:** architect subagent + Claude Code

## Context

Workflow D offers interview slots to shortlisted candidates and atomically books their choice. The `slot` table (V001) already supports the offer/claim lifecycle, but the spec (`docs/02-workflows/d-scheduling.md`) leaves open the question of how `slot` rows with `status='available'` come into existence in the first place. Three sourcing models exist:

1. **Manual seeding** — the Operations Lead enters concrete slot rows weekly via Twenty UI or a small admin tool.
2. **Live free/busy** — Workflow D queries Google Calendar `freebusy.query` synchronously during the offer path and constructs available slots on the fly.
3. **Hybrid** — operator defines weekly recurring availability windows; a daily Cron in Workflow D materialises concrete `slot` rows for the next 14 days; Google Calendar busy events veto generated rows before INSERT.

The HR firm has ~3 interviewers and targets ~15–30 interviews/week. The Google Calendar integration was vouched green in Phase 4 (`scripts/voucher/google-calendar.sh`).

CLAUDE.md invariants 1, 2 are not directly engaged. Invariant 3 (Redis lock) is unaffected since the generator runs without conv-locks (no candidate context). The Calendar dependency adds an external-API failure mode in whichever direction we resolve.

## Decision

Adopt the hybrid model. Add `interviewer_availability` (V012) to hold weekly recurring windows. Add `slot.generation_source` (V014) to distinguish operator-manual from generator-produced rows. Run the generator once daily at 05:00 Africa/Accra; on each run fetch `freebusy.query` per interviewer and skip slots that overlap busy blocks. Operator-manual rows are never deleted by the generator.

## Consequences

**Positive:**
- Offer-path latency stays low: claim and offer logic touch only the bookings DB, no synchronous external call.
- Operator's recurring weekly toil is eliminated — they edit `interviewer_availability` once per interviewer (or per change), not weekly.
- Calendar busy times are honoured automatically; interviewers do not need to mentally sync their personal commitments to a slot table.
- Manual operator overrides are preserved (operator can INSERT a one-off `generation_source='manual'` row; generator leaves it alone).
- Operator-defined windows decouple "intent to be available" (windows) from "concrete bookable units" (slot rows), which is a more honest data model.

**Negative / trade-offs accepted:**
- Two new tables (`interviewer_availability` and the `slot` ALTER) plus generator code increase Workflow D's surface area beyond the spec's implicit assumption.
- A failed `freebusy.query` defers slot generation by up to 24 hours for that interviewer; if the failure persists multiple days, slot inventory could run dry. Mitigation: T2-D-5 escalates 3-day failures to `system_incident`. v1 acceptance: the operator notices low slot inventory via `NO_SLOTS_AVAILABLE` ReviewTasks.
- Stale-busy: between daily runs, an interviewer who adds a personal event in Calendar is not reflected in slot availability until the next 05:00 run. Worst case: a candidate picks a slot that conflicts with the interviewer's just-added Calendar event. Mitigation: operator manually marks the slot `cancelled` and triggers reschedule (uncommon, low-cost recovery).
- One more daily Cron context to maintain; one more Google Calendar API dependency on a non-blocking path.

**Neutral / follow-up work:**
- T2-D-4: per-row `slot_minutes` rather than a fixed 45-minute increment.
- T2-D-5: repeated-failure escalation for `freebusy.query`.
- T2-D-11: cache `freebusy.query` results within a single generator run if multiple interviewers share a Calendar (rare).

## Alternatives considered

- **Option A — Manual seeding (rejected):** lowest implementation cost, highest predictability. Rejected because weekly slot seeding is recurring operational toil for an HR firm whose job is hiring, not calendar management. With ~3 interviewers × 5 days × ~8 slots/day = ~120 rows/week to manually create. Even with a UI helper, this is multiple hours/week of toil for no business reason.

- **Option B — Live free/busy on offer path (rejected):** simplest data model (no `slot` rows materialised in advance). Rejected because: (a) it adds a synchronous external API dependency to the offer-creation latency budget; (b) `freebusy.query` failures would block offer sends entirely instead of degrading gracefully; (c) the offer message lists 3 specific times — those times must be lock-able in advance, and the only safe lock primitive in this stack is the partial unique index on `slot`. Generating 3 ad-hoc rows per offer is functionally identical to the hybrid approach but pushes Calendar latency onto the candidate-facing path.

- **Option D — Calendar as the source of truth, no `slot` table at all (rejected):** would require Calendar's primitives to provide atomic claim. Calendar's API does not expose row-level locking or conditional create. The whole reason the bookings DB exists (per `docs/01-data-model/bookings-db.md` §"Why it exists") is that Calendar lacks the race-free claim primitive. Eliminating `slot` is incompatible with the project's atomic-claim invariant.

## References

- `docs/02-workflows/d-scheduling.md` — spec
- `docs/02-workflows/d-scheduling-design-v1.md` — full design (this ADR's decision in §1, §3)
- `docs/01-data-model/bookings-db.md` — slot table and atomic claim pattern
- `docs/03-integrations/google-calendar.md` — Calendar auth, freebusy, failure handling
- ADR-0011 — prior precedent for "introduce a dedicated bookings-DB table when a workflow needs structured per-entity state"
- CLAUDE.md invariants 1 (no direct Twenty DB writes) and 2 (no rollups/webhooks)
