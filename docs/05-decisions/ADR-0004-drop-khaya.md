# ADR-0004: Drop GhanaNLP Khaya ASR; English/Pidgin only

**Status:** Accepted
**Date:** 2026-04-24
**Deciders:** Operations Lead, CEO

## Context

The v3 blueprint originally included GhanaNLP's Khaya ASR as a fallback for transcribing Twi, Ga, Ewe, Dagbani voice notes. On review:

- Khaya's own demo on their website failed to translate correctly during evaluation.
- Their public API documentation describes v3 ASR as "ALPHA — still under development, some languages will not have punctuation."
- Youtube demos of the product showed transcription quality too low to be a reliable input into downstream automated decisions.
- Misrepresenting a candidate's local-language voice note through a low-accuracy transcriber is legally and ethically worse than politely declining to transcribe.

No currently available ASR (Whisper, gpt-4o-mini-transcribe, Google, AWS, Azure) handles Ghanaian local languages reliably.

## Decision

1. Do not use any Ghanaian local-language ASR in v1.
2. Transcribe voice notes only when the audio is English or Ghanaian Pidgin, with confidence ≥ 0.7. Use `gpt-4o-mini-transcribe`.
3. For unclear audio or non-English/Pidgin voice notes, the system:
   - Sends a polite retry request in English + Pidgin.
   - On second unclear voice note, routes to human review queue.
4. Typed local-language text is passed directly to Claude (no transcription step; text is easy for Claude to read).
5. The first-contact message explicitly tells candidates they can type in Twi/Ga/Ewe/any language, or send voice in English/Pidgin.

## Consequences

**Positive:**
- Candidates are not misrepresented by poor transcription.
- System complies with DPA accuracy principle.
- Cheaper (no paid Khaya subscription; no wasted OpenAI calls on unclear audio).
- Simpler: one integration for voice instead of two, with a clean human-review fallback.

**Trade-offs accepted:**
- Some percentage of voice notes (estimated 5–15% based on language mix) will require human review. Plan capacity for this in the Operations Lead's daily rhythm.
- Candidates who will only send voice in local languages and cannot type may feel some friction; this is a real cost.

**Neutral / follow-up:**
- Re-evaluate Ghanaian ASR annually. If Meta's MMS, OpenAI Whisper-v4, or a reliable African-language model reaches production-quality on Twi, adopt it.
- Track manual-review voice-note volume. If it's >20% of voice notes, the UX has a problem and we revisit.

## Alternatives considered

- **Keep Khaya as fallback:** rejected. Demo failure + alpha status + no SLA = reliability risk we cannot carry into candidate-facing decisions.
- **Transcribe non-English audio with Whisper anyway:** rejected. Known-wrong outputs are worse than no output.
- **Require all candidates to type (no voice):** rejected. Voice notes are a core channel for blue-collar candidates; banning them would kill conversion.

## References

- GhanaNLP website evaluation (performed April 2026)
- Khaya API documentation describing v3 ASR as alpha
- Research consensus on Ghanaian local-language ASR state-of-the-art, April 2026
