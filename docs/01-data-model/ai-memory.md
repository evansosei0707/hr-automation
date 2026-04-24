# AI Memory Strategy

How Claude remembers a conversation without re-reading six months of messages every turn.

## The problem

A candidate who has been in the firm's pipeline for eight months could have 400 WhatsApp messages on record. Sending all of them to Claude every time they say "hello" would be expensive, slow, and actually lower answer quality — Claude's best outputs come from tight, relevant context.

## The pattern: rolling summary + recent window + structured facts

Every conversation carries three kinds of context:

1. **Recent window** — the last N turns, verbatim. N = 20 by default. This is the "what just happened" layer.
2. **Rolling summary** — a Claude-written narrative of everything before the recent window. Regenerated whenever the window slides. Capped at ~300 words.
3. **Structured facts** — hard-data key-value pairs stored on the Candidate record: preferred language, years of experience, current location, available-from date, etc. These are extracted during screening, not stored as prose.

At each turn, we send Claude:

```
[System prompt]
[Structured facts — formatted as a compact bullet list]
[Rolling summary — last known state]
[Recent window — last 20 turns, verbatim]
[The new inbound message]
```

Total context per call: typically 1.5–3k tokens. Rarely above 5k.

## Storage

Not in Twenty. The conversation transcript, rolling summary, and window pointer live in the bookings Postgres, which n8n owns:

```sql
CREATE TABLE conversation (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  twenty_candidate_id TEXT NOT NULL UNIQUE,
  summary TEXT NOT NULL DEFAULT '',
  summary_updated_at TIMESTAMPTZ,
  window_start_message_id BIGINT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE conversation_message (
  id BIGSERIAL PRIMARY KEY,
  conversation_id UUID NOT NULL REFERENCES conversation(id),
  direction TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
  body TEXT NOT NULL,
  wa_message_id TEXT UNIQUE,
  media_type TEXT,
  media_url TEXT,
  transcript TEXT, -- filled by the transcription step for voice notes
  transcript_quality TEXT CHECK (transcript_quality IN ('high','low','unavailable')),
  occurred_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX conversation_message_window
  ON conversation_message (conversation_id, occurred_at DESC);
```

Structured facts live on the Candidate record in Twenty, mirrored to a read cache here for speed:

```sql
CREATE TABLE candidate_facts (
  twenty_candidate_id TEXT PRIMARY KEY,
  facts JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

## Summary regeneration

When a new message comes in and the conversation has > 20 messages since the last summary update, the next outbound reply is preceded by a summary-regeneration step:

1. Fetch messages `window_start_message_id` through `latest - 20`.
2. Send to Claude with the current summary and ask: "extend this summary to cover these additional messages, keeping total length under 300 words."
3. Store the new summary and advance `window_start_message_id` to `latest - 20`.

The summary regeneration uses Claude Haiku (cheap) not Sonnet (expensive). Summaries rarely need nuance.

## Structured fact extraction

Runs during workflow B (white-collar screening) and workflow C (blue-collar screening). The extraction prompt asks Claude for a strict JSON object with named fields; no prose. Parsing failures fall through to a human-review task.

Fields routinely extracted:
- `yearsExperience` (number | null)
- `currentRole` (string | null)
- `availableFromDate` (ISO date | null)
- `currentLocation` (string | null)
- `willingToRelocate` (boolean | null)
- `minSalaryGhs` (number | null)
- `certifications` (string[])
- `skillTagsInferred` (string[])

Conflicts between old and new facts are kept, not overwritten. A history table records every fact change with source and timestamp.

## Cost control

- **Recent window size:** 20 turns is a tuning parameter, not a law. We expect to lower it for workflow C (blue-collar) where turns are shorter, and keep it at 20 for workflow A (open conversations).
- **Model routing:** Haiku for summarisation, simple reply drafting, and fact extraction. Sonnet for CV reviews and anything that requires nuance. The router lives in the `docs/03-integrations/claude-api.md` spec.
- **Budget alerts:** the orchestration workflow flags daily AI spend > $5 and weekly > $25, sent to the staff channel.

## Privacy note

Conversation transcripts are candidate data under the Ghana DPA. Retention mirrors the Candidate record: 24 months from last activity, auto-archive thereafter, cryptographic shred at 36 months unless the candidate consents to longer retention.

Do not include the conversation table in any export that leaves the production environment without the Operations Lead's approval.
