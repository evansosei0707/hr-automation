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

### T2-6. Pidgin transcription quality sanity-check (Groq Whisper)

- **Description:** The Groq Whisper voucher uses an espeak-ng-synthesised English fixture, which proves the wire shape but not transcript quality on real Ghanaian Pidgin. Before Workflow A ships voice-note auto-handling, record ~5–10 short Pidgin voice notes from the firm's Operations Lead (or any Ghanaian Pidgin speaker) and run them through `whisper-large-v3-turbo`. Document observed WER, common error patterns, and recommended starting confidence-gate thresholds (`avg_logprob`, `no_speech_prob`, `compression_ratio`) for `docs/03-integrations/groq-whisper.md`. **Not a voucher concern; a workflow-build precondition.**
- **Files affected:** new `reference/groq-whisper-pidgin-samples/` (WAV files) + a short markdown report referenced from `docs/03-integrations/groq-whisper.md`'s Confidence-gating section. The thresholds in that section are currently initial guesses; this work converts them to evidence-backed defaults.
- **Blocking:** No — but Workflow A's auto-handling of voice notes IS gated on this. So it's a "must do before Workflow A's Phase-2 implementation" item, not a "must do before Phase 4 close."
- **Target window:** **Pre-Workflow-A build** (Week 2 or 3). User noted at Phase 4 dispatch (2026-04-28): "I'll record a real Ghanaian Pidgin sample later for a quality sanity check before we ship Workflow A."
- **Owner:** HRA Project Lead (audio recording) + workflow-builder (run + write up).

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
