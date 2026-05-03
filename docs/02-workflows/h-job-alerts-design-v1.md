# Workflow H — Job Alerts / Re-Engagement — Design Note v1

**Date:** 2026-05-03
**Author:** architect
**Status:** Draft — awaiting workflow-builder implementation

---

## 1. Trigger

**Decision (OQ-1):** Schedule Trigger polling every 5 minutes, querying Twenty GraphQL for
`findManyJobPostings(filter: { status: { eq: OPEN }, postedAt: { gte: windowStart } })`.

Rationale: Workflow G is not yet built. H must not block on G. A 5-min cron is self-contained
and meets the spec's "within 5 minutes" acceptance criterion. Dedup prevents double-sends across
overlapping windows (see §3, node 5).

Manual trigger path (spec: "back-fill old jobs") is deferred to v2 — the schema and node chain
are identical; it differs only in the trigger node.

---

## 2. Data sources

| Data | Source | How |
|---|---|---|
| New open job postings | Twenty GraphQL | `findManyJobPostings` with `status + postedAt` filter |
| Eligible applications | Twenty GraphQL | `findManyApplications` with nested candidate fields |
| Anti-spam state | bookings DB `candidate_facts.facts` JSONB | keys `last_reengaged_at`, `reengagement_count_ytd` |
| Processed-posting dedup | bookings DB `candidate_facts.facts` JSONB | key `h_processed_postings` (array of IDs) on a system row |
| Re-engagement replies | bookings DB `screening_inbox` | `trigger_kind = 're_engagement_reply'`, polled 2-min cron |

No new bookings-DB migration is needed. All state fits in existing JSONB columns or the existing
`screening_inbox` table (V008 + V011).

**OQ-2 resolution — candidate matching:** Two-phase approach.
Phase 1: Twenty GraphQL fetches Applications where `reEngagementEligible=true AND
createdAt > sixMonthsAgo AND jobPosting.category = newCategory`, with nested candidate fields
(consentStatus, lastActivityAt, dataRetentionPolicy, strengthTier, applications {status}).
Phase 2: Code node filters `consentStatus != GRANTED`, `dataRetentionPolicy = PENDING_DELETION`,
`lastActivityAt < 90dAgo`, busy-set statuses (interviewing/offered/placed), anti-spam state.
No bookings-DB join required for matching.

**OQ-3 resolution — anti-spam state:** Use `candidate_facts.facts` JSONB, keys
`last_reengaged_at` (ISO string) and `reengagement_count_ytd` (integer). Year-rollover logic:
if `last_reengaged_at` year != current year, reset `reengagement_count_ytd` to 0. Adequate for
v1 volume (≤20 sends per cron run). Flag as v2 candidate for a dedicated `re_engagement_log`
table if query patterns demand a full history join.

**OQ-4 resolution — busy candidate exclusion:** Handled in the same Code node as OQ-2 phase 2.
The initial Application query fetches nested `applications { status }` for each candidate, so
the busy check is zero-cost. No separate query or graph traversal needed.

---

## 3. Node flow

### Chain 1 — JobPosting scanner (5-min cron, ~16 nodes)

1. `Schedule Trigger` — every 5 min
2. `Compute Scan Window` — Code node: `windowStart = NOW() - 5 min`, `sixMonthsAgo`, `ninetyDaysAgo`, `seventyTwoHoursAgo`
3. `Query New Open JobPostings` — Twenty GraphQL `findManyJobPostings(filter: { status: { eq: OPEN }, postedAt: { gte: windowStart } })` → id, title, category, salaryMinGhs
4. `Any New Postings?` — IF: `$json.data.jobPostings.edges.length > 0` (check field not length — rule #28)
5. `Dedup Check` — Postgres read from `candidate_facts.facts` on system row (candidate_id = `'system'`) key `h_processed_postings`; Code node filters out already-processed posting IDs; `alwaysOutputData: true` at node root (rule #24)
6. `Any Unprocessed?` — IF on dedup result; uses `$json.unprocessed ?? ''` field check (rule #28)
7. `SplitInBatches` (1 at a time) over unprocessed postings
8. `Query Eligible Applications` — Twenty GraphQL `findManyApplications(filter: { reEngagementEligible: { eq: true }, createdAt: { gte: sixMonthsAgo }, jobPosting: { category: { eq: posting.category } } })` + nested candidate (consentStatus, lastActivityAt, dataRetentionPolicy, strengthTier, applications {status})
9. `Filter Candidates` — Code node: consent, lastActivityAt, dataRetentionPolicy, busy-check, anti-spam date/count, strengthTier sort DESC, limit 20, one-per-day invariant (if candidate already has a re-engagement send today, skip)
10. `SplitInBatches` (1 at a time) over filtered candidates
11. `Read Anti-Spam State` — Postgres read `candidate_facts.facts` for this candidate_id; `alwaysOutputData: true` at node root
12. `Anti-Spam Guard` — IF: last_reengaged_at within 14 days OR reengagement_count_ytd >= 4; on true → skip branch → merge; on false → continue
13. `Compose WA Message` — Execute Workflow → claude-call subflow (model: claude-haiku-4-5, max 120 tokens); prompt enforces: first name, previous role type + timeframe, new role title, YES/NO prompt, no client name, no salary, 2–4 sentences
14. `Create Application` — Twenty GraphQL `createApplication(data: { candidate: {connect: {id}}, jobPosting: {connect: {id}}, status: RE_ENGAGEMENT_OFFERED, reEngagedAt: NOW() })`
15. `Send WA Message` — Execute Workflow → wa-send subflow (templateName: re_engagement_v1; always a template since candidate is cold — invariant per CLAUDE.md)
16. `Update Anti-Spam State` — Postgres UPDATE `candidate_facts` SET `facts = facts || $updateJson` WHERE `twenty_candidate_id = $1`; use array-form queryReplacement (rule #18)
17. `Mark Posting Processed` — Postgres UPDATE system row's `h_processed_postings` array
18. `Log Run` — event_log INSERT (workflow_name, level=info, event=reengagement_batch_complete)

Error Trigger writes to `workflow_errors` on all exit paths (rule #1).

### Chain 2 — Reply handler (2-min cron, ~9 nodes)

1. `Schedule Trigger` — every 2 min
2. `Query Re-Engagement Replies` — Postgres: `SELECT ... FROM screening_inbox WHERE trigger_kind = 're_engagement_reply' AND processed_at IS NULL LIMIT 1 FOR UPDATE SKIP LOCKED`; `alwaysOutputData: true` at node root (rule #24)
3. `Row Claimed?` — IF: `$json.candidate_id ?? ''` not empty (rule #28)
4. `Fetch Open RE Application` — Twenty GraphQL `findManyApplications(filter: { candidate: { id: { eq: candidateId } }, status: { eq: RE_ENGAGEMENT_OFFERED } })`
5. `Parse Intent` — Code node: YES → 'accepted', NO/not_interested → 'declined', other → 'ambiguous'
6. Branch YES: `Advance to Accepted` (GraphQL updateApplication status=RE_ENGAGEMENT_ACCEPTED) + `Create ReviewTask` (kind=OTHER, note="fast_track_candidate — re-engagement YES", priority=HIGH) + `Send WA Ack via wa-send`
7. Branch NO: `Advance to Not Interested` (GraphQL updateApplication status=NOT_INTERESTED) + `Send WA Ack via wa-send`
8. Branch ambiguous: re-enqueue or log for human review
9. `Mark Row Processed` — Postgres UPDATE screening_inbox SET processed_at = NOW()

### Chain 3 — 72h timeout sweep (hourly cron, ~4 nodes)

1. `Schedule Trigger` — every hour
2. `Query Expired RE Offers` — Twenty GraphQL `findManyApplications(filter: { status: { eq: RE_ENGAGEMENT_OFFERED }, reEngagedAt: { lt: seventyTwoHoursAgo } })`; `alwaysOutputData: true`
3. `Any Expired?` — IF on field presence (rule #28)
4. `Advance to Withdrawn` — Twenty GraphQL `updateApplications` batch; no outbound WA message (spec: "don't chase")

---

## 4. OQ resolutions (summary)

| OQ | Resolution |
|---|---|
| OQ-1 Trigger | 5-min Schedule Trigger + dedup JSONB; no dependency on Workflow G |
| OQ-2 Matching | Two-phase: Twenty GraphQL for eligibility/category + Code node for consent/busy/anti-spam |
| OQ-3 Anti-spam state | `candidate_facts.facts` JSONB keys; no new migration |
| OQ-4 Busy exclusion | Same Code node as OQ-2 phase 2; no extra query |

---

## 5. Schema additions required

1. **Twenty schema (V017):** `Application.status` needs two new SELECT options:
   `RE_ENGAGEMENT_OFFERED` and `RE_ENGAGEMENT_ACCEPTED`. The spec also references
   `kind=fast_track_candidate` on ReviewTask, which does not exist in the current SELECT set
   (`LOW_CONFIDENCE_SCORE`, `VOICE_NOTE_MANUAL_REVIEW`, `COMPLIANCE_FLAG`, `WORKFLOW_ERROR`,
   `OTHER`). Recommend adding `FAST_TRACK_CANDIDATE` to ReviewTask.kind in V017 for clarity.
   Until V017 is applied, use `kind=OTHER` with a descriptive `resolution` text.

2. **No bookings-DB migration needed.** Anti-spam state fits in existing `candidate_facts.facts`.
   Dedup posting tracker uses the same table on a `system` row.

3. **Workflow A routing — T2-H-1 (pre-launch blocker):** Workflow A's `workflow_reply` branch
   currently routes to `blue_collar_reply` or `new_application`. It must also detect candidates
   with an open `RE_ENGAGEMENT_OFFERED` Application and enqueue with
   `trigger_kind='re_engagement_reply'` for Chain 2 above. This is the same pattern as
   `blue_collar_reply` detection (EXISTS subquery on Application status). Required before launch.

---

## 6. Pre-launch checklist

- [ ] V017 Twenty schema migration applied (`RE_ENGAGEMENT_OFFERED`, `RE_ENGAGEMENT_ACCEPTED`, `FAST_TRACK_CANDIDATE`)
- [ ] `re_engagement_v1` WhatsApp template approved in Meta Business Manager
- [ ] Workflow A routing updated for `re_engagement_reply` trigger_kind (T2-H-1)
- [ ] `h_processed_postings`, `last_reengaged_at`, `reengagement_count_ytd` JSONB keys documented in bookings-DB schema notes
- [ ] `patch-workflow-ids.sh` updated with Chain 1 Execute Workflow nodes (claude-call, wa-send) per rules #21 and #25
- [ ] All three chain files added to `patch-workflow-ids.sh` file list (rule #25)
- [ ] Container env vars: no new vars needed (ANTHROPIC_API_KEY, TWENTY_API_URL, WHATSAPP_* already mapped per rule #29)
- [ ] `candidate_facts` system row (`twenty_candidate_id = 'system'`) seeded or created on first run

---

## 7. Acceptance criteria (from spec)

- **Happy path:** JobPosting opens, 8 candidates match, 8 messages fire within 5 minutes. 3 reply YES within 24h, 2 reply NO, 3 don't reply. After 72h: 3 `RE_ENGAGEMENT_ACCEPTED` (ReviewTasks created), 2 `NOT_INTERESTED`, 3 `WITHDRAWN`.
- **Anti-spam cooldown:** candidate re-engaged 10 days ago — NOT contacted on next matching posting.
- **Busy candidate:** candidate has status `INTERVIEWING` on another posting — skipped.
- **Category mismatch:** Security Guard posting does not match Delivery Driver history — not contacted.
- **Personalisation:** message uses correct first name and describes the previous role type correctly.
- **Privacy:** message does not reveal previous client name.
