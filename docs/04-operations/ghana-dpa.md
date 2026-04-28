# Operations — Ghana DPA Compliance

How this system complies with the Data Protection Act 2012 (Ghana), as enforced by the Data Protection Commission (DPC) beginning January 2026.

## What the law requires (short version)

The Ghana DPA 2012 establishes these principles for any organisation processing personal data:

1. **Consent** before processing.
2. **Purpose limitation** — use data only for the stated purpose.
3. **Data minimisation** — collect only what you need.
4. **Accuracy** — keep data correct and current.
5. **Retention limits** — do not keep data longer than necessary.
6. **Security** — appropriate technical and organisational measures.
7. **Accountability** — be able to demonstrate compliance.

DPC enforcement became active January 2026 with published penalty schedules. Non-compliance can incur administrative fines, public orders, and, in cases of repeated violation, criminal proceedings.

## How each principle is implemented

### Consent

- Every new WhatsApp contact is treated as a **Candidate with `consentStatus=pending`**.
- First outbound message is a consent request template explaining why we store their data and for how long, with a YES/NO reply.
- Reply YES → `consentStatus=granted`, `consentGrantedAt=NOW()`.
- Reply NO or no reply in 48 hours → Candidate auto-purged.
- We do not process data (screen, score, re-engage) for `pending` or `refused` candidates.

The consent template text is kept in version control and reviewed annually by the CEO. A record of consent is the `consentGrantedAt` timestamp + the template version used + the full first conversation transcript.

### Purpose limitation

The stated purpose in the consent message is:

> "to review your suitability for roles we recruit, to contact you about opportunities, and to keep your record for future matching."

We do not use data for marketing to third parties, analytics sold to others, or any secondary purpose. If a new use case arises, we update the consent template and re-consent existing candidates.

### Data minimisation

We collect:

- Name, phone number (for WhatsApp)
- Professional information: role, experience, skills, availability, salary expectation, references
- CV (for white-collar roles)

We do NOT collect:
- ID card number, NHIS number, or national ID
- Next-of-kin
- Health data
- Religion, tribe, political affiliation

If a candidate volunteers any of the above (e.g. mentions their tribe in a message), we store the message but do not extract those attributes into structured fields.

### Accuracy

- Candidates can update their record by replying `UPDATE` on WhatsApp.
- The structured fact extraction (Workflow B/C) overwrites older facts with newer ones, keeping a history.
- Inaccurate records flagged by the candidate → Operations Lead corrects within 5 business days.

### Retention

- Active records: retained while active (`lastActivityAt` within 24 months).
- Archived: 24 months past `lastActivityAt`, record moved to an archived state, removed from active search.
- Cryptographic shred: 36 months past `lastActivityAt`, record PII (name, phone, CV, message bodies) is irrecoverably overwritten. A stub with Candidate ID, anonymised summary statistics (placement or not, category) is kept for firm analytics.
- Exception: candidates who affirmatively opt in to longer retention (`dataRetentionPolicy=extended_consent`).

Automated by Workflow G's nightly retention sweeper.

### Security

- TLS on all external connections (Nginx, Let's Encrypt auto-renewing).
- Database encryption at rest (Postgres with filesystem encryption on the VPS + B2 backup-side encryption).
- No `.env` in git; secrets in password manager.
- Principle of least privilege: n8n's DB user cannot read Twenty's DB and vice versa.
- Logs redact message bodies beyond 40 chars and never include transcribed voice content at info level.
- Annual access audit: who has VPS SSH, password manager access, Meta admin rights.

### Accountability

We maintain:

- This documentation (version controlled).
- A **Data Processing Register** — `docs/04-operations/data-processing-register.md` (TODO: generate in Week 0) — listing every data flow, lawful basis, retention, and sharing.
- Decision logs (ADRs).
- An annual review with the CEO + Operations Lead, recorded in `memory/decisions.md`.

## Candidate rights and how we honour them

| Right | How the candidate exercises it | System behaviour |
|---|---|---|
| Access | Reply `DATA` on WhatsApp | Workflow exports their record as a JSON document, sends via WhatsApp within 10 minutes |
| Rectification | Reply `UPDATE` | Conversational flow captures the correction; Operations Lead confirms within 5 business days |
| Erasure | Reply `DELETE` | Record marked `pending_deletion`, confirmation sent, purged from live data after 7 days, from backups at next monthly prune |
| Restriction | Reply `PAUSE` | `consentStatus=paused`, no outbound messages until the candidate resumes |
| Objection | Reply `STOP` | Treated as `refused`, equivalent to `DELETE` |
| Data portability | Reply `DATA` gives machine-readable JSON | Same as access |

## Breach notification

DPA requires notification to the DPC **within 72 hours** of becoming aware of a personal data breach likely to risk the rights of data subjects.

Our incident process:

1. Detection → lock down access (rotate credentials, disable affected accounts).
2. Within 4 hours: Operations Lead + CEO notified. Initial scope assessed.
3. Within 24 hours: preliminary report drafted (affected candidates, data types, root cause).
4. Within 72 hours: DPC notification using their prescribed form. Candidate notifications sent in parallel if risk is high.
5. Post-incident: root cause analysis + controls added, documented as an ADR.

The runbook (`runbook.md` §9) has the operational steps.

## Subcontractors (data processors)

We share candidate data, as a data controller, with these processors. Each has a DPA (data processing agreement) in place — verify in Week 0:

- Anthropic (Claude API) — message content, CV text
- Groq (transcribe) — audio content (voice notes in English/Pidgin), per ADR-0006
- Meta (WhatsApp Cloud, Facebook, Instagram) — messages, contact numbers
- X Corp (X API) — public post content only, no candidate PII
- Google (Calendar, Telegram-as-applicable) — interview calendar events; no candidate PII in Telegram posts
- Backblaze B2 — encrypted backups
- VPS provider (Hetzner/DO) — infrastructure; no direct data access but physical possession

Each of these is listed in the `data-processing-register.md` with the data categories shared.

## What we explicitly do NOT do

- Sell candidate data.
- Share candidate data between clients (Client X's applicants are not offered to Client Y by default — only if the candidate themselves consents via Workflow H re-engagement).
- Process children's data. If a candidate declares they are under 18, we politely decline and do not store their record.
- Use candidate data for advertising targeting.

## Annual compliance tasks

- Review this document (January).
- Rotate service credentials (January).
- Audit access to the VPS and the password vault (January).
- Re-verify each processor has a current DPA (January).
- Run a restore drill (monthly per `backup-dr.md`, but also confirmed in January).
- Review the consent template for plain-language clarity (January).

A calendar reminder for January lives on the Operations Lead's Google Calendar as a recurring event.
