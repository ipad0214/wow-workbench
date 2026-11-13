#!/usr/bin/env bash
# Deploy the Werkbank to jupiter: sync files (never .env, never data/), rebuild, restart, show status.
set -euo pipefail

HOST="${DEPLOY_HOST:-jupiter}"
REMOTE_DIR="/home/luna/srv/crafting-site"
cd "$(dirname "$0")"

# the addon download on the website (site/addon/Werkbank.zip, not in git)
addon/build.sh

# Excluded paths are also protected from --delete, so the user data in data/ stays untouched.
rsync -av --delete \
  --exclude '.env' --exclude '.git/' --exclude 'docs/' --exclude '.DS_Store' \
  --exclude '/addon/' --exclude '/test/' \
  --exclude 'data/' --exclude 'data-dev/' --exclude 'dev/' --exclude 'docker-compose.dev.yml' \
  ./ "$HOST:$REMOTE_DIR/"

ssh "$HOST" "set -e; cd $REMOTE_DIR
  test -f .env || { echo 'missing $REMOTE_DIR/.env (see .env.example)'; exit 1; }
  mkdir -p data   # must exist before compose, otherwise Docker creates it root-owned
  docker compose up -d --build && sleep 5 && docker compose ps"
