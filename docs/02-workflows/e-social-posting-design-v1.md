# Workflow E — Social Posting — Design v1

**Status:** Design ready for build.
**Scope:** v1 publishes approved `SocialPost` records to Facebook Page and Telegram channel. Instagram deferred per [ADR-0007](../05-decisions/ADR-0007-instagram-deferral.md). X deferred per [ADR-0008](../05-decisions/ADR-0008-x-deferral.md).
**Sources:** `docs/01-data-model/twenty-crm-schema.md` (SocialPost shape), `.claude/rules/n8n-workflows.md` (n8n conventions), ADR-0007, ADR-0008.

---

## 1. Trigger design

- **Trigger:** Cron, every 5 minutes.
- **Then:** Twenty GraphQL `findManySocialPosts` (HTTP Request node, NOT direct Postgres — invariant 1).
- **Filter:**
  ```graphql
  filter: {
    and: [
      { platform: { in: [FACEBOOK, TELEGRAM] } },
      { scheduledFor: { lte: $now } },
      { publishedAt: { is: NULL } }
    ]
  }
  orderBy: { scheduledFor: AscNullsLast }
  limit: 10
  ```
- **Fields fetched:** `id`, `body`, `platform`, `scheduledFor`, `jobPosting { id title }`.
- **Batch cap:** 10 records per tick. At 5-min cadence this is 120/hour, well above expected volume (≤ 5 jobs/day × 2 platforms = 10/day).
- **No `status` field is referenced.** SocialPost has no status — see OQ-1 resolution below.

## 2. Node flow (logical stages)

1. **Cron 5min** — kicks the workflow.
2. **Query Twenty for due SocialPosts** — HTTP Request, GraphQL, returns array.
3. **Any Due?** — IF node testing `$json.data.socialPosts.edges[0].node.id ?? '' !== ''` (rule #28 — field existence, not length).
4. **Split In Batches** — process one record at a time so per-record failures don't poison the batch.
5. **Switch on platform** — routes to FACEBOOK branch or TELEGRAM branch.
6. **FB branch:** Compose FB payload → HTTP Request to Graph API → IF Success → Update Twenty (publishedAt, externalPostId) | error branch → Classify Meta Error → Log/ReviewTask.
7. **Telegram branch:** Escape MarkdownV2 (Code node) → HTTP Request to Bot API → IF Success → Update Twenty | error branch → Classify Telegram Error → Log/ReviewTask.
8. **Error Trigger** — top-level, writes to `workflow_errors` (rule #1, rule #13).

## 3. Per-platform publish sequence

### 3.1 Facebook

- **Endpoint:** `POST https://graph.facebook.com/v20.0/{META_PAGE_ID}/feed`
- **Body:** `{ message, access_token: $env.META_PAGE_ACCESS_TOKEN }`. (No `link` in v1 — body text only. JobPosting URL embedding is v2.)
- **HTTP Request node config:**
  - timeout: 20s
  - retry: 2 retries, exponential backoff, only on 5xx and 429 (rule #2)
  - `"onError": "continueErrorOutput"` at node root (rule #27)
  - error branch wired in `connections` (rule #27)
- **Success:** parse `id` from response → write back to Twenty.
- **Body length cap:** 63,206 chars (Meta limit). Pre-flight Code node truncates to 5,000 chars + " […]" if longer.

### 3.2 Telegram

- **Endpoint:** `POST https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage`
- **Body:** `{ chat_id: $env.TELEGRAM_CHANNEL_ID, text: <escaped>, parse_mode: "MarkdownV2", disable_web_page_preview: true }`
- **MarkdownV2 escape (Code node, no require needed):**
  ```js
  const SPECIAL = /[_*\[\]()~`>#+\-=|{}.!\\]/g;
  const escaped = String($json.body).replace(SPECIAL, '\\$&');
  return [{ json: { ...$json, escapedBody: escaped } }];
  ```
- **HTTP Request node config:** same retry/timeout/onError shape as FB.
- **Body length cap:** 4,096 chars (Telegram limit). Pre-flight truncation in the same Code node that escapes.
- **Success:** parse `result.message_id` → store as string in `externalPostId`.

### 3.3 Instagram (stub)

Switch's IG branch routes to a NoOp + Log "IG deferred per ADR-0007" + write `workflow_errors` row with severity `info`. Should never fire in v1 because the GraphQL filter excludes `INSTAGRAM`; this is a defence-in-depth stub.

### 3.4 X (stub)

Same shape as IG. Cites ADR-0008.

## 4. Error handling

### Facebook (Meta) error codes

| Code | Meaning | v1 action |
|------|---------|-----------|
| 190 | Token expired/invalid | Alert (system_incident severity=critical), no retry, ReviewTask |
| 200 | Permission missing | Alert (severity=critical), no retry, ReviewTask |
| 4, 17, 32 | Rate limit / app-level throttle | n8n native retry handles 429; if surfaced as 200-with-error-body, requeue by leaving `publishedAt` null (next tick retries) |
| 1, 2 | Transient API/unknown | Log + retry next tick (publishedAt left null) |
| other | Unknown | `workflow_errors` row + ReviewTask on `subjectApplication: null, subjectCandidate: null` — N/A; instead log to `workflow_errors` only |

ReviewTask creation for code 190/200 only — these are operator-actionable. Other codes go to `workflow_errors` and let Workflow G's watchdog escalate if they recur.

### Telegram error classes

| HTTP | Meaning | v1 action |
|------|---------|-----------|
| 400 (`can't parse entities`) | MarkdownV2 escape miss | `workflow_errors` row + ReviewTask (operator must fix copy or escape function) |
| 403 (`bot is not a member`) | Bot removed from channel | system_incident severity=critical, alert |
| 429 | Rate limit, response includes `parameters.retry_after` | Wait then retry within same execution if retry_after ≤ 30s, else leave publishedAt null |
| 5xx | Telegram outage | n8n native retry; on final fail, leave publishedAt null for next tick |

## 5. Twenty updates

**On success (per-record):** GraphQL `updateSocialPost` mutation, set:
- `publishedAt`: ISO timestamp (now, Africa/Accra → UTC)
- `externalPostId`: FB `{page_id}_{post_id}` string OR Telegram `message_id` as string

**On failure:** **no Twenty mutation.** `publishedAt` stays NULL → next 5-min tick will reattempt UNLESS the failure was permanent (190, 200, 403). For permanent failures, the operator inspects the ReviewTask and either fixes credentials or sets `scheduledFor` to a far-future date to suppress retry.

> Note: this means a permanent-failure SocialPost will keep retrying every 5 min until the operator intervenes. v2 may add a `failedAttempts` counter and back-off; v1 relies on alerting via ReviewTask + system_incident.

## 6. Open question resolutions

- **OQ-1 (Trigger filter):** Resolved (c) — filter on `platform IN [FACEBOOK, TELEGRAM] AND scheduledFor <= NOW() AND publishedAt IS NULL`. No `status` field reference. SocialPost record existence + scheduledFor in past = implicit approval.
- **OQ-2 (Per-platform isolation):** Resolved by schema — `platform` is single-valued SELECT. Operator creates one record per platform; isolation is automatic.
- **OQ-3 (Draft authoring):** Resolved (c) for v1 — fully manual. Operator writes copy and creates SocialPost records in Twenty UI. Claude-drafted variants deferred to Workflow E v2. Rationale: scope discipline; WhatsApp (Workflow A) is the critical channel.
- **OQ-4 (Engagement sampling):** Resolved — moved to Workflow G. Workflow E is event-driven (publish now); G is time-driven (sweep). 6h/24h/72h snapshots fit G's existing 5-min cron sweep model. Workflow E v1 includes a TODO comment but no implementation.

## 7. No migrations needed

- `SocialPost` already exists in Twenty per `twenty-crm-schema.md`.
- No new bookings DB tables required. `workflow_errors`, `event_log`, `system_incident` (V001) and `ai_call_log` (V005) already cover logging needs.
- Confirmed: **zero database migrations for Workflow E v1.**

## 8. Acceptance criteria

1. **Happy path:** Two SocialPost records (one FACEBOOK, one TELEGRAM) with `scheduledFor` 1 min in the past and `publishedAt` NULL → after one cron tick, both records have `publishedAt` set and `externalPostId` populated; both posts visible on the live channels.
2. **Partial failure:** FB token revoked, Telegram healthy → FB record stays unpublished and creates a ReviewTask + system_incident (severity=critical, code 190); Telegram record publishes successfully and updates Twenty.
3. **Rate-limit retry:** Mock Meta returning 429 once then 200 → HTTP Request node's native retry handles it; final state is published with no ReviewTask.
4. **Telegram MarkdownV2 escape:** SocialPost body containing `Salary: 5,000-7,500 GHS (negotiable). Apply!` publishes successfully (escape function handles `-`, `(`, `)`, `.`, `!`, `,`).

## 9. Environment variables required

Already set in `infrastructure/docker-compose.yml`; verify before build:
- `META_PAGE_ID`
- `META_PAGE_ACCESS_TOKEN` (long-lived page token)
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHANNEL_ID` (numeric, with leading `-100` for supergroups/channels)
- `TWENTY_API_URL`, `TWENTY_API_TOKEN`

`N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` already set (rule #17).

## 10. Out of scope for v1

- Claude-drafted post variants (deferred to E v2).
- Engagement snapshot sampling at 6h/24h/72h (lives in Workflow G).
- Instagram and X publishing (ADR-0007, ADR-0008).
- Image / media attachments — text-only in v1.
- Per-record back-off on permanent failure — relies on operator intervention.
- Link previews / UTM tagging on JobPosting URLs.
