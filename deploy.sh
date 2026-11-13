#!/usr/bin/env bash
# Deploy the crafting site to jupiter: sync files (never .env), rebuild, restart, show status.
set -euo pipefail

HOST="${DEPLOY_HOST:-jupiter}"
REMOTE_DIR="/home/luna/srv/crafting-site"
cd "$(dirname "$0")"

rsync -av --delete \
  --exclude '.env' --exclude '.git/' --exclude 'docs/' --exclude '.DS_Store' \
  ./ "$HOST:$REMOTE_DIR/"

ssh "$HOST" "cd $REMOTE_DIR && test -f .env || { echo 'missing $REMOTE_DIR/.env (see .env.example)'; exit 1; }
  docker compose up -d --build && sleep 5 && docker compose ps"
