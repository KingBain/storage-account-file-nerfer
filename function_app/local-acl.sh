
STG="$HNS_ACCOUNT"      # e.g. userstoragespace54
FS="uploads"
ME=$(az ad signed-in-user show --query userPrincipalName -o tsv)

az role assignment create \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --role "Storage Blob Data Owner" \
  --scope $(az storage account show -n "$HNS_ACCOUNT" -g "$RG" --query id -o tsv)

az storage fs access set \
  --account-name "$STG" \
  --file-system "$FS" \
  --path "/" \
  --acl "user:$ME:rwx" \
  --auth-mode login

az storage fs access set-recursive \
  --account-name "$STG" \
  --file-system "$FS" \
  --path "/" \
  --acl "user::rwx,group::r-x,other::---,mask::rwx,user:$ME:rwx,default:user::rwx,default:group::r-x,default:other::---,default:mask::rwx,default:user:$ME:rwx" \
  --auth-mode login
