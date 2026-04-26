# Workflow E — Social Posting

Fan out a single job post to Facebook, Instagram, X, and Telegram. Free native APIs only.

## Purpose

Publishing a new role is currently manual and repetitive: copy-paste the same text four times into four different apps, watch them for engagement, reconcile results in a spreadsheet at the end of the week. This workflow reduces "approve a job post" to one button.

## Scope and non-scope

**In scope (launch):**
- Facebook Page posts (via Meta Graph API)
- Instagram Business account posts (via Meta Graph API)
- X posts (via X API v2 free tier)
- Telegram channel posts (via Telegram Bot API)

**Deferred:**
- LinkedIn — requires paid API approval that is not on our timeline. See `docs/05-decisions/ADR-0002-defer-linkedin.md`.

**Not used:**
- Blotato or any paid aggregator. See `docs/05-decisions/ADR-0001-drop-blotato.md`.

## Triggers

- `SocialPost` row in Twenty with `scheduledFor <= NOW()` and `publishedAt IS NULL`, polled every 5 minutes
- Immediate manual trigger from Twenty on approval

## Inputs

- `socialPostId` and the full `SocialPost` record
- Linked `JobPosting` (optional — posts can be general content, not just job postings)
- Configured accounts per platform (from `.env`, not from Twenty)

## Outputs

- A published post on each selected platform
- `SocialPost.publishedAt` set
- `SocialPost.externalPostId` populated with the platform's returned ID
- On failure: the `SocialPost.platform`-specific failure logged to `workflow_errors`; other platforms may still succeed (per-platform isolation)

## Step sequence

1. **Author.** Claude Sonnet drafts three versions tailored per platform: FB/IG (longer, emoji-friendly), X (280 chars), Telegram (markdown, can be longest). Twenty stores the draft; human approves.
2. **Approve.** Operations Lead reviews in Twenty, sets `status=approved`.
3. **Publish.** For each selected platform in parallel branches:
   - **Facebook:** `POST /{page-id}/feed` on Meta Graph with `message` + optional `link`.
   - **Instagram:** two-step — create media container with `POST /{ig-user-id}/media`, then publish with `POST /{ig-user-id}/media_publish`. Images only by default; video is deferred.
   - **X:** `POST https://api.x.com/2/tweets` with OAuth 2.0 user context.
   - **Telegram:** `POST https://api.telegram.org/bot{token}/sendMessage` with `chat_id` set to the channel.
4. **Record.** Store each platform's returned post ID and URL.
5. **Engagement sample.** Separate scheduled task — every 6h, 24h, 72h — pulls engagement metrics (likes, replies, reach) and stores a snapshot into `SocialPost.engagementSnapshot`.

## Invariants

- No post goes out without an explicit human approval in Twenty. No silent auto-publishing.
- Per-platform failure isolation. FB failing does not cancel the X post.
- Rate limits are respected per platform — see integration docs for exact limits.
- WhatsApp contact numbers must NOT appear in public posts by default (protection against scraping). A public-facing "reply-to" link goes to a WhatsApp business link with a pre-filled message, not a raw number.

## API limits we are designing around

- **X free tier:** 500 posts/month, 50/day. For a firm posting 5–10 jobs per week, this is comfortable. Alert when monthly quota crosses 70%.
- **Meta Graph:** Facebook Page posts — essentially unbounded for normal business use. Instagram publishing limit — 25 posts per 24 hours per account, generous.
- **Telegram Bot:** 30 messages per second to different chats, 1 per second to the same chat. Not a concern for our volume.

## Acceptance criteria

- **Happy path:** approved post publishes to all four platforms, returns four external post IDs, Twenty updated.
- **Partial failure:** X credentials expired, others succeed. Twenty shows three platforms with IDs and one with error; `workflow_errors` has the X failure.
- **Rate limit:** hitting X's daily cap returns a 429; workflow logs it, retries with backoff up to 3 times, then creates a `ReviewTask`.
- **Engagement sampling:** 24h after a post, engagement snapshot is present in Twenty.
- **Image handling:** JobPosting with an attached hero image publishes correctly to FB and IG; X falls back to text-only if no image fits; Telegram uses markdown-embedded image.
- **Unicode and Pidgin:** posts with non-ASCII characters render correctly on all platforms.

## Monitoring

- `workflow_e_published_total`, labelled by `platform` and `result`
- `workflow_e_engagement_sample_age_hours` gauge
- Per-platform API credential expiry — alert 14 days ahead

## Open questions

- Should Instagram Reels / video be in v1? Default: no, text + single image v1. Video later.
- Should we support cross-posting a Facebook post as an Instagram post via Meta's own cross-post feature rather than two separate API calls? Worth testing in Week 0. The cross-post feature may reduce our code but reduces our control.
