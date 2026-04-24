# Integration — WhatsApp Cloud API

Meta's first-party API for WhatsApp Business. The primary candidate-facing channel.

## Endpoint basics

- Base URL: `https://graph.facebook.com/v20.0/{phone-number-id}`
- Auth: Bearer token (long-lived access token stored in `.env` as `WHATSAPP_TOKEN`)
- Webhook URL: `https://<our-domain>/webhook/whatsapp` → Nginx → n8n

## Message types we use

- `text` — default for replies
- `interactive.button` — quick reply buttons (YES/NO, slot 1/2/3)
- `template` — required for any outbound message outside the 24h service window
- `audio` — inbound voice notes (we never send voice notes)
- `document` — inbound CVs; outbound data exports for DPA requests

## The 24-hour service window

Meta's rule: we can freely send free-form messages to a candidate within 24 hours of their last inbound message. Outside that window, outbound messages **must** use a pre-approved template.

This shapes the architecture. Any workflow that re-engages a cold candidate (Workflow H re-engagement, Workflow G reminders > 24h out) uses templates. In-thread replies (Workflow A, C, D) stay in free-form because we are always responding inside the window.

## Template approval

Templates live in Meta Business Manager and are submitted for approval. Typical approval time is under 1 hour for well-formed templates, but plan for up to 48h in Week 0.

Templates we need approved before go-live:

| Name | Purpose | Workflow |
|---|---|---|
| `consent_request` | First-touch consent message | A |
| `interview_reminder_24h` | 24h before interview | G |
| `interview_reminder_2h` | 2h before interview | G |
| `re_engagement_v1` | Strong candidate, new similar role | H |
| `still_interested_10d` | Shortlisted candidate, no activity 10d | G |

Templates are variable-parameterised. Keep parameters to first name + one other datum where possible; long, highly variable templates get rejected more often.

## Pricing (as of 2026)

Meta moved to per-message pricing in July 2025. Rates vary by template category and country.

- **Utility template** (confirmations, reminders, receipts): cheapest tier, ~$0.014 per delivered message in Ghana.
- **Marketing template** (re-engagement, promotions): most expensive tier, ~$0.040–$0.060 per delivered message in Ghana.
- **Service (free-form, in-session)**: free.

Workflow H's `re_engagement_v1` template is classified as **utility** (it references a specific prior interaction). Do not let it be reclassified as marketing — rewrite phrasing before accepting a marketing-tier approval.

Budget in the cost model: assume ~500 template sends per month initially, call it $10–20/mo.

## Inbound webhook format

The webhook delivers a batch. Each batch contains zero or more entries; each entry zero or more changes; each change includes `messages[]` (inbound), `statuses[]` (delivery/read receipts), or both.

n8n must:

1. Validate the `X-Hub-Signature-256` header against `WHATSAPP_APP_SECRET`. Reject if it does not match.
2. Return 200 within 5 seconds regardless of downstream success. Meta will retry aggressively on non-200.
3. Enqueue each message for processing rather than processing in the webhook response path.

## Media handling

Inbound media arrives as a `media_id`, not as a URL. To fetch, call `GET /{media-id}` to get a short-lived download URL, then download with the same bearer token.

Store media locally in a private S3-compatible bucket (Backblaze). URLs expire; IDs are stable for 30 days; our copies are forever (subject to retention).

## Rate limits

- Sending: 80 messages per second per phone number for standard quality rating. We are nowhere near this.
- Templates: subject to daily per-template sending tiers that increase as the account matures. Tier 250 at start, progresses to 1k / 10k / 100k / unlimited.

Workflow G tracks our quality rating (fetched from the Meta Business API); any drop from GREEN alerts the Orchestrator.

## Known pitfalls

- **Phone number format:** the API expects E.164 (`+233241234567`). Our normaliser does this on the way in. Never store local-format.
- **Session-window calculation:** "24 hours since last inbound" is calculated by Meta, not us. If our state disagrees with Meta's, Meta wins — an outbound free-form message will be rejected with error code 131047. Our code must handle this by falling back to a template.
- **Media URL expiry:** the download URL from `GET /{media-id}` expires in ~5 minutes. Download immediately on receipt, not later.
- **Display name:** whatever name appears on the business profile is what candidates see; keep it aligned with the firm's brand.

## Configuration

Required `.env` entries:

```
WHATSAPP_TOKEN=
WHATSAPP_PHONE_NUMBER_ID=
WHATSAPP_BUSINESS_ACCOUNT_ID=
WHATSAPP_APP_SECRET=
WHATSAPP_VERIFY_TOKEN=
WHATSAPP_WEBHOOK_URL=https://<our-domain>/webhook/whatsapp
```

See `reference/whatsapp-message-types.md` (TODO: snapshot from Meta docs during Week 0) for the exact request/response bodies we use.
