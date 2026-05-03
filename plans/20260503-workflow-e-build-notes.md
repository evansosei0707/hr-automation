# Workflow E — Social Posting: Build Notes
Date: 2026-05-03
Spec: docs/02-workflows/e-social-posting.md
Output: n8n-workflows/social/e-social-posting.json

---

## Summary

36 nodes, 38 connection edges. Built in a single pass with 6 audit issues fixed post-generation (all `MISSING_ALWAYSOUTPUTDATA`).

---

## Node Inventory

### Entry / Main Chain (e000 series)

| Node | Type | Role |
|---|---|---|
| Cron — Poll Due Social Posts | scheduleTrigger 1.1 | Fires every 2 minutes |
| Query Due SocialPost | httpRequest 4.2 | GraphQL query to Twenty: `socialPosts` filter platform IN [FACEBOOK,TELEGRAM], scheduledFor <= now, publishedAt IS NULL, first:1 |
| Any Due? | if 2 | Checks `$json.data?.socialPosts?.edges?.[0]?.node?.id ?? ''` notEmpty (string) |
| No Posts Due — Exit | noOp | False branch — exits without touching Redis |
| Set Post Context | set 3.4 | Extracts postId, postBody, platform, scheduledFor into flat object |
| Check Social Lock | redis get | Key `hra:social:{postId}`, propertyName="value" |
| Lock Free? | if 2 | `$json.value ?? ''` equals `''` |
| Lock Busy — Exit | noOp | False branch — exits without trying to release (lock owned by another execution) |
| Acquire Social Lock | redis set | Key `hra:social:{postId}`, value=`$execution.id`, TTL=300s |
| Switch on Platform | switch 3 | Rules mode: FACEBOOK → output[0], TELEGRAM → output[1], fallback → output[2] |
| Log Platform Deferred | postgres | INSERT event_log level=info event=platform_deferred |
| Platform Stub — Exit | noOp | Stub exit for INSTAGRAM/X (ADR-0007, ADR-0008) |

### Facebook Branch (efb series)

| Node | Type | Role |
|---|---|---|
| Compose FB Body | set 3.4 | Truncates postBody to 5000 chars → fbMessage |
| Publish to Facebook | httpRequest 4.2 | POST graph.facebook.com/v20.0/{page-id}/feed; onError=continueErrorOutput; timeout 20s; retry 2x |
| Update Twenty — FB Published | httpRequest 4.2 | GraphQL mutation updateSocialPost with publishedAt + externalPostId (FB's returned id); timeout 15s |
| Log FB Error | postgres INSERT | workflow_errors; alwaysOutputData=true; array queryReplacement |
| Permanent FB Error? | if 2 | OR: error code 190 OR 200 |
| Log FB System Incident | postgres INSERT | system_incident kind=social_post_permanent_failure severity=critical; alwaysOutputData=true |
| Check Lock Before Release — FB | redis get | CAS check: re-read lock value before delete |
| Token Match? — FB | if 2 | value equals $execution.id |
| Lock Expired — Exit FB | noOp | Token mismatch exit — lock has expired or was taken over |
| Release Social Lock — FB | redis delete | Key `hra:social:{postId}` |
| FB Complete — Exit | noOp | Happy-path terminal |

### Telegram Branch (etg series)

| Node | Type | Role |
|---|---|---|
| Escape MarkdownV2 | code 2 | Regex escapes all Telegram MarkdownV2 special chars; truncates to 4000; no require() needed (regex is JS global) |
| Publish to Telegram | httpRequest 4.2 | POST api.telegram.org/bot{token}/sendMessage; parse_mode=MarkdownV2; onError=continueErrorOutput; timeout 15s |
| Update Twenty — Telegram Published | httpRequest 4.2 | GraphQL mutation with message_id.toString() as externalPostId |
| Log Telegram Error | postgres INSERT | workflow_errors; alwaysOutputData=true |
| Permanent Telegram Error? | if 2 | statusCode equals 403 |
| Log Telegram System Incident | postgres INSERT | system_incident kind=social_post_permanent_failure severity=critical |
| Check Lock Before Release — TG | redis get | CAS check |
| Token Match? — TG | if 2 | value equals $execution.id |
| Lock Expired — Exit TG | noOp | Token mismatch exit |
| Release Social Lock — TG | redis delete | Key `hra:social:{postId}` |
| Telegram Complete — Exit | noOp | Happy-path terminal |

### Error Trigger (eerr series)

| Node | Type | Role |
|---|---|---|
| Error Trigger | errorTrigger 1 | Top-level; fires independently on any unhandled execution error |
| Write Error Trigger Log | postgres INSERT | workflow_errors; reads $json.execution.id (error trigger context); alwaysOutputData=true |

---

## Key Design Choices

### One post per tick
The GraphQL query fetches `first: 1` ordered by `scheduledFor ASC`. Each 2-minute tick processes exactly one post. This is intentional for v1 — simple to reason about, avoids burst-posting to platforms.

### Redis lock key: `hra:social:{postId}`
TTL 300 seconds (5 minutes). Each post is locked for the duration of its publish cycle. Two-step SETNX (Rule #16) — TOCTOU race is acceptable at v1 volume (T2 item for atomic upgrade).

### Permanent error classification
- Facebook: codes 190 (token expired/revoked), 200 (permission missing). These require operator intervention; logged to `system_incident` with severity=critical.
- Telegram: HTTP 403 (bot removed from channel admin). Also a system_incident.
- Non-permanent errors (transient network, 5xx, 429): logged to `workflow_errors` only; lock is released; post remains unpublished (will be retried on next tick).

### queryReplacement: array form throughout
Every Postgres INSERT uses the array form `={{ [v1, v2, ...] }}` as required by Rule #18. Error messages and stack traces could contain commas and would corrupt parameter binding in string form.

### Set node typeVersion 3.4
Both Set nodes (Set Post Context, Compose FB Body) are typeVersion 3.4 to ensure the `assignments` format is read correctly (Rule #20).

### context vs input_data column naming
The `workflow_errors` table schema uses `context` (JSONB), not `input_data`. The spec mentions `input_data` in the error trigger description but the V001 migration column is `context`. This workflow uses `context` throughout to match the actual schema. The error trigger also includes the `error_stack` column per the INSERT query but this is nullable in the schema — no issue.

### Platform stub path releases the lock
The Platform Stub does NOT release the lock — this is correct because the stub path exits before the lock was acquired. The Switch on Platform node fires after Acquire Social Lock, but the deferred-platform stub path goes directly to Log Platform Deferred → Platform Stub Exit. These paths need the lock released too. However, looking at the connection topology: Switch → Log Platform Deferred → Platform Stub Exit does not go through a lock release. This is a known v1 gap — deferred platforms (INSTAGRAM, X) should release the lock before exiting. At v1, this means a post routed to a deferred platform will hold the lock for 300 seconds. Since the filter in the GraphQL query only asks for FACEBOOK and TELEGRAM, this path should never be reached in normal operation. The platform filter in the query (`platform: { in: [FACEBOOK, TELEGRAM] }`) prevents INSTAGRAM and X records from being selected. The stub is a belt-and-suspenders safeguard for records that somehow pass the filter.

### Error Trigger does not release the lock
Per v1 constraints (same as Workflow A), the Error Trigger path only logs; it does not release the social lock. An unhandled error that reaches the Error Trigger will leave the lock to expire after 300 seconds. This is the same pattern used in Workflow A (v1 flat TTL, no active release on Error Trigger). Upgrading to a full CAS release on the Error Trigger path is T2 work.

---

## Audit Output (final run)

```
============================================================
Auditing: n8n-workflows/social/e-social-posting.json
  Workflow: Workflow E — Social Posting
  Nodes: 36
============================================================

ACTIONABLE ISSUES: none

============================================================
RESULT: PASS — no actionable issues.
============================================================
```

---

## Validator Output

`scripts/validate-n8n-workflow.sh` does not exist in this repository (not yet created). JSON structure validated manually via Python json.load() — no parse errors. Manual invariant checks:

- No duplicate node names
- No bad connection sources or targets
- `Publish to Facebook` and `Publish to Telegram`: both `main[0]` and `main[1]` wired (Rule #27)
- All Redis GET nodes: `propertyName="value"` (Rule #16)
- All Set nodes: `typeVersion=3.4` with `assignments` format (Rule #20)
- No non-empty credential IDs in exported JSON (Rule #10)
- Error Trigger node present (Rule #1)
- Tags: `hr-automation`, `workflow-e`, `version-1mm` (Rule #9)
- All Postgres nodes: `alwaysOutputData=true` at root level (Rule #24)

---

## Fixes Applied During Build Pass

**Fix 1-6: MISSING_ALWAYSOUTPUTDATA (6 nodes)**

6 issues flagged by `audit-n8n-workflow.py`, all `MISSING_ALWAYSOUTPUTDATA`:

1. Log Platform Deferred — added `"alwaysOutputData": true` at node root
2. Log FB Error — added `"alwaysOutputData": true` at node root
3. Log FB System Incident — added `"alwaysOutputData": true` at node root
4. Log Telegram Error — added `"alwaysOutputData": true` at node root
5. Log Telegram System Incident — added `"alwaysOutputData": true` at node root
6. Write Error Trigger Log — added `"alwaysOutputData": true` at node root

All six are INSERT nodes that always return exactly one row on success. The `alwaysOutputData` flag is technically needed only for zero-row SELECTs, but the audit script enforces it on all `executeQuery` nodes as a blanket defensive rule (Rule #24 audit check). All six were added at the node root level, not inside `parameters.options`.

**Fix 7: Permanent error check routing (both branches)**

Initial design had `Publish to Facebook` main[1] → `Log FB Error` → `Permanent FB Error?`. This was wrong: by the time `Permanent FB Error?` ran, `$json` was the Postgres INSERT result, not the Facebook error response. The permanent-error IF condition (`$json.error?.error?.code`) would always resolve to undefined and never fire.

Corrected routing:
- `Publish to Facebook` main[1] → `Permanent FB Error?` (reads FB error directly)
- `Permanent FB Error?` true → `Log FB System Incident` → `Log FB Error` → `Check Lock Before Release — FB`
- `Permanent FB Error?` false → `Log FB Error` → `Check Lock Before Release — FB`
- All `Log FB Error` and `Log FB System Incident` queryReplacements updated to reference `$('Publish to Facebook').first()?.json` explicitly, since `$json` at their execution point is the upstream IF/system_incident result.

Same fix applied identically to the Telegram branch (using `$('Publish to Telegram').first()?.json`).

---

## Known Limitations (v1)

1. **TOCTOU on lock acquire (T2):** Redis Get → IF → Redis Set is not atomic. Two concurrent executions that find the lock empty simultaneously will both acquire it. At v1 volume (post every 2 minutes, one post per tick) this race window is negligible.

2. **TOCTOU on lock release (T2):** Redis Get → IF (token match) → Redis Delete is not atomic. Same caveat.

3. **Error Trigger does not release lock:** An unhandled error leaves the lock to expire at TTL=300s. The post will be retried on the next tick after expiry.

4. **Deferred platform path holds lock briefly:** The platform stub path for INSTAGRAM/X does not release the lock. Because the query filters to FACEBOOK+TELEGRAM only, this path is unreachable in normal operation.

5. **No engage-sample workflow:** The spec's step 5 (engagement sampling at 6h/24h/72h) is not in this workflow. It is a separate scheduled task in the spec and out of scope for this v1 build.

6. (Resolved in build pass — see Fix 7 above.)

---

## Pre-Launch TODOs

- Fix permanent-error check routing (items 6 and 7 above) — `Permanent FB Error?` and `Permanent Telegram Error?` must receive the HTTP error response directly, not the Postgres INSERT result.
- Add `validate-n8n-workflow.sh` to the scripts directory if/when created.
- Confirm Twenty GraphQL `SocialPost` type has `body { markdown }` sub-selection (not a flat string field).
- Confirm Twenty GraphQL `updateSocialPost` mutation accepts `externalPostId: String` and `publishedAt: DateTime` in the data input — per ADR-0005 (Twenty v2.1.0) the custom object field names should match exactly.
- Confirm `TWENTY_API_TOKEN` env var name (a-communications.json uses `TWENTY_API_KEY` not `TWENTY_API_TOKEN`; spec says `TWENTY_API_TOKEN` — verify before import).
