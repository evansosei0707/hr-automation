#!/usr/bin/env bash
# Bootstrap — one-time local setup.
# Usage: ./scripts/bootstrap.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> HR Automation — bootstrap"
echo "    Root: $ROOT"

# ─────────────────────────────────────────────
# Prerequisite checks
# ─────────────────────────────────────────────
need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found on PATH"; exit 1; }
}

echo "==> Checking prerequisites"
need docker
need git
# docker compose plugin v2 comes as a subcommand; test it
docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose v2 plugin not installed"; exit 1; }
echo "    ok: docker, docker compose, git"

# ─────────────────────────────────────────────
# .env
# ─────────────────────────────────────────────
ENV_FILE="$ROOT/infrastructure/.env"
EXAMPLE="$ROOT/infrastructure/.env.example"

if [ ! -f "$ENV_FILE" ]; then
  echo "==> Creating .env from .env.example"
  cp "$EXAMPLE" "$ENV_FILE"
  echo "    Edit $ENV_FILE to fill in real values before running the stack."
else
  echo "==> .env exists — skipping"
fi

# ─────────────────────────────────────────────
# Directories that must exist
# ─────────────────────────────────────────────
mkdir -p "$ROOT/secrets"
chmod 700 "$ROOT/secrets"
mkdir -p "$ROOT/logs"

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────
cat <<'EOF'

==> Bootstrap complete.

Next steps:
  1. Edit infrastructure/.env with real values.
  2. Start the stack:
        docker compose -f infrastructure/docker-compose.yml up -d
  3. Verify health:
        docker compose -f infrastructure/docker-compose.yml ps
  4. Open services:
        Twenty:  http://localhost:3000
        n8n:     http://localhost:5678

If anything fails, see docs/04-operations/runbook.md.
EOF
