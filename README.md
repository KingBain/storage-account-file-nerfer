# Azure HNS: No-Exec + Quarantine (\.danger) Function

This package contains:
- An **Azure Functions (Python)** app that:
  - removes execute bits on ADLS Gen2 (HNS) files (accidental Linux exec protection)
  - renames risky files by appending `\.danger` (accidental Windows exec protection)
- CLI scripts to set **default ACLs** (no-exec) on your upload directory
- A deploy script to create the Function App (Consumption), wire permissions, and push code
- An Event Grid → Storage Queue wiring command

> Minimal cost, burst-ready: Event Grid → Storage Queue (buffer) → Function. HNS required for ACL edits and atomic rename.

## Quick start

1. **Edit variables** in `deploy/deploy.sh` and `infra/acl-setup.sh`.
2. Run `infra/acl-setup.sh` once to set default ACLs (no exec) on your upload path.
3. Run `deploy/deploy.sh` to create the Function App (or point to existing), assign identity, grant RBAC, set app settings, and deploy the zip.
4. Create the Event Grid subscription using the command printed by `deploy.sh` (or run the included example).

See comments in each script for details.
