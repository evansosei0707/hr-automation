# Integration — X API (free tier)

Posting to X (Twitter) with the free API tier. Adequate for our volume; budget-aware.

## Access tier

- **Free tier** at time of writing: 500 posts / month, 50 / day, 17 requests per 15 min for writes.
- Requires OAuth 2.0 with PKCE, user-context token.
- App must be created in the X Developer Portal with `tweet.read`, `tweet.write`, `users.read` scopes.

## Posting

**Endpoint:** `POST https://api.x.com/2/tweets`

**Headers:** `Authorization: Bearer {user-access-token}` + `Content-Type: application/json`

**Body:**
```json
{ "text": "We're hiring a Frontend Developer in Accra ..." }
```

**Returns:** `{"data": {"id": "1234567890", "text": "..."}}`

Store `id` in `SocialPost.externalPostId`. The public URL is `https://x.com/{handle}/status/{id}`.

## Constraints

- **280 characters** for free tier. Strict. Claude Sonnet drafts the X-specific version and counts characters before posting.
- **Media:** free tier supports text-only. Images require media upload to `/2/media/upload` which is on Basic tier ($100/mo) — skip images on X for now.
- **Threads:** reply to a previous tweet with `reply.in_reply_to_tweet_id` — useful for job post + "apply here" follow-up. Counts as multiple posts against the daily cap.
- **Mentions and cashtags:** allowed but conservatively. No @everyone equivalent.

## Authentication flow

OAuth 2.0 PKCE, one-time setup:

1. Generate a code verifier + challenge.
2. Redirect the firm's admin to `https://x.com/i/oauth2/authorize?...` for approval.
3. Exchange the returned code for an access token + refresh token.
4. Store the refresh token in `.env`; use it to rotate the access token before expiry (~2h).

n8n has a built-in X OAuth2 credential type — use it; do not hand-roll.

## Rate limit handling

Use X's `x-rate-limit-remaining` header to back off preemptively. On HTTP 429:
- First hit: wait 60s, retry.
- Second hit: wait 300s, retry.
- Third: raise ReviewTask, do not retry automatically.

Weekly, the orchestration workflow checks our monthly usage against the 500 cap and alerts at 70%.

## Known pitfalls

- **Tokens expire:** refresh-token rotation is a moving part. If it fails, posts stop silently. Orchestration does a synthetic post-then-delete test nightly to catch this.
- **API endpoint drift:** X has renamed endpoints repeatedly (twitter.com → api.twitter.com → api.x.com). Pin to `api.x.com/2/*` explicitly.
- **Character count != length:** URLs are shortened to 23 chars, emoji can be multi-codepoint. Use X's own `parse` utility or a tested char-counter; do not use naive `string.length`.

## Configuration

```
X_CLIENT_ID=
X_CLIENT_SECRET=
X_REFRESH_TOKEN=
X_USER_ID=
```
