# Plan — Tier 2 follow-ups (post-Phase-2 housekeeping)

**Started:** 2026-04-26
**Status:** Active — items captured during the Phase 2 close (commits `a532774`..`7ae9083`).
**Owner:** flagged per item; surface during weekly gardening (`/weekly-gardening`).

## Why this exists

Code-reviewer's Phase 2 review (against commit series ending at `c90db9c`/`7ae9083`) surfaced items that are real but not blocking Phase 2's official close. Captured here so they don't drift into permanent backlog. Each item carries: description, files affected, blocking/not-blocking status, and target window. Reference from `.claude/memory/status.md` so weekly-gardening picks it up.

The big Tier 2 elevation (NUMERIC + RATING in audit's `STRING_DEFAULT_TYPES`) was already done as Tier 1.5 in commit `7ae9083` — not in this list.

---

## Items

### T2-1. Wire `audit-twenty-schema.py` as a git pre-commit hook

- **Description:** Currently the audit runs as a pre-apply check inside `scripts/apply-twenty-schema.sh`. An invalid migration file can be committed and only rejected at apply time. Wiring as a real pre-commit hook (`.claude/hooks/` or `.git/hooks/pre-commit`) prevents the bad JSON from landing in the first place.
- **Files affected:** new `.claude/hooks/pre-commit` (or `.git/hooks/pre-commit` install script in `scripts/`), possibly a `scripts/install-git-hooks.sh` so the hook installs from a tracked path on fresh clones.
- **Blocking:** No. Pre-apply integration is already verified (tester section K, 2026-04-26). This is belt + braces.
- **Target window:** **Week 0 close.** Should land before Phase 4 starts adding more migration files (V002, V003, etc.).
- **Owner:** workflow-builder or whichever agent is next in the migration-touching path.

### T2-2. Remove dead `sed '/^[[:space:]]*\/\//d'` in apply script

- **Description:** Two `sed` invocations in `scripts/apply-twenty-schema.sh` (~lines 187, 335 in the current file) strip JSON `//` comments before `jq` parses each migration. Originally written when V001 carried readability comments (resolved in commit `6f83125`). The pre-apply audit (commit `37e7934`) now rejects any JSON with comments at parse time, so a file that reaches the apply loop is guaranteed comment-free. Both `sed` calls are unreachable defensive code.
- **Files affected:** `scripts/apply-twenty-schema.sh` (delete two `sed` lines + adjacent comments).
- **Blocking:** No. Dead code, not a bug.
- **Target window:** **Post-Week-0.** Whoever next touches the apply script for any reason can lump this in. Low urgency.
- **Owner:** code-reviewer or workflow-builder, whoever's next.

### T2-3. Annotate stale items in `IMPLEMENTATION_NOTES.md`

- **Description:** Several decisions/gotchas/open-questions in `twenty-schema/IMPLEMENTATION_NOTES.md` were authored at schema-designer time and have since been resolved. They should not be deleted (preserves the journey for future agents) but should be annotated `> RESOLVED 2026-04-26: <one-line note>` so a reader doesn't apply now-stale guidance. Specific items:
  - Decision 1 — JSON comments in V001: comments removed; audit now rejects them.
  - Gotcha 1 — JSON comments handled transparently: same.
  - Open Question 6 — `?includeStandardObjects=true` query param: removed in commit `54ca502`; current script uses bare path.
  - Decision 10 — operation count: actual breakdown is 10 createObject + 64 non-relation createField + 10 RELATION createField = 84. Note's earlier breakdown was 53/21 (corrected once); the original `~70 + 11 = ~91` was the original draft.
- **Files affected:** `twenty-schema/IMPLEMENTATION_NOTES.md`.
- **Blocking:** No. Doc hygiene.
- **Target window:** **Post-Week-0.** Natural fit for a weekly doc-gardener pass.
- **Owner:** doc-gardener.

### T2-4. README `applied_by` doc/code drift

- **Description:** `twenty-schema/README.md` describes `applied_by` as "the API key's role/user identifier or 'apply-twenty-schema.sh'". The actual script writes a timestamped run ID (e.g. `apply-20260426T145749-13125`). The value works for tracing; the doc just needs to match.
- **Files affected:** `twenty-schema/README.md` (one line).
- **Blocking:** No.
- **Target window:** **Post-Week-0.** Trivial; bundle with other doc updates.
- **Owner:** doc-gardener.

### T2-5. Extend audit-twenty-schema.py to validate composite-typed defaults

- **Description:** The audit currently validates string-typed defaults (TEXT/SELECT/RICH_TEXT/NUMERIC/RATING), bare numeric defaults (NUMBER), bare boolean defaults (BOOLEAN), and date defaults (DATE/DATE_TIME). It does NOT validate composite-typed defaults: CURRENCY (`{amountMicros, currencyCode}`), PHONES (`{primaryPhoneNumber, primaryPhoneCountryCode, additionalPhones}`), EMAILS, ADDRESS, LINKS, FULL_NAME — or array-typed defaults (ARRAY, MULTI_SELECT). V001 sets none of these, so no current bug; if a future migration sets a composite default with the wrong shape, Twenty will reject and the audit won't pre-empt it. Same argument as the NUMERIC/RATING elevation: load-bearing script with known-incomplete coverage.
- **Files affected:** `scripts/audit-twenty-schema.py` (add per-type composite validators with shape checks; cite `FieldMetadataDefaultValueMapping` in source).
- **Blocking:** No (yet — escalate to Tier 1 at the moment a workflow needs to add such a default).
- **Target window:** **Week 0 close** OR **at first need** — whichever comes first. If we add a CURRENCY default in V002/V003 for the bookings DB schema (unlikely; bookings DB defaults are SQL-side), or in a future Twenty migration, do this first.
- **Owner:** schema-designer or workflow-builder.

### T2-7. Production-grade backup script (cron + B2 + rotation + alerting)

- **Description:** Today's local drill (`scripts/backup-databases.sh`, 2026-04-29) proves the bones — three pg_dumps from our containers produce real, restorable artifacts. The production version takes the same shape and adds: cron schedule (nightly 02:00 Accra per spec), `rclone` sync to Backblaze B2 with server-side encryption, retention rotation matching the 14-daily / 8-weekly / 6-monthly policy in `backup-dr.md`, lockfile to prevent overlapping runs, paging on failure (Workflow G integration), and a sane `.env` config-path strategy for production deployments. Eventually replaces or supersedes the drill script; the drill version stays callable on-demand for local verification.
- **Files affected:** `scripts/backup-databases.sh` (rewrite or split into local-drill + production), new `scripts/restore-from-backup.sh` (referenced from runbook §8 but not yet written), cron entry in `infrastructure/`, B2 bucket setup notes.
- **Blocking:** No (for v1 readiness — single-VPS local backups are sufficient until launch). Yes (before any production go-live). The drill artifact at `scripts/backup-databases.sh` is the bones.
- **Target window:** **Week 4** per `backup-dr.md` ("workflow-builder will write it properly in Week 4"). Re-evaluate at the Week-3 close-out.
- **Owner:** workflow-builder.
- **Reference:** today's local drill at `scripts/backup-databases.sh` and the corrected inventory in `backup-dr.md` (post-2026-04-29 audit, including the n8n DB that the original spec missed).

### T2-8. Full backup-restore drill (live RTO measurement)

- **Description:** Today's drill verifies the dump path only — pg_dump produces non-empty, real-content artifacts. The full restore drill exercises the recovery path end-to-end and produces the live RTO number that runbook §8 currently estimates as "60–90 minutes for a practised operator."
- **Acceptance criteria:**
  1. Provision fresh Postgres containers (or a fresh Docker compose stack) on a clean filesystem.
  2. Restore Twenty + bookings + n8n DBs from the latest local-drill backup.
  3. Verify all 10 Twenty custom objects exist (Candidate, JobPosting, Application, Interview, SkillTag, CandidateSkillTag, Holiday, ReviewTask, SocialPost, WorkflowError) by querying Twenty's metadata API.
  4. Verify bookings DB application data: `slot`, `interviewer`, `event_log`, `workflow_errors`, `ai_call_log`, `system_incident`, `booking_event_log`, `twenty_schema_migrations` all present with row counts matching pre-backup state.
  5. Verify n8n: every workflow loads in the UI, every credential decrypts (n8n encryption key from `.env` must be the same key used when the dump was taken), execution history present.
  6. Run a synthetic Workflow A inbound message (real Meta-signed payload, HMAC-validated) end-to-end against the restored stack.
  7. Measure end-to-end recovery time from "fresh containers up" to "synthetic workflow green." Target: ≤ 90 minutes per runbook §8.
  8. If any acceptance gate fails, document the gap, update backup-dr.md and runbook §8, repeat the drill.
- **Files affected:** new `scripts/restore-from-backup.sh` (probably written by T2-7 path), updates to `backup-dr.md` and `runbook.md` §8 with live RTO, possible ADR if restore reveals a structural gap (e.g. n8n encryption-key handling).
- **Blocking:** No (before launch). Yes (before any compliance/security review claiming RPO=24h, RTO=2h).
- **Target window:** **First Monday of Week 2** (one full week after Week 0 closes — gives Workflow A v1 a few days to populate real execution history and real workflow definitions, so the drill exercises non-trivial state).
- **Owner:** tester (drill execution) + workflow-builder (restore script).
- **Reference:** runbook.md §8 (the disaster recovery procedure this drill validates).

### T2-6. Pidgin transcription quality sanity-check (Groq Whisper) — pre-launch catastrophic-check

- **Role in the two-path Pidgin quality strategy:** This item is the **pre-launch catastrophic-check** — a one-time pass to catch garbage transcripts (e.g., Whisper hallucinating English on Pidgin, or returning empty/silence-tagged output on intelligible audio) before they harm production decisions. The complementary path is ADR-0006's **post-launch calibration window** — ongoing quality dial-in across the first two weeks of real candidate traffic, where confidence-gate thresholds are tuned against actual transcripts. Both paths are intentional and serve different risk profiles: T2-6 catches "is the system working at all on Pidgin"; calibration tunes "how much can we trust each transcript."
- **Description:** The Groq Whisper voucher uses an espeak-ng-synthesised English fixture, which proves the wire shape but not transcript quality on real Ghanaian Pidgin. Before Workflow A ships voice-note auto-handling, record ~5–10 short Pidgin voice notes from the firm's Operations Lead (or any Ghanaian Pidgin speaker) and run them through `whisper-large-v3-turbo`. Document observed WER, common error patterns, and recommended starting confidence-gate thresholds (`avg_logprob`, `no_speech_prob`, `compression_ratio`) for `docs/03-integrations/groq-whisper.md`. **Not a voucher concern; a workflow-build precondition.**
- **Files affected:** new `reference/groq-whisper-pidgin-samples/` (WAV files) + a short markdown report referenced from `docs/03-integrations/groq-whisper.md`'s Confidence-gating section. The thresholds in that section are currently initial guesses; this work converts them to evidence-backed defaults.
- **Blocking:** No — but Workflow A's auto-handling of voice notes IS gated on this. So it's a "must do before Workflow A's Phase-2 implementation" item, not a "must do before Phase 4 close."
- **Target window:** **Pre-Workflow-A build** (Week 2 or 3). User noted at Phase 4 dispatch (2026-04-28): "I'll record a real Ghanaian Pidgin sample later for a quality sanity check before we ship Workflow A."
- **Owner:** HRA Project Lead (audio recording) + workflow-builder (run + write up).

### T2-9. Rules consolidation pass after Week 1 close

- **Description:** Phase 6 reconnaissance (2026-04-29) surfaced five rules-coverage gaps (RC1-RC5) — bug classes we caught during Phases 2-4 that aren't yet codified into `.claude/rules/`. Codify them as new rules during a single batched pass after Week 1's first workflow-builder dispatches have shipped (so the rule wording is grounded in additional real-world cases, not just the Phase 4 incidents).
  - **RC1 — Nginx default_server pattern.** Phase 4 hit the routing bug where webhooks landed at the wrong server block. Codify in a new `.claude/rules/nginx.md` (file doesn't exist yet) covering: default_server discipline, $fwd_proto inheritance, single-file bind-mount caveat (see RC2).
  - **RC2 — Docker single-file bind-mount + atomic-write inode quirk.** When you edit a bind-mounted single file and the editor does an atomic-write replace, the container holds the old inode; `nginx -s reload` reloads the stale config. Fix: `docker compose up -d --force-recreate <service>`. Either folded into the new nginx.md rule file or as a general infrastructure rule.
  - **RC3 — n8n Webhook node `options.rawBody` toggle.** Required for HMAC validation. Mentioned in `n8n-workflows/communications/a0-whatsapp-webhook-handler-NOTES.md` but not as a rule. Add as rule #15 (or fold into rule #12's surrounding commentary).
  - **RC4 — Twenty data-API resolver naming convention.** "No `One` infix on data API; `One` only appears on `/metadata` mutations." In ADR-0005 + schema doc but not in n8n rules. Add as a short rule near rule #6 (Claude calls go through subflow) so workflow-builder dispatches that construct Twenty mutations from scratch see it.
  - **RC5 — Twenty `RESERVED_METADATA_NAME_KEYWORDS`** awareness. ~30 reserved names; audit script catches programmatically; no rule mentions the existence of the list as a class. Future schema-designer dispatches without the heads-up could pick another reserved name (`event`, `task`, `note`) and reproduce Phase 2's R1 RED round.
- **Files affected:** new `.claude/rules/nginx.md` (or extension to existing rules); additions to `.claude/rules/n8n-workflows.md` (rules #15+); possibly `.claude/agents/schema-designer.md` for RC5 reserved-name awareness.
- **Blocking:** No. None of these are bugs today; they're future-proofing against re-occurrence.
- **Target window:** **After Week 1 close** — gives the rules consolidation a few more workflow-builder dispatches to ground against, and bundles the cleanup into one focused pass instead of trickling rule additions per-PR.
- **Owner:** code-reviewer or workflow-builder (whoever is closing out Week 1).
- **Reference:** Phase 6 reconnaissance findings §"Rules coverage gaps" (in conversation history).

### T2-10. observability.md aspirational references — annotate or remove

- **Description:** `docs/04-operations/observability.md` references `scripts/metrics-exporter.py` (line 31) and a `metrics_daily` aggregation table in the bookings DB. Neither exists; no V-migration creates the table. Reads as if the artifacts are present. Annotate as "Phase 2 / not yet shipped" with target Week, OR remove the section if Prometheus/metrics aren't in the v1 plan. Cleanup of an aspirational doc that crept in during the v3.1 blueprint round.
- **Files affected:** `docs/04-operations/observability.md` (Metrics section).
- **Blocking:** No. Cosmetic — but worth landing before any new operator joins and tries to find these artifacts.
- **Target window:** **Post-Week-0** docs-gardening pass.
- **Owner:** doc-gardener.
- **Reference:** Phase 6 reconnaissance §"Coherence gaps" item C2.

### T2-11. ghana-context.md holiday list drift from Google Calendar source-of-truth

- **Description:** `docs/00-foundations/ghana-context.md` lines 41-55 hold a static "for reference" 2026 holiday list. ADR-0003 makes Google Calendar the authoritative source; the static list disagrees with Google's actual response on a few entries (e.g. the file says "Dec 1 — Farmers' Day"; Google returned Dec 4 for 2026 — first Friday is the rule, the date drifts each year). Either annotate the static list as "illustrative only — Google Calendar is authoritative per ADR-0003" or prune to a minimal "see google-calendar.md" pointer.
- **Files affected:** `docs/00-foundations/ghana-context.md` Public holidays section.
- **Blocking:** No. The actual Holiday object in Twenty is sourced from Google per ADR-0003; the static list is informational.
- **Target window:** **Post-Week-0** docs-gardening pass, OR Week 4 batch with other docs cleanup.
- **Owner:** doc-gardener.
- **Reference:** Phase 6 reconnaissance §"Spec drift findings" item SD8.

### T2-12. Implement true conv-lock heartbeat (Lua PEXPIRE-CAS every 15s)

- **Description:** CLAUDE.md invariant #3 specifies a 60s TTL with a Lua CAS PEXPIRE heartbeat every 15s. Workflow A v1 uses a 180s flat TTL instead (no active heartbeat) because n8n 1.85.0 in regular execution mode has no mechanism for a background timer to fire independently while the main execution chain is blocked on a long HTTP call (Groq Whisper + Claude Sonnet can together take 10–40s). Options A (parallel branch) and B (self-webhook fire-and-forget) are non-viable in n8n 1.85.0 regular mode — see `a-communications-NOTES.md` §"Conv-lock implementation" for the full analysis. The v1 safety property is preserved by Lua CAS DEL on all six exit paths; 180s is the crash-scenario orphaned-lock window. Once n8n moves to queue mode or a task-runner-based parallel execution model, implement the proper heartbeat and restore invariant #3's 60s TTL.
- **Files affected:** `n8n-workflows/communications/a-communications.json` (change lock TTL back to 60000), new `n8n-workflows/communications/conv-lock-heartbeat.json`, update CLAUDE.md invariant #3 annotation, update `docs/02-workflows/a-communications-design-v1.md` §3.
- **Blocking:** No. The 180s flat TTL provides equivalent safety to 60s + heartbeat in crash scenarios; it merely increases the orphan-lock window from ~60s to ~180s.
- **Target window:** **Post-Week-1** — revisit when n8n execution model is better understood or if lock contention becomes a measurable problem in production. Natural trigger: switching n8n to `EXECUTIONS_MODE=queue` (see ADR-0009 §Claim 3).
- **Owner:** workflow-builder.
- **Reference:** Workflow A v1 build (2026-04-29); `docs/02-workflows/a-communications-design-v1.md` §3; `n8n-workflows/communications/a-communications-NOTES.md` §"Conv-lock implementation".

### T2-13. ReviewTask error path — rule #11 edge case when no candidateId

- **Description:** `ac_e005` "Create Workflow Error Review Task" sources `candidateId` from `$('Query Lock Value from Event Log').item.json.candidate_id`. When an error occurs before lock acquisition, this value is empty string, creating a ReviewTask with `subjectCandidate.id = ''` — violating rule #11 (neither-set). Fix: add an If node before ac_e005 checking if `candidate_id` is non-empty; skip ReviewTask when no subject available, or create a `system_incident` row instead.
- **Files affected:** `n8n-workflows/communications/a-communications.json` (new If node + bypass path).
- **Blocking:** No. The workflow_errors table row is always written regardless; the ReviewTask is an additional notification, not the primary audit record.
- **Target window:** Post-Week-1.
- **Owner:** workflow-builder.

### T2-14. Wrong template fallback in wa-send.json "Force Template — Window Expired"

- **Description:** When a caller passes no `templateName` and the service window has expired, `Force Template — Window Expired` defaults to `still_interested_10d` (a re-engagement template). Several callers (distress holding reply, opted-out ack, retype prompts) don't pass `templateName` and may call this subflow outside the 24h window on stale conversations. The `still_interested_10d` template would fire — semantically wrong and potentially violating the candidate's opt-out expectation. Fix: callers that should never use a template fallback should pass a sentinel (e.g. `templateName: 'NONE'`) and the subflow should error-exit rather than default to a re-engagement template when `templateName === 'NONE'`.
- **Files affected:** `n8n-workflows/communications/wa-send.json`, all callsites in `a-communications.json` and `dpa-handler.json`.
- **Blocking:** No. Affects only out-of-window edge cases. Opted-out candidates already have `consentStatus: REFUSED` blocking further processing.
- **Target window:** Pre-launch.
- **Owner:** workflow-builder.

### T2-15. Outbound messages not stored in conversation_message

- **Description:** Consent request templates, refusal acks, DPA acks, distress holding replies, and retype prompts are sent through the WA Send subflow but have no `conversation_message` INSERT. The service window calculation and DPA "show me all messages you sent me" audit both read from this table. These messages are invisible from the bookings DB; their audit trail exists only in n8n execution history.
- **Files affected:** `n8n-workflows/communications/a-communications.json` (add outbound INSERT at each callsite or inside wa-send.json subflow).
- **Blocking:** No for v1. DPA full-audit compliance requires this before handling real DATA requests.
- **Target window:** Pre-launch.
- **Owner:** workflow-builder.

### T2-16. Budget Gate workflow_a exemption — document or cap

- **Description:** `claude-call.json` Budget Gate has OR condition: under $10/day OR workflowName is `workflow_a_communications`. Workflow A is permanently exempt from the $10/day cap. A spam flood attacking the WhatsApp webhook could produce unbounded Claude API spend. Fix: either document the exemption with a separate higher cap for workflow_a, or add a per-conversation spend limit (e.g. max 3 Claude calls per candidateId per hour) enforced in the subflow.
- **Files affected:** `n8n-workflows/communications/claude-call.json`.
- **Blocking:** No. The `active: false` flag prevents real traffic until manual activation.
- **Target window:** Pre-launch.
- **Owner:** architect + workflow-builder.

### T2-17. ai_call_log prompt_excerpt — reduce from 200 to 40 chars

- **Description:** `claude-call.json` "Write AI Call Log" stores `LEFT(lastMessage.content, 200)` in `prompt_excerpt`. This captures up to 200 chars of candidate message text. CLAUDE.md style rules and DPA principles require minimising PII in operational logs. Reduce to 40 chars (sufficient to identify the prompt type for debugging) or replace with a non-PII descriptor.
- **Files affected:** `n8n-workflows/communications/claude-call.json` node cc000006.
- **Blocking:** No.
- **Target window:** Pre-launch.
- **Owner:** workflow-builder.

---

## How to use this plan

- Items move OUT of this list when they land in commits (cite the commit hash).
- New Tier 2 items: append to this list with the same shape; don't create a new file unless the list crosses ~10 items.
- Re-evaluate windows during weekly gardening — what was "post-Week-0" might become "now" if related work touches the same files.
- Escalate to Tier 1 (blocking) if any item starts costing more than ~15 min of tester time per occurrence.

## References

- Commit series that closed Phase 2: `a532774..7ae9083` (8 commits).
- Code-reviewer's review report (in conversation history; not a tracked file).
- `.claude/memory/decisions.md` 2026-04-26 entries for context on the four-rule local audit mirror.
