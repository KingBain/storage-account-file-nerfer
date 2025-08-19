#!/usr/bin/env bash
set -euo pipefail

# ==== EDIT THESE ====
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-your-subscription-id}"
RG="${RG:-your-resource-group}"  # Resource group for the function app
LOC="${LOC:-canadacentral}"
FUNC_NAME="${FUNC_NAME:-hns-quarantine-func}"
PLAN=""  # Consumption plan auto-created by az functionapp create
FUNC_STORAGE="${FUNC_STORAGE:-safuncquarantine$RANDOM}"   # runtime storage for function app (not your HNS account)
HNS_ACCOUNT="${HNS_ACCOUNT:-userscratchspace54}"

FILESYSTEM="${FILESYSTEM:-uploads}"            # container / filesystem
QUEUE_NAME="${QUEUE_NAME:-ingest-events}"      # must match function.json
# Optional: blocklist override
BLOCKLIST="${BLOCKLIST:-.exe,.com,.bat,.cmd,.scr,.msi,.msp,.ps1,.ps2,.vbs,.vbe,.js,.jse,.wsf,.wsh,.hta,.jar,.dll,.reg,.cpl,.lnk}"
# ====================

echo "Using subscription: $SUBSCRIPTION_ID"
az account set -s "$SUBSCRIPTION_ID"

# Resource group
#az group create -n "$RG" -l "$LOC" >/dev/null

# Function runtime storage (separate, tiny, cheap)
az storage account create -g "$RG" -n "$FUNC_STORAGE" -l "$LOC"   --sku Standard_LRS --kind StorageV2 --https-only true >/dev/null

# Function app (Consumption, Python 3.11)
az functionapp create -g "$RG" -n "$FUNC_NAME" --consumption-plan-location "$LOC"  --os-type Linux   --runtime python --runtime-version 3.11 --functions-version 4   --storage-account "$FUNC_STORAGE" >/dev/null

# Assign system identity
IDENTITY_ID=$(az functionapp identity assign -g "$RG" -n "$FUNC_NAME" --query principalId -o tsv)
echo "Assigned managed identity: $IDENTITY_ID"

# Grant RBAC on the HNS storage (Blob Data Owner: needed for ACL + rename)
HNS_SCOPE=$(az storage account show -g "$RG" -n "$HNS_ACCOUNT" --query id -o tsv 2>/dev/null || true)
if [[ -z "$HNS_SCOPE" ]]; then
  # If the HNS account is in a different RG/sub, fetch its resource id explicitly:
  HNS_SCOPE=$(az storage account show -n "$HNS_ACCOUNT" --query id -o tsv)
fi
az role assignment create --assignee-object-id "$IDENTITY_ID"   --assignee-principal-type ServicePrincipal   --role "Storage Blob Data Owner" --scope "$HNS_SCOPE" >/dev/null

# Create the queue in the HNS account (Queue service)
az storage queue create --name "$QUEUE_NAME"   --account-name "$HNS_ACCOUNT" >/dev/null

# Connection string for queue trigger (stored in app settings)
# (You can swap this for Key Vault later if desired.)
QUEUE_CONN=$(az storage account show-connection-string -n "$HNS_ACCOUNT" -o tsv)
az functionapp config appsettings set -g "$RG" -n "$FUNC_NAME" --settings   "QueueConnection=$QUEUE_CONN"   "STORAGE_ACCOUNT=$HNS_ACCOUNT"   "IS_HNS=true"   "RENAME_MODE=blocklist"   "BLOCKLIST=$BLOCKLIST" >/dev/null

echo  "Build zip and deploy"
echo 

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIP_PATH="$THIS_DIR/../function_app.zip"
( cd "$THIS_DIR/../function_app" && zip -qr "$ZIP_PATH" . )
az functionapp deployment source config-zip -g "$RG" -n "$FUNC_NAME" --src "$ZIP_PATH"

echo "Deployed function app: $FUNC_NAME"
echo
echo "Now wire Event Grid -> Storage Queue (edge filter recommended):"
STORAGE_ID=$(az storage account show -n "$HNS_ACCOUNT" --query id -o tsv)
QUEUE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$(az storage account show -n "$HNS_ACCOUNT" --query resourceGroup -o tsv)/providers/Microsoft.Storage/storageAccounts/$HNS_ACCOUNT/queueServices/default/queues/$QUEUE_NAME"

echo "Example command:"
cat <<EOF
az eventgrid event-subscription create   --name hns-quarantine-egsub   --source-resource-id "$STORAGE_ID"   --endpoint-type storagequeue   --endpoint "$QUEUE_ID"   --delivery-identity systemassigned   --included-event-types Microsoft.Storage.BlobCreated   --advanced-filter subjectEndsWith .exe .com .bat .cmd .scr .msi .msp .ps1 .ps2 .vbs .vbe .js .jse .wsf .wsh .hta .jar .dll .reg .cpl .lnk
EOF

echo
echo "Done."


az eventgrid event-subscription create   --name hns-quarantine-egsub   --source-resource-id "/subscriptions/bc4bcb08-d617-49f4-b6af-69d6f10c240b/resourceGroups/Bainer/providers/Microsoft.Storage/storageAccounts/userscratchspace54"   --endpoint-type storagequeue   --endpoint "/subscriptions/ScSx-SP-DataSolutions-HiddenThylacine/resourceGroups/Bainer/providers/Microsoft.Storage/storageAccounts/userscratchspace54/queueServices/default/queues/ingest-events"   --delivery-identity systemassigned   --included-event-types Microsoft.Storage.BlobCreated   --advanced-filter subjectEndsWith .exe .com .bat .cmd .scr .msi .msp .ps1 .ps2 .vbs .vbe .js .jse .wsf .wsh .hta .jar .dll .reg .cpl .lnk