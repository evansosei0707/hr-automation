# Integration — Meta Graph API (Facebook + Instagram)

Posting to the firm's Facebook Page and connected Instagram Business account. Free. Same underlying API as WhatsApp Cloud.

## Setup prerequisites (Week 0)

- Facebook Page owned by the firm's Meta Business account
- Instagram Business account linked to that Page
- App registered in Meta for Developers with `pages_manage_posts`, `pages_read_engagement`, `instagram_basic`, `instagram_content_publish` permissions
- Long-lived Page Access Token generated; never expires unless revoked

All credentials → `.env`.

## Facebook Page posting

**Endpoint:** `POST https://graph.facebook.com/v20.0/{page-id}/feed`

**Body:**
```json
{
  "message": "We're hiring a Frontend Developer! ...",
  "link": "https://wa.me/233XXXXXXXXX?text=Frontend%20role",
  "access_token": "{PAGE_ACCESS_TOKEN}"
}
```

**Returns:** `{"id": "{page-id}_{post-id}"}` — store the full `id` in `SocialPost.externalPostId`.

For an image, use `POST /{page-id}/photos` with `url` or multipart upload.

## Instagram publishing

Two-step, because Meta.

**Step 1 — create container:**
```
POST https://graph.facebook.com/v20.0/{ig-user-id}/media
body: {
  image_url: "https://...",
  caption: "...",
  access_token: "{PAGE_ACCESS_TOKEN}"
}
→ returns { "id": "<container_id>" }
```

**Step 2 — publish container:**
```
POST https://graph.facebook.com/v20.0/{ig-user-id}/media_publish
body: {
  creation_id: "<container_id>",
  access_token: "{PAGE_ACCESS_TOKEN}"
}
→ returns { "id": "<media_id>" }
```

Store `media_id` as `SocialPost.externalPostId`.

Note: Instagram images must be hosted at a public URL that Meta can fetch. For the firm's posts, host images on the firm's own website or a public bucket. Do not use signed S3 URLs that expire.

## Constraints and quirks

- **Captions:** max 2,200 characters. Keep posts much shorter.
- **Hashtags:** up to 30 on Instagram; 3–5 is ideal.
- **Image formats:** JPEG or PNG, min 320×320, max 8 MB. Aspect ratio between 4:5 and 1.91:1.
- **Publishing limit:** 25 IG posts per 24 hours per account.
- **Cross-post:** Meta's "share to Facebook" toggle exists for IG, but API-driven cross-posts are less reliable than two separate API calls. Two calls is our default.

## Engagement sampling

**Facebook post metrics:**
```
GET https://graph.facebook.com/v20.0/{post-id}/insights?metric=post_impressions,post_reactions_by_type_total,post_clicks
```

**Instagram media metrics:**
```
GET https://graph.facebook.com/v20.0/{media-id}/insights?metric=impressions,reach,likes,comments,saved
```

Store each snapshot in `SocialPost.engagementSnapshot` as a timestamped JSON entry. Sample at 6h, 24h, 72h.

## Error handling

Meta error codes worth catching specifically:
- `190` — access token invalid / expired → raise an alert, do not retry.
- `200` — permission missing → alert, do not retry.
- `10` — permission or feature unavailable → alert, manual review.
- `4` / `17` — rate limit → retry with exponential backoff.
- `100` — bad parameter → log payload, do not retry.

## Configuration

```
META_PAGE_ID=
META_PAGE_ACCESS_TOKEN=
META_IG_USER_ID=
```
