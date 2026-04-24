# Integration — OpenAI Voice Transcription

Transcribes English and Ghanaian Pidgin voice notes. Not used for Twi, Ga, Ewe, Dagbani or other Ghanaian local languages.

## Model

`gpt-4o-mini-transcribe`. ~$0.003 per minute of audio as of 2026. Significantly better than Whisper-1 on Ghanaian-accented English and Pidgin.

## Endpoint

```
POST https://api.openai.com/v1/audio/transcriptions
Authorization: Bearer {OPENAI_API_KEY}
Content-Type: multipart/form-data

fields:
  file: <audio bytes>
  model: gpt-4o-mini-transcribe
  language: en
  prompt: "Ghanaian English and Pidgin. Names may include Ghanaian names like Kwame, Akosua, Kojo."
```

The `prompt` field is a biasing hint, not an instruction. It steers the model toward our domain and reduces transliteration errors on Ghanaian names.

## When we call it — and when we don't

We transcribe when **all** of the following:
- Inbound message type is `audio`
- Language classifier says English or Pidgin with confidence ≥ 0.7
- Audio duration ≤ 90 seconds

We do NOT transcribe when:
- Language classifier says Twi/Ga/Ewe/Dagbani/other local language with any confidence
- Language classifier is uncertain (<0.7 confidence)
- Duration > 90 seconds (probably a monologue; we want a retry for brevity, not a $1 transcription bill per message)

## Language detection

Before transcription, we run a short language classifier pass. Two options we are testing in Week 0:

1. **OpenAI's own langid** via the Whisper preview transcription (10s sample, no cost logged separately) — most accurate but adds a call.
2. **Local classifier** using a small model — no extra API cost but less accurate on noisy audio.

Default in v1: option 1. Revisit if cost becomes an issue.

## The retry / fallback flow

When we choose not to transcribe, the workflow A handler sends a pre-approved template (within 24h service window, actually a free-form message):

> *"I heard your voice note but couldn't catch it clearly. Could you type your reply, or try again in English or Pidgin? No worries either way — whichever works for you."*

On a second undeliverable voice note from the same candidate in the same 24h window, we route to `manual_review` without another auto-reply — do not nag.

Manual-review voice notes are accessible to the Operations Lead as a Task in Twenty, with the audio attached.

## Output handling

The transcription returns a text string. We store it on the `conversation_message` row as `transcript`, with `transcript_quality`:

- `high` — clean transcription, passed a basic sanity check (non-empty, contains words, not a noise artefact)
- `low` — returned but looks noisy (many repeated words, very short, nonsense) — route to manual review anyway
- `unavailable` — we chose not to transcribe

## Cost notes

For a firm receiving ~300 voice notes per week averaging 15 seconds: ~$0.002 × 300 = $0.60/week. Negligible.

Budget alert threshold: $10/month for this integration.

## Known pitfalls

- **Very short clips:** under 2 seconds, the transcription often returns noise artefacts ("you", "thank you", empty). Detect and treat as unclear.
- **Background noise:** street noise, marketplace background, multiple speakers → low quality. Classifier helps but not perfectly.
- **Numbers and phone numbers:** Whisper-lineage models transcribe "two three three" as "233" inconsistently. Do not rely on transcribed numbers for identity.
- **Names:** Ghanaian names are often transliterated. The `prompt` field helps. Do not match candidate identity by transcribed name; match by phone number.

## Configuration

```
OPENAI_API_KEY=
OPENAI_TRANSCRIBE_MODEL=gpt-4o-mini-transcribe
```
