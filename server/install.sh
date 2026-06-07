#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/gokart-online"
SERVICE="/etc/systemd/system/gokart-online.service"

mkdir -p "$APP_DIR/data"
cp gokart-online-server.js package.json "$APP_DIR/"
cp gokart-online.service "$SERVICE"
chmod +x "$APP_DIR/gokart-online-server.js"

if ! command -v node >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y nodejs
  else
    echo "node is required but no apt-get was found" >&2
    exit 1
  fi
fi

systemctl daemon-reload
systemctl enable gokart-online
systemctl restart gokart-online
systemctl status gokart-online --no-pager
