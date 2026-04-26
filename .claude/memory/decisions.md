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

## 2026-04-26 — Twenty image pin: v0.60 → v2.1.0

The original scaffolding pinned `twentycrm/twenty:v0.60`, which does not exist on
Docker Hub. Twenty's published lineage jumped to v1.x and is now at v2.1.0
(released 2026-04-24). Pinned to `v2.1.0` for Phase 1 bring-up.

Risk carried forward: `docs/01-data-model/twenty-crm-schema.md` was authored
against the v0.60-era assumption set. Before Phase 2 dispatches `schema-designer`,
`researcher` must verify the v2 GraphQL metadata API shape (custom object
creation, field types, relations).

## 2026-04-26 — Phase 1 scaffolding fixes

Bring-up surfaced several gaps in the original scaffolding. All fixed and committed
to `infrastructure/`:

1. **n8n user/db not provisioned.** `init-bookings-db.sql` created only the
   `n8n_bookings` superuser; n8n expected a separate `n8n` role + `n8n` database
   for its internal storage. Added `infrastructure/postgres/init-n8n-user.sh`
   which runs after the SQL init and provisions both. bookings-db now also
   accepts `N8N_DB_USER/PASSWORD/NAME` env vars to feed that script.

2. **Twenty v2 needs a worker service.** v2 splits into `server` + `worker`
   (BullMQ on Redis). Added `twenty-worker` service mirroring the official
   reference compose. Worker shares `twenty_server_data` volume with the server
   and depends on `twenty:service_healthy`. `DISABLE_DB_MIGRATIONS=true` and
   `DISABLE_CRON_JOBS_REGISTRATION=true` on worker so it doesn't fight the server.

3. **Twenty v2 requires REDIS_URL.** Added `REDIS_URL=redis://redis:6379` and a
   `redis: condition: service_healthy` depends_on entry to twenty.

4. **Twenty needs a /healthz healthcheck.** Added one with `start_period: 60s`
   so the worker can `depends_on twenty: service_healthy` cleanly.

5. **Redis needs `--maxmemory-policy noeviction`** for BullMQ reliability.
   Added to redis command line.

6. **n8n: enable task runners.** Set `N8N_RUNNERS_ENABLED=true` on n8n env to
   silence the deprecation warning and align with where n8n is heading.

7. **Twenty's first-boot init has a race-condition trap.** Twenty's entrypoint
   checks "does `core` schema exist?" — if yes, skips `database:init:prod` and
   only runs upgrade migrations. If `database:init:prod` is interrupted partway
   (creates `core` schema but not its tables), subsequent restarts take the
   wrong branch and Twenty boots with no usable schema. Workaround when this is
   observed: `DROP SCHEMA core CASCADE` on the twenty DB and restart the twenty
   container. **TODO:** add this to `docs/04-operations/runbook.md` once the
   runbook gets its first real entries.

Open question deferred to ADR: shared-vs-dedicated Redis. Currently all three
tenants (Twenty BullMQ, n8n BullMQ, our app's locks) share one Redis with no
key-prefix isolation. Acceptable for Phase 1; needs an architect ADR before
production if collisions are observed in workflow testing.

---

## Format for new entries

```
## YYYY-MM-DD — Short title

Context: ...
Decision: ...
Link: (ADR path if applicable)
```
