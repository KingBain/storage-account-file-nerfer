#!/usr/bin/env bash
set -euo pipefail

echo "[post-create] Installing Azure Functions Core Tools..."
npm install -g azure-functions-core-tools@4 --unsafe-perm

echo "[post-create] Installing system packages..."
sudo apt-get update -y
sudo apt-get install -y zip jq

echo "[post-create] Setting up Python venv..."
python -m venv .venv
source .venv/bin/activate
pip install --upgrade pip pip-tools

if [ -f function_app/requirements.in ]; then
  pip-compile function_app/requirements.in -o function_app/requirements.txt
fi

if [ -f function_app/requirements.txt ]; then
  pip-sync function_app/requirements.txt
fi

echo "[post-create] Dev container ready. Run 'az login' then 'func start'."
