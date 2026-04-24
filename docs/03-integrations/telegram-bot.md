# Integration — Telegram Bot API

Free, generous limits, well-suited to broadcasting job posts to a channel.

## Setup

1. Talk to `@BotFather` on Telegram; create a new bot, get the bot token.
2. Create a public channel for job posts (e.g. `@FirmNameCareers`).
3. Add the bot as an administrator of the channel with "Post Messages" permission.
4. Get the channel's numeric chat ID (via `getUpdates` after a test post, or by forwarding a message to `@userinfobot`).

All → `.env`.

## Posting

**Endpoint:** `POST https://api.telegram.org/bot{token}/sendMessage`

**Body:**
```json
{
  "chat_id": "@FirmNameCareers",
  "text": "*Frontend Developer* — Accra\n\nWe're hiring...",
  "parse_mode": "MarkdownV2",
  "disable_web_page_preview": false
}
```

**Returns:** `{"ok": true, "result": {"message_id": 42, ...}}`

Store `message_id` in `SocialPost.externalPostId`.

The public URL is `https://t.me/FirmNameCareers/{message_id}`.

## Photos and media

**`POST .../sendPhoto`** with `chat_id`, `photo` (URL or multipart), `caption`.

Caption max 1,024 characters.

## MarkdownV2 escaping

Telegram's MarkdownV2 requires escaping `_*[]()~`\>#+-=|{}.!` with a backslash when they are literal. Our wrapper function handles this; never hand-concatenate user content into a Markdown message.

## Rate limits

- 30 messages per second across all chats
- 1 message per second to the same chat
- 20 messages per minute to the same group

We are never close to these.

## Updates webhook (future)

If/when we want to support candidates replying through Telegram:

- Set the webhook: `POST /setWebhook` with our URL
- Messages arrive as `Update` objects; parse and route similar to WhatsApp inbound

**For v1, we only post outbound. No inbound Telegram.** Flagged for Phase 2.

## Known pitfalls

- **Parse mode ambiguity:** if `parse_mode` is set but the text has unescaped special chars, the whole send fails with 400. Default to `MarkdownV2` and always escape.
- **Chat ID form:** `@channelname` works for public channels; private channels need the numeric form (negative, usually starts with `-100`).
- **Bot permissions:** if the bot loses admin rights in the channel, sends fail with 403. Orchestration daily health check catches this.

## Configuration

```
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHANNEL_ID=@FirmNameCareers
```
