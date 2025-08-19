# Azure Storage File Nerfing

An **event-driven security guardrail** for Azure Storage accounts with **Hierarchical Namespace (ADLS Gen2)** that prevents accidental execution of uploaded files by:

- **Removing execute permissions** from all uploaded files for owner, group, and other (prevents accidental execution on mounted filesystems)
- **Quarantining risky file types** by renaming them to `*.sus` (breaks Windows double-click execution)
- **Processing files in near real-time/on-demand** via Event Grid → Storage Queue → Azure Functions pipeline

> **Important**: This system does NOT block file uploads - users can still upload executables and scripts. Instead, it **interrupts accidental execution** by removing execute permissions and renaming dangerous file types. **Users should primarily be uploading data files**, not executables.

> **Philosophy**: We prevent accidents, not intent. If users deliberately rename files or re-add execute permissions, that's their choice. This system guards against unintentional execution vectors.

---

## Architecture Overview

```
[File Upload] → ADLS Gen2 Storage (HNS enabled)
       │
       ▼ BlobCreated event
   Event Grid ──(system identity)──→ Storage Queue
       │                               ▲
       ▼                               │ batched processing
Azure Function (Queue trigger) ────────┘
       │
       ├─ get_access_control() → remove execute permissions (owner/group/other)
       ├─ check extension against blocklist
       └─ atomic rename to *.sus + set metadata
```

### Why This Design

- **Cost-effective**: Event Grid + Consumption Functions scale to zero and cost pennies
- **Resilient**: Queue buffering handles traffic spikes; automatic retry with poison queue fallback
- **HNS-native**: Leverages POSIX ACLs and atomic renames for clean, race-free operations

---

## Security and Compliance

### Threat Model

This system mitigates:
- ✅ Accidental execution of malicious files via double-click
- ✅ Accidental execution on mounted filesystems (removed execute permissions)
- ✅ Unintentional running of uploaded executables and scripts

**Important**: This system allows uploads of any file type but interrupts execution paths. Users should primarily upload data files, not executables.

This system does NOT prevent:
- ❌ Users from uploading malicious files (uploads are allowed)
- ❌ Determined users from renaming files or adding execute permissions
- ❌ Execution via explicit invocation (e.g., `python malware.py.sus`)
- ❌ Social engineering or other attack vectors

### RBAC Requirements

| Identity | Role | Scope | Purpose |
|----------|------|-------|---------|
| Function Managed Identity | Storage Blob Data Owner | Target storage account | Read/write files, modify ACLs |
| Event Grid System Identity | Storage Queue Data Message Sender | Storage queue | Send events to processing queue |

### Data Privacy

- No file contents are read or stored outside the original storage account
- Only metadata (filename, timestamp) is added during quarantine process
- All operations use Azure managed identities - no credentials stored in code

---

## Quick Start

### Prerequisites

- Azure subscription with permissions to create resources and assign RBAC
- Storage account with **Hierarchical Namespace enabled** (ADLS Gen2)
- Azure CLI (`az`) installed and authenticated
- **Optional**: VS Code with Dev Containers extension for streamlined development

### 1. Clone and Setup Development Environment

```bash
git clone <your-repo-url>
cd azure-hns-quarantine

# Option A: VS Code Dev Container (recommended)
code .
# Choose "Reopen in Container" when prompted

# Option B: Local Python setup
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r function_app/requirements.txt
```

### 2. Configure Environment

```bash
# Configure deployment settings
# Edit .env with your subscription ID, resource group, and storage account names
cp .env.example .env

# Configure local development settings
# Edit local.settings.json with your actual connection strings and account names
cp function_app/local.settings.json.example function_app/local.settings.json

# Update these required values in local.settings.json:
#   - AzureWebJobsStorage: Your development storage connection string
#   - QueueConnection: Connection string to storage account with queue
#   - STORAGE_ACCOUNT: Your HNS-enabled storage account name
```

### 3. Deploy Infrastructure

```bash
# Deploy Function App, managed identity, RBAC, and Event Grid subscription
bash deploy/deploy.sh
```

### 4. Set Up Local Development Permissions (For local testing)

```bash
# Configure your environment variables
export HNS_ACCOUNT="your-storage-account-name"
export RG="your-resource-group"

# Grant your user account the necessary permissions for local development
bash function_app/local-acl.sh
```

### 5. Set Default ACLs (One-time per upload directory)

```bash
# Ensure new files inherit no execute permissions
bash infra/acl-setup.sh \
  SUBSCRIPTION_ID=<your-sub-id> \
  HNS_ACCOUNT=<your-storage-account> \
  FILESYSTEM=uploads \
  UPLOAD_PATH=incoming
```

---

## Configuration

### Environment Variables

Configure these in your Function App settings or `local.settings.json`:

| Variable | Default | Description |
|----------|---------|-------------|
| `STORAGE_ACCOUNT` | *required* | Name of your HNS-enabled storage account |
| `IS_HNS` | `true` | Must be `true` - this solution requires HNS features |
| `RENAME_MODE` | `blocklist` | `blocklist` (recommended) or `three` (rename any 3-char extension) |
| `BLOCKLIST` | `.exe,.com,.bat,.cmd,.scr,.msi,.msp,.ps1,.ps2,.vbs,.vbe,.js,.jse,.wsf,.wsh,.hta,.jar,.dll,.reg,.cpl,.lnk` | Comma-separated list of risky file extensions |
| `QueueConnection` | *required* | Connection string for the storage queue |

### Default Blocklist

The system blocks these extensions by default:
```
.exe, .com, .bat, .cmd, .scr, .msi, .msp, .ps1, .ps2, 
.vbs, .vbe, .js, .jse, .wsf, .wsh, .hta, .jar, .dll, 
.reg, .cpl, .lnk
```

### Queue Processing Configuration

Function batching is optimized in `host.json`:
- **Batch size**: 16 messages per execution
- **New batch threshold**: 8 messages
- **Max retries**: 5 attempts before poison queue
- **Visibility timeout**: 30 seconds

---

## How It Works

### File Processing Pipeline

1. **File uploaded** to HNS storage account
2. **Event Grid** captures `BlobCreated` event and forwards to Storage Queue
3. **Azure Function** processes queue messages in batches:
   - Strips execute permissions from file ACLs (`rwxr-xr-x` → `rw-r--r--`)
   - Checks filename against blocklist
   - If blocked: atomically renames to `filename.ext.sus`
   - Sets metadata: `sus=true`, `originalName`, `timestamp`

### Security Model

- **Managed Identity authentication** - no connection strings or keys in code
- **Principle of least privilege** - Function identity has minimal required permissions
- **Fail-safe design** - errors are logged and retried; poison queue captures persistent failures
- **Idempotent operations** - safe to reprocess the same file multiple times

---

## Development

### Local Development

```bash
# 1. Configure local settings (copy from example and edit)
cp function_app/local.settings.json.example function_app/local.settings.json

# 2. Edit local.settings.json and update these required values:
#    - AzureWebJobsStorage: Connection string to your development storage
#    - QueueConnection: Connection string to storage account with your queue
#    - STORAGE_ACCOUNT: Name of your HNS-enabled storage account

# 3. Set up local permissions (required for HNS operations)
# Edit function_app/local-acl.sh and set your environment variables:
export HNS_ACCOUNT="your-storage-account-name"
export RG="your-resource-group"
bash function_app/local-acl.sh

# 4. Start the Functions runtime locally
func start

# Test with sample queue messages (manually enqueue events to test processing)
```

### Code Quality

```bash
# Format code
black function_app/

# Lint
flake8 function_app/

# Update dependencies
pip-compile function_app/requirements.in -o function_app/requirements.txt
pip-sync function_app/requirements.txt
```

### Testing

Upload test files to verify the system:

```bash
# Upload a blocked file type
az storage blob upload \
  --account-name <storage-account> \
  --container-name uploads \
  --name "test.exe" \
  --file "some-test-file.exe"

# Verify it was renamed to test.exe.sus with metadata
az storage blob show \
  --account-name <storage-account> \
  --container-name uploads \
  --name "test.exe.sus"
```

---

## Deployment Options

### Automated Deployment (Recommended)

The `deploy/deploy.sh` script handles end-to-end deployment:
- Creates Function App with Python 3.11 runtime
- Assigns managed identity and required RBAC permissions
- Creates Event Grid subscription with proper routing
- Packages and deploys function code

### Manual Deployment Steps

If you prefer manual control:

1. **Create Function App**: Consumption plan, Python 3.11, Linux
2. **Enable managed identity** and assign **Storage Blob Data Owner** role
3. **Create Storage Queue** in your target storage account  
4. **Configure app settings** with required environment variables
5. **Create Event Grid subscription** filtering `BlobCreated` events to your queue
6. **Grant Event Grid identity** **Storage Queue Data Message Sender** role
7. **Deploy function code** via zip deployment or GitHub Actions

---

## Monitoring and Operations

### Logging and Observability

- **Application Insights** integration provides detailed execution telemetry
- **Structured logging** includes `container`, `path`, `action`, and `result` fields
- **Poison queue** captures messages that fail after 5 retry attempts

### Key Metrics to Monitor

- Queue depth and processing latency
- Function execution count and duration  
- Error rates and poison queue message count
- Storage account request rates and throttling

### Troubleshooting

**Function fails to start:**
- Ensure `ENABLE_ORYX_BUILD=true` for automatic dependency installation
- Verify all required app settings are configured

**Queue not receiving events:**
- Check Event Grid subscription is active and properly filtered
- Verify Event Grid identity has **Storage Queue Data Message Sender** role

**Files not being processed:**
- Check Function App logs in Application Insights
- Verify managed identity has **Storage Blob Data Owner** on target storage account
- Confirm `STORAGE_ACCOUNT` setting matches your HNS account name

---

## Cost Considerations

This solution is designed to be extremely cost-effective:

- **Event Grid**: First 100K operations/month free, then ~$0.60 per million
- **Azure Functions**: 1M executions + 400K GB-seconds free monthly  
- **Storage Queue**: ~$0.10 per million operations
- **Total cost**: Essentially zero for typical workloads, scales linearly with usage





