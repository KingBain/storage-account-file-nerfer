import json
import logging
import os
import re
from datetime import datetime

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.storage.filedatalake import DataLakeServiceClient

# Config from app settings / local.settings.json
ACCOUNT = os.environ.get("STORAGE_ACCOUNT")  # e.g., userscratchspace54
IS_HNS = os.getenv("IS_HNS", "true").lower() == "true"
RENAME_MODE = os.getenv("RENAME_MODE", "blocklist")
BLOCKLIST = {
    e.strip().lower()
    for e in os.getenv(
        "BLOCKLIST",
        ".exe,.com,.bat,.cmd,.scr,.msi,.msp,.ps1,.ps2,.vbs,.vbe,.js,.jse,.wsf,.wsh,.hta,.jar,.dll,.reg,.cpl,.lnk",
    ).split(",")
}

# --- Redaction helper for safe logging ---------------------------------------
_SENSITIVE_PATTERNS = [
    # SAS or signed query params: ...?sig=...  or &sig=...
    (re.compile(r"([?&](?:sig|token|secret|password)=[^&\s\"']+)"), r"\1<REDACTED>"),
    # Common header/value keys inside JSON blobs
    (
        re.compile(r'("Authorization"\s*:\s*")([^"]+)(")', re.IGNORECASE),
        r"\1<REDACTED>\3",
    ),
    (re.compile(r'("accountKey"\s*:\s*")([^"]+)(")', re.IGNORECASE), r"\1<REDACTED>\3"),
]


def _redact(s: str) -> str:
    if not s:
        return s
    out = s
    for pat, repl in _SENSITIVE_PATTERNS:
        out = pat.sub(repl, out)
    return out


# -----------------------------------------------------------------------------


def _is_dangerous(name: str) -> bool:
    # Skip if already marked .sus
    if name.lower().endswith(".sus"):
        return False
    dot = name.rfind(".")
    if dot == -1:
        return False
    ext = name[dot:].lower()
    if RENAME_MODE == "three":
        return len(ext) == 4  # ".???"
    return ext in BLOCKLIST


def _strip_exec_bits_if_hns(file_client) -> None:
    """Turn rwxr-xr-x style perms into rw-r--r-- (remove execute bits)."""
    try:
        acl = file_client.get_access_control()
        perms = list(acl.get("permissions", ""))
        if len(perms) != 9:
            return
        changed = False
        for i in (2, 5, 8):  # owner/group/other execute
            if perms[i] == "x":
                perms[i] = "-"
                changed = True
        if changed:
            file_client.set_access_control(permissions="".join(perms))
            logging.info("Cleared +x on path=%s", file_client.path_name)
    except Exception as ex:
        logging.warning(
            "ACL strip failed for path=%s err=%s", file_client.path_name, ex
        )


def _parse_container_path(ev: dict) -> tuple[str | None, str | None]:
    subject = ev.get("subject") or ""
    # Example: /blobServices/default/containers/<fs>/blobs/path/to/file
    try:
        parts = subject.split("/")
        cidx = parts.index("containers")
        bidx = parts.index("blobs")
        container = parts[cidx + 1]
        path = "/".join(parts[bidx + 1 :])
        return container, path
    except Exception:
        pass
    # Fallback to URL
    url = (ev.get("data") or {}).get("url") or ""
    if url.startswith("https://"):
        try:
            u = url.split("/")
            return u[3], "/".join(u[4:])
        except Exception:
            return None, None
    return None, None


def main(msg: func.QueueMessage) -> None:
    if not IS_HNS:
        logging.error("IS_HNS=false is not supported in this build.")
        return
    if not ACCOUNT:
        logging.error("STORAGE_ACCOUNT app setting is required.")
        return

    raw = msg.get_body().decode("utf-8")

    # 1) Always log the raw event (redacted)
    logging.info("Event (raw, redacted) => %s", _redact(raw))

    # 2) Parse JSON
    try:
        ev = json.loads(raw)
    except Exception:
        logging.warning("Skipping non-JSON body")
        return

    # 3) Log key fields we rely on
    subj = ev.get("subject")
    url = (ev.get("data") or {}).get("url")
    logging.info("Parsed fields: subject=%s url=%s", subj, url)

    # 4) Resolve container/path and log what we found
    container, path = _parse_container_path(ev)
    if not container or not path:
        logging.warning("Unable to parse container/path from event.")
        return
    logging.info("Resolved: container=%s path=%s", container, path)

    name = path.rsplit("/", 1)[-1]

    dfs_uri = f"https://{ACCOUNT}.dfs.core.windows.net"
    dl = DataLakeServiceClient(dfs_uri, credential=DefaultAzureCredential())
    fs = dl.get_file_system_client(container)
    f = fs.get_file_client(path)

    # 5) Remove execute bits
    _strip_exec_bits_if_hns(f)

    # 6) Quarantine rename -> .sus if needed
    if not _is_dangerous(name):
        logging.info("Allow: %s (not in blocklist)", name)
        return

    if name.lower().endswith(".sus"):
        logging.info("Already marked sus: %s", name)
        return

    new_path = f"{path}.sus"
    try:
        f.rename_file(f"{container}/{new_path}")
        qf = fs.get_file_client(new_path)
        qf.set_metadata(
            {
                "sus": "true",
                "originalName": name,
                "ts": datetime.utcnow().isoformat() + "Z",
            }
        )
        logging.info("Marked sus: %s -> %s", path, new_path)
    except Exception as ex:
        logging.error("Rename failed for %s: %s", path, ex)
