# Integration — Groq Whisper Voice Transcription

Transcribes English and Ghanaian Pidgin voice notes. Not used for Twi, Ga, Ewe, Dagbani or other Ghanaian local languages (per ADR-0004).

**Provider:** Groq (https://groq.com), model `whisper-large-v3-turbo`. Selected per ADR-0006 (2026-04-28) replacing OpenAI's `gpt-4o-mini-transcribe`. The wire shape is OpenAI-compatible — same multipart upload, same default JSON response — so a future swap back is mechanical.

## Model

`whisper-large-v3-turbo` (Groq-hosted). Cost: **$0.04 per hour of audio** if paid; free tier covers our forecast (~150 audio-minutes/week) with ~95% headroom. Pricing has a 10-second minimum bill per request, so very short clips round up to the floor.

**Fallback model:** `whisper-large-v3` (non-turbo) at $0.111/hour — switch to this only if the calibration window surfaces clear quality gaps on Ghanaian Pidgin. Default is `turbo` until evidence shows otherwise.

## Endpoint

```
POST https://api.groq.com/openai/v1/audio/transcriptions
Authorization: Bearer {GROQ_API_KEY}
Content-Type: multipart/form-data

fields:
  file: <audio bytes>
  model: whisper-large-v3-turbo
  language: en
  prompt: "Ghanaian English and Pidgin. Names may include Ghanaian names like Kwame, Akosua, Kojo."
  response_format: verbose_json     # see "Confidence gating" below
  timestamp_granularities[]: segment
```

The `prompt` field is a biasing hint, not an instruction. It steers the model toward our domain and reduces transliteration errors on Ghanaian names.

The base URL `/openai/v1/` is intentional — Groq's compatibility surface lives under that path prefix. Bare `/v1/` does NOT work.

## When we call it — and when we don't

We transcribe when **all** of the following:
- Inbound message type is `audio`
- Language classifier says English or Pidgin with confidence ≥ 0.7
- Audio duration ≤ 90 seconds

We do NOT transcribe when:
- Language classifier says Twi/Ga/Ewe/Dagbani/other local language with any confidence
- Language classifier is uncertain (<0.7 confidence)
- Duration > 90 seconds (probably a monologue; we want a retry for brevity, not a full-cost transcription per message)

## Language detection

Before transcription, we run a short language classifier pass. Two options on the table:

1. **Groq Whisper langid pass** — submit the first ~10 seconds with `response_format=verbose_json` and inspect the detected `language` field. Adds one short call but uses the same provider as the transcription itself.
2. **Local classifier** using a small model — no extra API cost but less accurate on noisy audio.

Default in v1: option 1. Revisit if cost becomes an issue (the free tier absorbs the extra calls easily for now).

## Confidence gating (new capability vs OpenAI)

`response_format: verbose_json` returns per-segment fields including:
- `avg_logprob` — closer to 0 means higher confidence; very negative means uncertain
- `no_speech_prob` — closer to 1 means the model thinks it's silence/noise rather than speech
- `compression_ratio` — high values indicate hallucinated repetition

These are routing primitives we did NOT have on OpenAI's default JSON response. Workflow A uses them to gate auto-action:

| Signal | Threshold (initial) | Action |
|---|---|---|
| `avg_logprob` < −1.0 (any segment) | low confidence | route to manual review |
| `no_speech_prob` > 0.3 (any segment) | likely silence/noise | "I couldn't catch that — try again?" template |
| `compression_ratio` > 2.4 (any segment) | likely hallucinated loop | route to manual review |
| All three OK | high confidence | proceed with auto-handling |

These thresholds are **initial guesses** to be calibrated empirically during the 2-week post-launch human-review window. Real Ghanaian-Pidgin voice notes from the ops team are the ground truth.

## The retry / fallback flow

When we choose not to transcribe, the workflow A handler sends a free-form message (within 24h service window):

> *"I heard your voice note but couldn't catch it clearly. Could you type your reply, or try again in English or Pidgin? No worries either way — whichever works for you."*

On a second undeliverable voice note from the same candidate in the same 24h window, we route to `manual_review` without another auto-reply — do not nag.

Manual-review voice notes are accessible to the Operations Lead as a Task in Twenty, with the audio attached.

## Output handling

The transcription returns a `text` field with the full transcript and (when `verbose_json` is requested) a `segments[]` array. We store the text on the `conversation_message` row as `transcript`, with `transcript_quality`:

- `high` — clean transcription, all confidence gates above threshold
- `medium` — single soft-fail on one threshold; auto-process but flag for sampling review
- `low` — multiple gates fail or any hard threshold breached; route to `manual_review`
- `unavailable` — we chose not to transcribe (local language, too long, etc.)

The full `verbose_json` response is stored in `conversation_message.transcript_metadata` as JSONB so we can re-evaluate gating thresholds after launch without re-transcribing.

## Cost notes

- **Free tier:** 20 RPM, 2K RPD, 28.8K audio-seconds/day. Production forecast (~22 audio-min/day) uses ~5% of the daily allowance.
- **If/when paid:** `whisper-large-v3-turbo` $0.04/hour ≈ $0.000667/minute. A 30-second voice note costs ~$0.0003. Workflow G's daily cost roll-up (`g-orchestration.md`) sums Claude + Groq Whisper into the daily total against the $5 warn / $10 gate budgets.
- **Card acceptance from Ghana** for paid upgrade is unverified at the issuing-bank level. Free tier requires no card; defer the question.
- Budget alert threshold for transcription specifically: $10/month (rolled into the unified AI budget).

## Known pitfalls (carry-forward from earlier Whisper experience)

- **Very short clips:** under 2 seconds, the transcription often returns noise artefacts ("you", "thank you", empty). Detect and treat as unclear; the `no_speech_prob` gate catches most of these now.
- **Background noise:** street noise, marketplace background, multiple speakers → low confidence segments. Classifier helps but not perfectly; `avg_logprob` and `compression_ratio` are the gates.
- **Numbers and phone numbers:** Whisper-lineage models transcribe "two three three" as "233" inconsistently. Do not rely on transcribed numbers for identity.
- **Names:** Ghanaian names are often transliterated. The `prompt` field helps. Do not match candidate identity by transcribed name; match by phone number.

## Configuration (env)

```
GROQ_API_KEY=gsk_...                                    # secret, from console.groq.com
GROQ_TRANSCRIBE_MODEL=whisper-large-v3-turbo            # default; override only on calibration evidence
GROQ_API_BASE_URL=https://api.groq.com/openai/v1        # rarely changes; documented for clarity
```

The voucher script `scripts/voucher/groq-transcribe.sh` proves the wire shape end-to-end. Run it after any `.env` change.

## Historical artifact

The OpenAI Whisper integration was the original choice; superseded by ADR-0006. The OpenAI voucher (`scripts/voucher/openai-transcribe.sh` + same WAV fixture at `scripts/voucher/fixtures/voucher_sample.wav`) remains in the repo as a "what we tried" artifact. Switching back is mechanical — env-var swap — but is not anticipated.
