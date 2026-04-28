# Getting Started — Fresh-Clone Onboarding

For a developer cloning this repo for the first time. Gets you from `git clone` to a running stack with Phase 4 vouchers green.

**Assumed audience**: a software engineer comfortable with Linux, Docker, and basic networking. Not assumed: prior n8n / Twenty / WhatsApp Cloud familiarity — the docs cover those.

**Read the project constitution first**: [`CLAUDE.md`](../../CLAUDE.md). Five non-negotiable invariants live there; everything below assumes you've read them.

---

## 1. Prerequisites

| Tool | Version | Notes |
|---|---|---|
| **WSL2 Ubuntu 24.04** OR native Linux | — | Project pinned to Ubuntu 24.04 LTS (`.claude/memory/decisions.md`) |
| **Docker Desktop** + WSL integration | latest | If on Windows: Settings → Resources → WSL Integration → enable for your distro. ~5 GB images post-bring-up. |
| **git** | any | |
| **curl, jq, openssl** | recent | apt-installed; `sudo apt install -y jq` if missing |
| **python3** ≥ 3.10 | — | For `audit-twenty-schema.py` and the migration tooling |
| **espeak-ng** | optional | Only needed if regenerating `scripts/voucher/fixtures/voucher_sample.wav`; `sudo apt install -y espeak-ng` |
| **ngrok** | latest | Free tier; needed only for the WhatsApp webhook voucher |

Disk: ~10 GB free for Docker images + volumes. Memory: 6 GB to docker comfortable.

---

## 2. Clone and configure

```bash
git clone <repo-url> hr-automation
cd hr-automation

cp infrastructure/.env.example infrastructure/.env
```

Generate secrets (six values):

```bash
for var in TWENTY_APP_SECRET N8N_ENCRYPTION_KEY N8N_JWT_SECRET; do
  echo "${var}=$(openssl rand -hex 32)"
done
for var in TWENTY_DB_PASSWORD BOOKINGS_DB_PASSWORD N8N_DB_PASSWORD; do
  echo "${var}=$(openssl rand -hex 16)"
done
```

Paste the output into the corresponding `.env` lines. The DB passwords MUST be set before first `docker compose up` — Postgres init scripts run once.

---

## 3. External credentials you need to obtain

Each voucher proves one external API works. Skip vouchers for credentials you don't have yet — they're independent.

| Provider | What to get | Where | Goes into `.env` as |
|---|---|---|---|
| **Anthropic** (Claude) | API key (paid, ~$5 prepaid is plenty for vouchers) | https://console.anthropic.com → Settings → API Keys | `ANTHROPIC_API_KEY` |
| **Groq** (Whisper transcription) | API key (free tier — no card required) | https://console.groq.com → API Keys | `GROQ_API_KEY` |
| **Telegram** | Bot token + channel ID | DM `@BotFather` on Telegram → `/newbot`; create a public channel and add bot as admin | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHANNEL_ID` |
| **Google Calendar** | API key (read-only) | https://console.cloud.google.com → APIs & Services → Credentials → "Create credentials" → API key. Enable Calendar API. | `GOOGLE_API_KEY` |
| **Meta — WhatsApp + FB Page + IG** | App + WhatsApp Business + Page Access Token | https://developers.facebook.com → Apps → Create App → Business → add WhatsApp + Page products | `WHATSAPP_*` (5 vars), `META_PAGE_ID`, `META_PAGE_ACCESS_TOKEN` |
| **ngrok** | Auth token | https://dashboard.ngrok.com → Your Authtoken | runs locally; `ngrok config add-authtoken <token>` |
| **Twenty API key** | Generated from your local Twenty after step 5 below | local: Settings → API & Webhooks → Create | `TWENTY_API_KEY` |

Notes on the list:
- **OpenAI is intentionally absent** — the project pivoted away from OpenAI to Groq for transcription due to Ghana-region card-acceptance issues. See [ADR-0006](../05-decisions/ADR-0006-groq-whisper-pivot.md). The OpenAI voucher script is still in the repo as historical artifact (`scripts/voucher/openai-transcribe.sh`); don't run it unless you want to retry.
- **X (Twitter) is deferred** pending developer-access approval. No env vars needed yet.
- **Instagram is deferred** per ADR-0007 (forthcoming) — Meta's link refusal is structural, not time-based.

---

## 4. Bring up the stack

```bash
./scripts/bootstrap.sh                                          # prereq checks + dirs
docker compose -f infrastructure/docker-compose.yml up -d --wait
```

Expect ~2-10 min on first run (image pulls). After `--wait`, all 7 services should be healthy: `hr-twenty-db, hr-bookings-db, hr-redis, hr-twenty, hr-twenty-worker, hr-n8n, hr-nginx`. Plus `hr-migrate-bookings` ran one-shot.

Verify:

```bash
curl -s -o /dev/null -w "Twenty:  %{http_code}\n" http://localhost:3000/healthz
curl -s -o /dev/null -w "n8n:     %{http_code}\n" http://localhost:5678/healthz
docker exec hr-bookings-db psql -U n8n_bookings -d bookings -c "\dt"
```

All three should respond cleanly.

---

## 5. Twenty workspace + API key

1. Open http://localhost:3000 → sign up. Create the first workspace (use any email — local only).
2. Settings → Members → Roles → create role **`n8n-service`** with `DATA_MODEL`, `canReadAllObjectRecords`, `canUpdateAllObjectRecords`, `canSoftDeleteAllObjectRecords` permissions.
3. Settings → API & Webhooks → Create API key, bind to `n8n-service` role. Copy the JWT shown in the textarea on the keys page (per [ADR-0005](../05-decisions/ADR-0005-twenty-v2-migration.md)).
4. Paste into `infrastructure/.env` as `TWENTY_API_KEY=<jwt>`.

Smoke test:

```bash
curl -s -X POST "http://localhost:3000/metadata" \
  -H "Authorization: Bearer ${TWENTY_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { objects { edges { node { nameSingular labelSingular } } } }"}' | head -c 600
```

Should list built-in objects (workspaceMember, company, person, etc.).

---

## 6. Apply the Twenty schema

```bash
./scripts/audit-twenty-schema.py twenty-schema/migrations/V001__init_core_objects.json
./scripts/apply-twenty-schema.sh
```

Audit must pass before apply runs (it's wired as a pre-apply gate). Apply takes ~2 minutes (84 ops × 1.2s pacing). On success: 10 custom objects + 21 reverse-relation fields exist in your local Twenty.

If apply fails partway: `./scripts/reset-twenty-schema.sh --yes` cleans up, fix the issue, re-run. The codified recovery path is in [`twenty-schema/README.md`](../../twenty-schema/README.md).

---

## 7. Run vouchers

Each is independent. Run only those whose credentials you've populated.

```bash
./scripts/voucher/telegram.sh                # Telegram bot
./scripts/voucher/google-calendar.sh         # Google Calendar (Ghana holidays)
./scripts/voucher/anthropic.sh               # Claude Sonnet + Haiku
./scripts/voucher/groq-transcribe.sh         # Groq Whisper
./scripts/voucher/meta-fb.sh                 # Facebook Page post+delete
./scripts/voucher/meta-ig.sh                 # Instagram (skip-gates if META_IG_USER_ID empty)
./scripts/voucher/whatsapp-webhook.sh        # WhatsApp synthetic harness — see (a) below
```

**(a) WhatsApp webhook voucher prerequisites** (more setup than the others):
1. Import `n8n-workflows/communications/a0-whatsapp-webhook-handler.json` into n8n's UI
2. Create the Postgres credential `Bookings DB (n8n_bookings)` per [`a0-whatsapp-webhook-handler-NOTES.md`](../../n8n-workflows/communications/a0-whatsapp-webhook-handler-NOTES.md)
3. Activate the workflow
4. Run `./scripts/voucher/whatsapp-webhook.sh`

For Meta's actual verify-and-save step (against your real ngrok URL), follow the same NOTES.md.

---

## 8. Where to look first

| Question | Open |
|---|---|
| What is this project? | [`CLAUDE.md`](../../CLAUDE.md) + [`docs/00-foundations/philosophy.md`](philosophy.md) |
| What's the current build state? | [`.claude/memory/status.md`](../../.claude/memory/status.md) |
| What are we building right now? | [`plans/active-plan.md`](../../plans/active-plan.md) |
| What's the data model? | [`docs/01-data-model/twenty-crm-schema.md`](../01-data-model/twenty-crm-schema.md) |
| How does workflow X work? | [`docs/02-workflows/`](../02-workflows/) (one file per workflow) |
| Why did we choose X? | [`docs/05-decisions/`](../05-decisions/) (immutable ADRs) |
| What's been decided? | [`.claude/memory/decisions.md`](../../.claude/memory/decisions.md) |
| Map of all docs | [`docs/INDEX.md`](../INDEX.md) |
| Known follow-ups | [`plans/tier-2-followups.md`](../../plans/tier-2-followups.md) |

The full reading-order recipes for common tasks live in `docs/INDEX.md`.

---

## 9. Gotchas you'll probably hit

These are paid-for-already lessons. Each links to where it's documented.

- **Docker WSL2 integration not enabled** → bootstrap fails on docker version check. Settings → Resources → WSL Integration → toggle the distro on, Apply & Restart.
- **Twenty first-boot races on `core` schema** → if Twenty crashes during `database:init:prod`, drop the partial `core` schema and restart the container. See `.claude/memory/decisions.md` 2026-04-26 for the exact recovery.
- **nginx config edit not picked up after `nginx -s reload`** → single-file bind mount + atomic write = stale inode in container. `docker compose up -d --force-recreate --wait nginx` fixes it. See [`a0-whatsapp-webhook-handler-NOTES.md`](../../n8n-workflows/communications/a0-whatsapp-webhook-handler-NOTES.md) build-history #3.
- **n8n Code node `crypto is not defined`** → the sandbox blocks stdlib `require()` by default. `NODE_FUNCTION_ALLOW_BUILTIN=crypto` is already set on the n8n service in compose; if you add a workflow that needs another stdlib module, add it there too. Rule #12 in [`.claude/rules/n8n-workflows.md`](../../.claude/rules/n8n-workflows.md).
- **Postgres NOT NULL constraint trips** on a logging INSERT → cross-check the V-migration's NOT NULL columns; bind `$execution.id` for `workflow_errors`. Rule #13.
- **OpenAI billing rejection from Ghana** → use Groq instead. ADR-0006.

---

## 10. Asking for help

The project has subagent specialists for substantial work — `architect`, `workflow-builder`, `schema-designer`, `tester`, `code-reviewer`, `researcher`. The routing rules are in `CLAUDE.md`. For day-to-day "I'm stuck on X," start with the doc index and the rules; nine times out of ten the answer is one file away.

If something genuinely doesn't make sense after reading: that's a doc bug worth fixing. Open a PR.
