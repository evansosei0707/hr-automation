# Decisions Log

Running log of decisions made, in chronological order. Lightweight — for anything architectural, write an ADR under `docs/05-decisions/` and link to it from here.

---

## 2026-04-24 — Project scaffolded

Initial harness created. Five non-negotiables baked into `CLAUDE.md` from the v3 research round:

1. No direct writes to Twenty Postgres.
2. No Twenty rollup / formula / action-button assumptions.
3. Redis conversation lock: 60s + Lua heartbeat (15s) + Lua CAS release.
4. No LinkedIn / Blotato in v1.
5. No attempted ASR for Ghanaian local languages.

See:
- ADR-0001 — drop Blotato
- ADR-0002 — defer LinkedIn
- ADR-0003 — Google Calendar holidays
- ADR-0004 — drop Khaya ASR

## 2026-04-24 — Scope freeze for v1

Out of scope for v1, deferred to Phase 2:
- LinkedIn posting
- Inbound Telegram messaging (posts only)
- Instagram Reels / video
- Mobile app (WhatsApp is the app)
- Payment processing
- Multi-region / HA
- PITR backups

## 2026-04-24 — Calibration window = 2 weeks

Every AI-assisted decision is human-reviewed for the first 2 weeks after launch. See `docs/04-operations/calibration.md`.

## 2026-04-24 — Technology pins

- Ubuntu 24.04 LTS
- Postgres 16
- Redis 7
- Docker Compose (single node)
- Anthropic Claude Sonnet 4.6 (smart) + Haiku 4.5 (cheap)
- OpenAI gpt-4o-mini-transcribe

Pin specific versions; no `-latest` tags in production.

---

## Format for new entries

```
## YYYY-MM-DD — Short title

Context: ...
Decision: ...
Link: (ADR path if applicable)
```
