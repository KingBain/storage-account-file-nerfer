#!/usr/bin/env bash
set -euo pipefail


# Resolve repo root and auto-load .env if present (for local development)
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$THIS_DIR/../.env}"
if [[ -f "$ENV_FILE" ]]; then
  echo "Loading env from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Choose Python (defaults to python3, falls back to python)
PYTHON_BIN="${PYTHON_BIN:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then PYTHON_BIN=python; else echo "Error: python3/python not found on PATH." >&2; exit 1; fi
fi

# ==== EDIT THESE ====
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-your-subscription-id}"
RG="${RG:-your-resource-group}"
LOC="${LOC:-canadacentral}"

FUNC_NAME="${FUNC_NAME:-hns-quarantine-func}"
FUNC_STORAGE="${FUNC_STORAGE:-filenerfer$RANDOM}"       # runtime storage for Function App

HNS_ACCOUNT="${HNS_ACCOUNT:-userstorage$RANDOM}"        # target HNS (ADLS Gen2) account
FILESYSTEM="${FILESYSTEM:-uploads}"                      # container / filesystem name
QUEUE_NAME="${QUEUE_NAME:-ingest-events}"                # must match function.json

# Optional: blocklist override
BLOCKLIST="${BLOCKLIST:-.exe,.com,.bat,.cmd,.scr,.msi,.msp,.ps1,.ps2,.vbs,.vbe,.js,.jse,.wsf,.wsh,.hta,.jar,.dll,.reg,.cpl,.lnk}"
# ====================

echo "Using subscription: $SUBSCRIPTION_ID"
az account set -s "$SUBSCRIPTION_ID"

# Make sure providers are registered (idempotent)
az provider register -n Microsoft.EventGrid >/dev/null
az provider register -n Microsoft.Storage   >/dev/null

echo "== Create runtime storage account (for Function host) =="
az storage account create -g "$RG" -n "$FUNC_STORAGE" -l "$LOC" \
  --sku Standard_LRS --kind StorageV2 --https-only true >/dev/null

echo "== Create HNS (ADLS Gen2) storage account (target) =="
# If it already exists, this is a no-op.
az storage account create -g "$RG" -n "$HNS_ACCOUNT" -l "$LOC" \
  --sku Standard_LRS --kind StorageV2 --https-only true \
  --hns true >/dev/null

echo "== Create Function App (Consumption, Python 3.11) =="
az functionapp create \
  -g "$RG" -n "$FUNC_NAME" \
  --consumption-plan-location "$LOC" \
  --os-type Linux --runtime python --runtime-version 3.11 --functions-version 4 \
  --storage-account "$FUNC_STORAGE" >/dev/null

# (Optional) Assign system identity — not required for the simple Event Grid delivery we use below,
# but handy if your function code later uses DefaultAzureCredential against HNS.
echo "== Assign managed identity to Function App (optional) =="
IDENTITY_ID=$(az functionapp identity assign -g "$RG" -n "$FUNC_NAME" --query principalId -o tsv)
echo "Assigned managed identity: $IDENTITY_ID"

# If you plan to use MI in your function code for HNS operations, grant Blob Data Owner.
HNS_SCOPE=$(az storage account show -g "$RG" -n "$HNS_ACCOUNT" --query id -o tsv)
az role assignment create \
  --assignee-object-id "$IDENTITY_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Owner" \
  --scope "$HNS_SCOPE" >/dev/null || true

echo "== Ensure filesystem (container) and queue exist on HNS account =="
az storage container create --name "$FILESYSTEM" --account-name "$HNS_ACCOUNT" >/dev/null || true
az storage queue create     --name "$QUEUE_NAME"  --account-name "$HNS_ACCOUNT" >/dev/null || true

echo "== Set app settings for the Function App =="
QUEUE_CONN=$(az storage account show-connection-string -n "$HNS_ACCOUNT" -o tsv)
az functionapp config appsettings set -g "$RG" -n "$FUNC_NAME" --settings \
  "QueueConnection=$QUEUE_CONN" \
  "STORAGE_ACCOUNT=$HNS_ACCOUNT" \
  "IS_HNS=true" \
  "RENAME_MODE=blocklist" \
  "BLOCKLIST=$BLOCKLIST" \
  "SCM_DO_BUILD_DURING_DEPLOYMENT=false" \
  "ENABLE_ORYX_BUILD=false" \
  "WEBSITE_RUN_FROM_PACKAGE=1" >/dev/null

echo "== Build and zip function_app/ =="
pushd "$THIS_DIR/../function_app" >/dev/null
  rm -rf .python_packages wheelhouse
  "$PYTHON_BIN" -m pip install --upgrade pip >/dev/null
  if [[ -f requirements.txt ]]; then
    "$PYTHON_BIN" -m pip wheel -r requirements.txt -w wheelhouse
    "$PYTHON_BIN" -m pip install --no-index --find-links=wheelhouse \
      -r requirements.txt \
      --target .python_packages/lib/site-packages
  fi
popd >/dev/null

ZIP_PATH="$THIS_DIR/../function_app.zip"
( cd "$THIS_DIR/../function_app" && \
  zip -qr "$ZIP_PATH" . \
    -x ".venv/*" "__pycache__/*" "wheelhouse/*" "*.pyc" "*.pyo" )

echo "== Deploy zip package =="
az functionapp deployment source config-zip -g "$RG" -n "$FUNC_NAME" --src "$ZIP_PATH" >/dev/null

echo "== Create Event Grid subscription (BlobCreated -> Storage Queue) =="
STORAGE_ID=$(az storage account show -g "$RG" -n "$HNS_ACCOUNT" --query id -o tsv)
QUEUE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$HNS_ACCOUNT/queueServices/default/queues/$QUEUE_NAME"

# NOTE: Using stable 'endpoint' form (no preview flags, no MI delivery).
# If you want to filter only certain extensions, append --advanced-filter subjectEndsWith .exe .bat ... etc.
EGSUB_NAME="${EGSUB_NAME:-hns-egsub}"

# BLOCKLIST=".exe,.com,.bat,..."
IFS=',' read -r -a EXTS <<< "$BLOCKLIST"

az eventgrid event-subscription create \
  --name "$EGSUB_NAME" \
  --source-resource-id "$STORAGE_ID" \
  --endpoint-type storagequeue \
  --endpoint "$QUEUE_ID" \
  --included-event-types Microsoft.Storage.BlobCreated \
  --advanced-filter subject StringEndsWith "${EXTS[@]}"


echo
echo "== Done =="
echo "Function App: $FUNC_NAME"
echo "Runtime SA  : $FUNC_STORAGE"
echo "HNS SA      : $HNS_ACCOUNT"
echo "Filesystem  : $FILESYSTEM"
echo "Queue       : $QUEUE_NAME"
echo "EG Sub      : $EGSUB_NAME"
echo

echo "TIP: If your HNS account has firewall/VNET rules, enable 'Allow trusted Microsoft services' so Event Grid can deliver to the queue."
