# ADR-0011: Blue-Collar Screening — Dedicated State Table and Dual-Trigger Pattern

**Status:** Proposed
**Date:** 2026-05-02
**Deciders:** architect subagent + Claude Code

## Context

Workflow C (Blue-Collar Screening) is a multi-step conversational screening flow where a candidate answers up to ~6 questions over WhatsApp, one per session. Unlike Workflow B (white-collar), which is a single-pass CV parse, Workflow C must persist intermediate state (question index, accumulated answers) between executions that can be hours apart.

Two prior patterns exist in the codebase:

1. `candidate_facts.facts` JSONB (V003) — used by Workflow A for conversation context and by Workflow B for CV parse output. A single freeform blob per candidate.
2. `screening_inbox` (V008) — a hand-off queue row that is short-lived (claimed and processed within one execution).

Neither is a clean fit: stuffing multi-step Q&A state into `candidate_facts.facts` merges two distinct domains (CV data and Q&A progress) into one blob. The `screening_inbox` row is consumed per reply, not held open.

A second problem is triggering: Workflow B is triggered solely by Workflow A inserting into `screening_inbox`. But blue-collar Applications may be created directly by a human in Twenty CRM, with no inbound WhatsApp message. Workflow A only fires on an inbound message; it cannot enqueue a row for an Application created silently in Twenty.

## Decision

**Q1 (state):** Introduce a dedicated `blue_collar_screening` bookings-DB table (V009) to hold per-candidate Q&A session state. Do not extend `candidate_facts.facts`.

**Dual trigger (Q2a):** Workflow C runs two separate Cron contexts: (1) the existing `screening_inbox` poll pattern (60s), and (2) a new 5-minute poll of Twenty's GraphQL API that finds blue-collar Applications with no corresponding `blue_collar_screening` row and enqueues them. This is the first workflow in the project to use a Twenty CRM poll as a trigger path, justified by the need to handle human-created Applications without violating invariant #2 (no action-button webhooks).

**Screening scripts (Q4):** Scripts live in a `screening_scripts` bookings-DB table (V010), not hard-coded in the workflow JSON and not in Twenty CRM.

## Consequences

**Positive:**
- Clean domain separation: CV facts and Q&A state never share a JSONB blob.
- `question_index` and `status` are indexable columns — the 24h reminder sweep and 72h auto-withdraw sweep are simple range queries, not JSONB predicates.
- Human-created Applications are handled without a webhook (invariant #2 preserved).
- Script updates go live without a workflow redeploy.

**Negative / trade-offs accepted:**
- Two new migrations (V009, V010) must apply before Workflow C activates.
- A second Cron (5-minute Twenty poll) adds a small, constant GraphQL load — ~12 queries/hour against Twenty. Acceptable at v1 scale (up to 200 applications/day).
- The Twenty poll introduces a latency window of up to 5 minutes before a human-created Application enters screening. Acceptable: the candidate doesn't know they've been added yet.
- Scripts table requires seed data INSERT at deploy time (pre-launch blocker, not a code blocker).

**Neutral / follow-up work:**
- T2: add `shortlistThreshold` override field to Twenty `JobPosting` custom object so per-job thresholds can supersede the per-category default in `screening_scripts`.
- T2: Workflow A change to detect active `blue_collar_screening` rows and route replies with `trigger_kind = 'blue_collar_reply'`.

## Alternatives considered

- **Option A — `candidate_facts.facts` JSONB (existing table):** rejected. No new migration, but merges CV facts (Workflow B's domain) with Q&A state (Workflow C's domain) in one blob. Concurrent writes from B and C on the same candidate (possible for a candidate who previously had a CV) risk last-write-wins corruption. JSONB predicates on `question_index` are uglier than column indexes for the sweep queries.

- **Option C — Twenty `Application.screeningState` field (via Twenty schema migration):** rejected. Adding a field to Twenty for bookings-side operational state violates the spirit of invariant #1 (keeping workflow-owned data in the bookings DB). Requires a `twenty-schema` migration + apply step for data that is transient and workflow-internal. JSON stored in a Twenty TEXT field has no index support.

- **Option A for scripts (hard-coded in workflow JSON):** rejected. Changing a question prompt in a live 200-candidates/day system without a full workflow redeploy is required operational hygiene. Hard-coded scripts also cannot be versioned independently of the workflow build.

- **Option C for scripts (Twenty CRM `ScreeningScript` custom object):** rejected. No such object exists in the applied schema; creating it requires a Twenty schema migration plus an apply step. An extra GraphQL query per screening session for data that changes monthly is disproportionate overhead. Adds a Twenty API availability dependency to an already latency-sensitive loop.

- **Single-trigger only (no Twenty poll):** rejected. The spec's trigger list includes "New `Application` row with `JobPosting.collarType=blue`", not just "candidate sends WhatsApp message". The HR firm's operators create Applications directly in Twenty; a Twenty poll is the only pattern that handles this without violating invariant #2.

## References

- `docs/02-workflows/c-blue-collar.md` — spec (trigger list, state machine, invariants)
- `docs/02-workflows/c-blue-collar-design-v1.md` — full design note (this ADR's decisions implemented)
- `docs/02-workflows/b-white-collar-design-v1.md` — prior state-persistence decision (OQ-5: JSONB-only for B)
- `database/migrations/V003__candidate_conversation_tables.sql` — `candidate_facts` schema
- `database/migrations/V008__screening_inbox.sql` — `screening_inbox` schema
- CLAUDE.md invariant #2 — no action-button webhooks
