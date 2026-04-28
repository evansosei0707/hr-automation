# Ghana Context

Everything Ghana-specific in one place. If a spec anywhere else contradicts this file, fix the spec.

## Language strategy

Candidates in Ghana use a mix of English, Ghanaian Pidgin, Twi (Akan), Ga, Ewe, Dagbani, and others. We handle them as follows:

- **Typed text, any language:** passed directly to Claude. Claude reads Twi, Ga, Ewe, Dagbani meaningfully well when they are typed. No transcription step, no quality degradation.
- **Voice notes in English or Ghanaian Pidgin:** transcribed with `whisper-large-v3-turbo` via Groq (per ADR-0006; superseded the earlier OpenAI choice). Cost: ~$0.000667/minute on the paid tier; the free tier covers our forecast volume. Real-Pidgin accuracy is verified during the 2-week post-launch calibration window.
- **Voice notes in any other Ghanaian language:** we do NOT attempt automated transcription. No currently available ASR handles these reliably (confirmed in the v3 research round — including GhanaNLP's Khaya API, which is still alpha). The system sends a polite retry request. If the candidate still sends a local-language voice note, the message is routed to a human-review queue in Twenty, tagged `voice_note_manual_review`.

See `docs/05-decisions/ADR-0004-drop-khaya.md` for the full rationale.

### Default greeting template

Every first-touch inbound message gets this framing (in the Claude system prompt, not hardcoded):

> "You can reply by typing or by voice note. For voice notes, please use English or Pidgin so we understand you clearly. If you prefer to type in Twi, Ga, Ewe, or any other language, that works fine — we will read it."

## Phone numbers

Ghanaian mobile prefixes as of 2026. The validator lives in `scripts/lib/phone.ts` and is imported by every workflow that touches a phone number.

| Carrier | Prefixes (after +233 or 0) |
|---|---|
| MTN | 024, 025, 053, 054, 055, 059 |
| Telecel (ex-Vodafone) | 020, 050 |
| AirtelTigo | 026, 027, 056, 057 |
| Glo | 023 |

Any submitted number outside these ranges is flagged `phone_validation_failed` and routed to the Orchestrator queue, not bounced.

WhatsApp recognises numbers in E.164 format (`+233XXXXXXXXX`), not local format (`0XXXXXXXXXX`). The normaliser converts local to E.164 on the way in.

## Public holidays (2026)

The source of truth is Google Calendar (public calendar `en.gh#holiday@group.v.calendar.google.com`), pulled daily and mirrored into a `Holiday` object in Twenty. The Operations Lead can override any entry in Twenty to handle regional holidays, lunar date adjustments, or firm-specific closures.

Reference list for 2026 (from Government of Ghana calendar; subject to mirror):

- Jan 1 — New Year's Day
- Jan 7 — Constitution Day
- Mar 6 — Independence Day
- Apr 3 — Good Friday
- Apr 6 — Easter Monday
- May 1 — May Day
- May 25 — African Union Day (observed)
- Jul 1 — Republic Day
- *TBD (lunar)* — Eid-ul-Fitr
- *TBD (lunar)* — Eid-ul-Adha
- Sep 21 — Founder's Day (Kwame Nkrumah's birthday) — **NOT August**
- Dec 1 — Farmers' Day (first Friday of December)
- Dec 5 — Shaqq Day (lunar — verify annually)
- Dec 25 — Christmas Day
- Dec 26 — Boxing Day

**Common mistake to avoid:** older references list Founder's Day as August 4th. That was changed; September 21 is correct.

See `docs/03-integrations/google-calendar.md` for the sync mechanism.

## Working hours assumptions

- **Business hours:** Monday–Friday, 09:00–17:00 Africa/Accra.
- **Candidate-friendly messaging window:** Monday–Saturday, 07:00–20:00 Africa/Accra. Outside this, outbound messages queue (never fire at 02:00).
- **Interview slots:** Mon–Fri 09:00–16:00 by default; override per client.

## Timezone

`Africa/Accra` everywhere. GMT+0 year-round, no DST. Store timestamps as UTC in Postgres, render in Accra time in UI and messages.

## Currency

- **Internal accounting:** Ghanaian Cedi (GHS). Placement fees, invoices, firm-side numbers.
- **Cloud bills:** USD. API costs, VPS, domains.
- **Candidate-facing salary mentions:** GHS. Never mention USD to candidates.

Display GHS with two decimal places and a thousands separator: `GHS 3,500.00`.

## Data protection

Ghana's Data Protection Act 2012 became actively enforced by the Data Protection Commission in January 2026. Key obligations baked into this system:

- **Consent:** every new candidate receives an explicit consent message on first contact and must reply YES before their data is retained. If they do not consent, their record is auto-purged after 48 hours.
- **Purpose limitation:** we collect only what the current role requires. No speculative data hoarding.
- **Retention:** candidate records auto-archive 24 months after last activity; archived records are cryptographically shredded at 36 months unless the candidate has consented to indefinite retention.
- **Access:** a candidate can request their data via WhatsApp reply `DATA`. Workflow exports their record as JSON and sends it as a document.
- **Deletion:** a candidate can request deletion via WhatsApp reply `DELETE`. Workflow marks the record `pending_deletion`, sends a confirmation, and purges after 7 days (buffer for accidental deletes).
- **Breach notification:** 72-hour notification obligation. Documented in the runbook.

See `docs/04-operations/ghana-dpa.md` for the compliance detail.

## Cultural and operational notes

- **Opening messages:** candidates often start with "Please" or "Good morning/afternoon, sir/madam" as a politeness signal. Do not treat missing greeting as rudeness.
- **Name formats:** many candidates use a day-name (Kofi, Ama, Akosua, Kwame, Kwesi, Kojo, Esi, Yaa...) as a first name; these are day-of-week names, not nicknames. Do not normalise them away.
- **"Okay" as a terminator:** replying with just "Okay" often signals the end of a candidate's thread, not the start of a new question.
- **Voice-note culture:** voice notes are the default for blue-collar candidates and many white-collar candidates, more so than typed long messages. Design accordingly.
