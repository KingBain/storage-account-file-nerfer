#!/usr/bin/env bash
set -euo pipefail

# ==== EDIT THESE ====
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-your-subscription-id}"
HNS_ACCOUNT="${HNS_ACCOUNT:-your-user-storage-account}"  # Hierarchical Namespace enabled storage account
FILESYSTEM="${FILESYSTEM:-uploads}"     # container
UPLOAD_PATH="${UPLOAD_PATH:-incoming}"  # directory inside container
# ====================

az account set -s "$SUBSCRIPTION_ID"

# Ensure the directory exists
az storage fs directory create   --account-name "$HNS_ACCOUNT"   --file-system "$FILESYSTEM"   --name "$UPLOAD_PATH" >/dev/null || true

# Access ACL on the directory (dir needs x for traversal)
az storage fs access set   --account-name "$HNS_ACCOUNT" --file-system "$FILESYSTEM" --path "$UPLOAD_PATH"   --acl "user::rwx,group::r-x,other::---"

# Default ACLs for children (files inherit rw-, no x)
az storage fs access set   --account-name "$HNS_ACCOUNT" --file-system "$FILESYSTEM" --path "$UPLOAD_PATH"   --acl "default:user::rw-,default:group::r--,default:other::---,default:mask::rw-"

echo "Default no-exec ACLs applied to $FILESYSTEM/$UPLOAD_PATH"
