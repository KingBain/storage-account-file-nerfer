# Storage Account File Nerfer

This repo implements an **event‑driven safety layer** on an Azure Storage account with **Hierarchical Namespace (ADLS Gen2)**:

* Strip Linux execute bits on uploaded files (accidental exec guard for mounts).
* Quarantine risky Windows file types by renaming to `*.danger` (kills double‑click).
* Burst‑tolerant via **Event Grid → Storage Queue → Azure Functions (Consumption)**.

> If someone deliberately renames or re‑adds `+x`, that’s on them. We’re preventing accidents, not policing intent.

---

## Architecture (at a glance)

```
[User Uploads] → Storage (HNS)
       │  BlobCreated
       ▼
  Event Grid  —(system‑assigned identity)→  Storage Queue (ingest-events)
       ▼                                       ▲  batched dequeues
   Azure Function (Queue trigger)
       ├─ HNS: get_access_control → remove x → rename *.danger (atomic)
       └─ Tag metadata (quarantined=true, originalName)
```

### Why this design

* **Cheap**: Event Grid + Functions (Consumption) are basically free at modest volume.
* **Resilient**: Queue buffers spikes; function scales out automatically.
* **HNS‑only features**: POSIX ACLs + atomic rename are clean and fast.

---

## Repo layout

```
├── .devcontainer/           # Ready-to-code container (Python 3.11, Az CLI, Core Tools)
├── deploy/deploy.sh         # Creates Function App, identity, RBAC, queue, and zip‑deploys
├── infra/acl-setup.sh       # Sets default "no‑exec" ACLs on upload directory
└── function_app/            # Azure Functions (Python) project
    ├── QueueProcessor/      # Queue-triggered function
    ├── host.json            # batching + logging
    ├── requirements.txt     # runtime deps
    └── local.settings.json.example
```

---

## Prerequisites

* Azure subscription + permission to assign roles on the Storage account.
* Storage account **with HNS enabled** (ADLS Gen2).
* VS Code with Dev Containers *or* local Python 3.11 and Azure Functions Core Tools v4.
* Azure CLI (`az`), logged in to the correct tenant/sub.

Optional but recommended:

* **Azurite** for local `AzureWebJobsStorage` (the example uses `UseDevelopmentStorage=true`).

---

## Quick start (local dev)

1. Open the repo in VS Code and **Reopen in Container**.
2. Post‑create script will set up a `.venv` and install deps. If you’re not using devcontainers:

   ```bash
   python3.11 -m venv .venv && source .venv/bin/activate
   pip install -r function_app/requirements.txt
   ```
3. Copy `function_app/local.settings.json.example` → `function_app/local.settings.json` and edit values as needed for local testing.
4. Run the function host:

   ```bash
   func start
   ```

> Local events: you can enqueue test messages into the queue or call the handler with a mocked body.

---

## Bootstrap HNS ACLs (one‑time per upload path)

Set default ACLs so **new files inherit no execute bit**:

```bash
bash infra/acl-setup.sh \
  SUBSCRIPTION_ID=<subid> \
  HNS_ACCOUNT=<your-hns-storage-account> \
  FILESYSTEM=uploads \
  UPLOAD_PATH=incoming
```

This ensures directory traversal works but **files default to `rw-`** (no `x`).

---

## Deploy to Azure (Consumption plan)

Script creates a Function App + managed identity, grants RBAC, creates queue, and zip‑deploys code. Before first deploy, enable Oryx build so the platform installs `requirements.txt` automatically.

```bash
# once per app (or add these lines into deploy.sh after function creation)
az functionapp config appsettings set -g <RG> -n <APP> --settings \
  SCM_DO_BUILD_DURING_DEPLOYMENT=true ENABLE_ORYX_BUILD=true

# deploy
bash deploy/deploy.sh \
  SUBSCRIPTION_ID=<subid> RG=<rg> LOC=canadacentral \
  FUNC_NAME=hns-quarantine-func HNS_ACCOUNT=<your-hns-storage-account> \
  FILESYSTEM=uploads QUEUE_NAME=ingest-events
```

### Wire Event Grid → Queue & grant sender role

The script prints an example `az eventgrid event-subscription create`. After creating it, assign **Storage Queue Data Message Sender** to that subscription’s identity on the queue resource scope:

```bash
EG_PRINCIPAL_ID=$(az eventgrid event-subscription show \
  --name hns-quarantine-egsub --source-resource-id "$STORAGE_ID" \
  --query identity.principalId -o tsv)

QUEUE_SCOPE="/subscriptions/<subid>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<account>/queueServices/default/queues/ingest-events"

az role assignment create \
  --assignee-object-id "$EG_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Queue Data Message Sender" \
  --scope "$QUEUE_SCOPE"
```

---

## Configuration knobs

App settings (Function App → Configuration → Application settings):

* `STORAGE_ACCOUNT` — HNS account name.
* `IS_HNS` — `true` (we rely on HNS features).
* `RENAME_MODE` — `blocklist` (recommended) or `three` (rename any 3‑letter ext; usually too aggressive).
* `BLOCKLIST` — default: `.exe,.com,.bat,.cmd,.scr,.msi,.msp,.ps1,.ps2,.vbs,.vbe,.js,.jse,.wsf,.wsh,.hta,.jar,.dll,.reg,.cpl,.lnk`.
* `QueueConnection` — connection string to the storage account that hosts the **queue** (can be the same HNS account).

`host.json` (already tuned):

```json
{
  "extensions": {"queues": {"batchSize": 16, "newBatchThreshold": 8, "maxDequeueCount": 5, "visibilityTimeout": "00:00:30"}}
}
```

---

## How the function behaves

* **On each message**: parse container/path → if HNS, `get_access_control()` and flip execute slots off; if name matches policy → atomic `rename_file` to `*.danger`; set metadata (`quarantined=true`, `originalName`, timestamp).
* **On non‑HNS** (not our target): would fall back to copy→delete rename (kept in code for portability).

---

## End‑to‑end test

1. Upload `incoming/hello.exe` to the `uploads` filesystem.
2. Confirm the blob becomes `incoming/hello.exe.danger` and has metadata `quarantined=true`.
3. If you mount the storage (ABFS/NFS/blobfuse2), verify `+x` is cleared on files.

---

## Ops & monitoring

* **Poison queue**: after 5 failed dequeues, messages land in `<queue>-poison`. Investigate and re‑queue after fix.
* **App Insights**: created by default on Function Apps. Check logs for `Quarantined` entries.
* **Soft delete/versioning**: enable on containers for easy restore if a rename goes sideways.

---

## Security model & limits (be realistic)

* We prevent accidental execution. A determined user can download and `chmod +x` or rename.
* Default ACLs + function enforcement cover mounted access paths. Consider `noexec` mount option wherever practical.
* Use **Managed Identity**; no keys are stored in code. RBAC scopes:

  * Function MI → **Storage Blob Data Owner** on HNS account (needed for ACL+rename)
  * Event Grid identity → **Storage Queue Data Message Sender** on the queue

---

## Costs (rule of thumb)

* Event Grid: first 100k ops/month free; then dollars per million.
* Functions (Consumption): 1M exec + 400k GB‑s free/month; we’re doing tiny bursts.
* Storage Queue: fractions of a cent per 10k ops.
* Net: essentially noise unless you’re ingesting at massive scale.

---

## Troubleshooting

* **Functions starts but fails on import** → Ensure Oryx build settings are present or publish via `func azure functionapp publish <app> --python`.
* **Queue not receiving events** → Grant Event Grid identity the **Queue Data Message Sender** role on the queue.
* **Regex crash** in `_is_dangerous` → The pattern must be:

  ```python
  m = re.search(r"\.([A-Za-z0-9]{1,10})$", name)
  ```
* **HNS APIs failing** → Confirm `STORAGE_ACCOUNT` is set and MI has **Blob Data Owner**.

---

## Common dev tasks

* **Run locally**: `func start`
* **Lint**: `pip install black flake8 && black --check function_app && flake8 function_app`
* **Bump deps**: `pip install pip-tools && pip-compile -o function_app/requirements.txt && pip-sync function_app/requirements.txt`
* **Publish (alt)**: `func azure functionapp publish <app> --python`

---

## Contributing

* Keep logic in `QueueProcessor/__init__.py` small and testable.
* Prefer adding extensions to the **blocklist** rather than flipping to `three`.
* PRs should include a short note on expected cost/scale impact if changing triggers/batching.
