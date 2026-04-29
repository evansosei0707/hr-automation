# ADR-0006: Pivot transcription provider — OpenAI Whisper → Groq Whisper

**Status:** Accepted
**Date:** 2026-04-28
**Deciders:** HRA Project Lead

## Context

The original integration design (`docs/03-integrations/openai-transcribe.md`) selected OpenAI's `gpt-4o-mini-transcribe` as the transcription provider for WhatsApp voice notes (English + Ghanaian Pidgin only; local languages routed to manual review per CLAUDE.md non-negotiable invariant #5).

OpenAI billing failed twice during Phase 4 voucher work (2026-04-27 and 2026-04-28) on a Ghanaian-issued payment card — the same card was accepted by Anthropic without issue. The failure was OpenAI-specific, region-specific card-acceptance behaviour. The voucher script + WAV fixture are committed (`scripts/voucher/openai-transcribe.sh`, commit `e5a9b16`); the run record is parked indefinitely.

We need transcription. Workflow A (WhatsApp inbound) cannot ship without it. Continuing to wait on OpenAI is open-ended; the firm has a contact who runs Groq from Ghana successfully today.

A `researcher` pass on 2026-04-28 verified Groq's current shape, pricing, free-tier limits, and OpenAI-compatibility surface. Findings cited in **References** below.

## Decision

Replace OpenAI Whisper with **Groq Whisper** as the project's transcription provider.

- **Default model:** `whisper-large-v3-turbo` (Groq-hosted; OpenAI-compatible API).
- **Endpoint:** `POST https://api.groq.com/openai/v1/audio/transcriptions`.
- **Auth:** `Authorization: Bearer $GROQ_API_KEY`.
- **Wire shape:** identical to OpenAI — multipart `file` / `model` / `language` / `response_format=json` / optional `prompt` / optional `timestamp_granularities[]`. Response: `{"text": "..."}` for `json`, full segment data for `verbose_json`.

The OpenAI voucher script and WAV fixture stay in the repo as historical "what we tried" artifacts. The Groq voucher (`scripts/voucher/groq-transcribe.sh`) is a new file, not an in-place edit, so the OpenAI script remains intact and runnable if access is ever resolved.

## Consequences

**Positive:**

- Unblocks Phase 4 transcription voucher and Workflow A's voice-note path. No further wait on OpenAI billing.
- Free tier comfortably covers production volume with ~95% headroom. The original brief targets ~few hundred voice notes per week (~150 min/week ≈ 22 min/day audio); Groq's free tier allows 480 audio-min/day and 2,000 requests/day. We can grow 3× before needing to think about paid.
- Drop-in OpenAI-compatible API: env-var swap only. Same `claude.ts`-style wrapper pattern fits without redesign.
- Cheaper at scale if we ever upgrade — `whisper-large-v3-turbo` is 60% cheaper per hour than the OpenAI equivalent tier.
- `verbose_json` returns per-segment `avg_logprob` and `no_speech_prob`, usable as confidence gates (route low-confidence transcripts to manual review). OpenAI's `gpt-4o-mini-transcribe` returns only `text` in default JSON mode — Groq gives us a routing primitive we didn't have before.

**Negative / trade-offs accepted:**

- No published benchmark for Ghanaian Pidgin or West African accented English on any Whisper variant. Researcher noted this is inferential — both Whisper-large-v3 and OpenAI's `gpt-4o-mini-transcribe` descend from the same architecture, so practical differences are likely small but unverified. **The 2-week post-launch calibration window is the ongoing quality dial-in path** — threshold tuning, edge-case handling, per-accent observation across real candidate traffic. During calibration, Workflow A's voice-note pass is fully human-reviewed before any auto-action; we'll see real Ghanaian-Pidgin transcription quality on real candidate audio and tune confidence thresholds against that. **A complementary pre-launch catastrophic-check** (catch garbage transcripts before they reach production) is captured separately as Tier 2 item T2-6 — one-time WER/error-pattern measurement on ~5-10 recorded Pidgin samples, gated before Workflow A's voice-note auto-handling ships. The two paths serve different risk profiles and are both intentional: T2-6 verifies "is the system working at all on Pidgin"; the calibration window tunes "how much can we trust each transcript."
- If we ever need to upgrade past the free tier, Groq's billing accepts only credit cards (no bank accounts outside US/SEPA). A Ghanaian Visa/Mastercard *should* clear via Groq's Stripe-based processor, but the issuing bank may block international charges. **Verification deferred until/unless we hit free-tier limits.** At current volume forecasts, this is a year-out concern at minimum.
- Whisper-large-v3 is older (2023) than `gpt-4o-mini-transcribe` (2025). Older means more battle-tested in deployment but less recent training data. Acceptable for our use.

**Neutral / follow-up work:**

- Rename `docs/03-integrations/openai-transcribe.md` → `docs/03-integrations/groq-whisper.md` and rewrite content for Groq specifics. (Carried out alongside this ADR — same commit series.)
- Add `GROQ_API_KEY`, `GROQ_TRANSCRIBE_MODEL`, `GROQ_API_BASE_URL` to `infrastructure/.env.example`. Leave the existing OpenAI vars in place but commented as "no longer used; kept for the OpenAI voucher historical artifact."
- Build `scripts/voucher/groq-transcribe.sh` adapted from the OpenAI voucher (env vars + URL only). Same `voucher_sample.wav` fixture.
- Update workflow specs that reference OpenAI transcription (Workflow A primarily; possibly Workflow C if it touches voice).
- Update `.claude/rules/n8n-workflows.md` if it references the OpenAI provider specifically. (Likely doesn't — the rule talks about subflow patterns, not vendor names.)
- Update `.claude/memory/status.md` Phase 4 row.
- During the 2-week calibration window post-launch: collect Groq Whisper transcripts on real Ghanaian voice notes and decide whether `whisper-large-v3-turbo` (cheaper, faster) is sufficient or whether we need to bump to base `whisper-large-v3` for quality. The default is `turbo` until evidence shows otherwise.

## Alternatives considered

- **Self-hosted whisper.cpp on the VPS.** Rejected: adds infrastructure complexity (GPU/CPU sizing, model file management, queue depth handling). Single-node VPS budget already absorbs Twenty + n8n + Postgres + Redis; adding a transcription service on the same box risks resource contention with Workflow A's lock-holding Claude calls. The Groq free tier removes this entirely.
- **AssemblyAI Universal-2.** Rejected: better accent benchmarks per published comparisons but paid-only (no free tier), more expensive than Groq's paid tier even, and re-introduces the card-acceptance question. We'd be solving the same problem with a worse price point.
- **Deepgram Nova-2.** Same trade-off as AssemblyAI: paid-only, comparable price, no free tier for our voucher.
- **ElevenLabs Scribe.** Premium pricing tier; unjustified for our volume.
- **Wait for OpenAI billing to resolve.** Rejected: open-ended timeline, the underlying card-acceptance issue may never resolve via the same bank. The OpenAI voucher artifacts stay in the repo as a "ready when access resolves" path, but Workflow A cannot wait on it.

## References

- Groq pricing: https://groq.com/pricing — `$0.04/hr` for `whisper-large-v3-turbo`, `$0.111/hr` for `whisper-large-v3`. Both have a 10-second minimum bill per request.
- Groq rate limits: https://console.groq.com/docs/rate-limits — free tier: 20 RPM, 2K RPD, 7.2K audio-sec/hour, 28.8K audio-sec/day.
- Groq speech-to-text docs: https://console.groq.com/docs/speech-to-text — endpoint, multipart fields, `verbose_json` segment fields (`avg_logprob`, `no_speech_prob`), `timestamp_granularities[]`.
- Groq OpenAI compatibility: https://console.groq.com/docs/openai — confirms `https://api.groq.com/openai/v1/...` base URL.
- Groq billing FAQ: https://console.groq.com/docs/billing-faqs — payment-method scope (Visa/Mastercard/Amex/Discover; US bank accounts; SEPA debit).
- Researcher report: in-conversation, 2026-04-28 (no separate file).
- ADR-0004 — drop GhanaNLP Khaya ASR; English/Pidgin only — establishes the scope this ADR's provider serves.
- Original OpenAI integration doc (now superseded): `docs/03-integrations/openai-transcribe.md` (renamed to `groq-whisper.md` in the same commit series).
- OpenAI voucher artifacts (kept as historical): `scripts/voucher/openai-transcribe.sh`, `scripts/voucher/fixtures/voucher_sample.wav`.
