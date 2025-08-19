import os
import json
import logging
import re
from datetime import datetime
from typing import List, Any

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.storage.filedatalake import DataLakeServiceClient
from azure.storage.blob import BlobServiceClient

RENAME_MODE = os.getenv("RENAME_MODE", "blocklist")  # "blocklist" or "three"
BLOCKLIST = {e.strip().lower() for e in os.getenv(
    "BLOCKLIST",
    ".exe,.com,.bat,.cmd,.scr,.msi,.msp,.ps1,.ps2,.vbs,.vbe,.js,.jse,.wsf,.wsh,.hta,.jar,.dll,.reg,.cpl,.lnk"
).split(",")}
IS_HNS = os.getenv("IS_HNS", "true").lower() == "true"
ACCOUNT = os.environ.get("STORAGE_ACCOUNT")
if not ACCOUNT:
    logging.warning("STORAGE_ACCOUNT not set; HNS operations will fail.")

def _is_dangerous(name: str) -> bool:
    # Already quarantined?
    if name.lower().endswith(".danger"):
        return False
    m = re.search(r"\.([A-Za-z0-9]{1,10})$", name)
    if not m:
        return False
    ext = m.group(0).lower()  # includes dot
    if RENAME_MODE == "three":
        # ".???" (length incl. dot is 4) — beware this hits .jpg/.pdf/etc.
        return len(ext) == 4
    return ext in BLOCKLIST

def _strip_exec_bits_if_hns(file_client):
    acl = file_client.get_access_control()
    perms = list(acl.get("permissions", ""))
    if len(perms) != 9:
        return  # unexpected format, bail
    changed = False
    for i in (2, 5, 8):  # owner/group/other execute slots
        if perms[i] == "x":
            perms[i] = "-"
            changed = True
    if changed:
        file_client.set_access_control(permissions="".join(perms))

def _parse_container_blob_from_subject(subject: str):
    # Example subject: /blobServices/default/containers/<fs>/blobs/path/to/file.bin
    try:
        parts = subject.split("/")
        cidx = parts.index("containers")
        bidx = parts.index("blobs")
        container = parts[cidx + 1]
        path = "/".join(parts[bidx + 1:])
        return container, path
    except Exception:
        return None, None

def _handle_single_event(ev: Any):
    # Supports direct Event Grid schema or a queue-wrapped body
    data = ev.get("data", {})
    subject = ev.get("subject", "")
    url = data.get("url", "")

    container, path = _parse_container_blob_from_subject(subject)
    if not container or not path:
        # try URL parse: https://acct.blob.core.windows.net/container/path/file
        if url:
            try:
                parts = url.split("/")
                container = parts[3]
                path = "/".join(parts[4:])
            except Exception:
                logging.warning("Cannot parse container/path from event: %s", ev)
                return

    name = path.split("/")[-1]

    if IS_HNS:
        # Data Lake (HNS) operations
        dfs_uri = f"https://{ACCOUNT}.dfs.core.windows.net"
        dl = DataLakeServiceClient(dfs_uri, credential=DefaultAzureCredential())
        fs = dl.get_file_system_client(container)
        f = fs.get_file_client(path)

        # 1) remove execute bits (accidental Linux exec)
        try:
            _strip_exec_bits_if_hns(f)
        except Exception as ex:
            logging.warning("Strip +x failed for %s/%s: %s", container, path, ex)

        # 2) quarantine by renaming if risky extension
        if _is_dangerous(name):
            # compute new path
            if "/" in path:
                dir_part = "/".join(path.split("/")[:-1])
                new_path = f"{dir_part}/{name}.danger"
            else:
                new_path = f"{name}.danger"
            try:
                f.rename_file(f"{container}/{new_path}")
                qf = fs.get_file_client(new_path)
                qf.set_metadata({"quarantined":"true","originalName":name,"ts":datetime.utcnow().isoformat()+"Z"})
                logging.info("Quarantined %s/%s -> %s", container, path, new_path)
            except Exception as ex:
                logging.error("Rename failed for %s/%s: %s", container, path, ex)
    else:
        # Flat Blob path (no ACLs): copy -> delete for rename
        blob_uri = f"https://{ACCOUNT}.blob.core.windows.net"
        bs = BlobServiceClient(blob_uri, credential=DefaultAzureCredential())
        bc = bs.get_blob_client(container=container, blob=path)
        if _is_dangerous(name):
            new_blob = path + ".danger"
            dest = bs.get_blob_client(container=container, blob=new_blob)
            try:
                dest.start_copy_from_url(bc.url)
                # NOTE: In prod, poll copy status before delete
                bc.delete_blob()
                dest.set_blob_metadata({"quarantined":"true","originalName":name,"ts":datetime.utcnow().isoformat()+"Z"})
                logging.info("Quarantined (copy->delete) %s/%s -> %s", container, path, new_blob)
            except Exception as ex:
                logging.error("Copy/Delete rename failed for %s/%s: %s", container, path, ex)

def main(msgs: List[func.QueueMessage]):
    for m in msgs:
        try:
            body = m.get_body().decode("utf-8")
        except Exception:
            logging.warning("Non-utf8 message; skipping")
            continue
        try:
            parsed = json.loads(body)
            events = parsed if isinstance(parsed, list) else [parsed]
        except Exception:
            # Allow raw single event in queue body
            events = [{"data": {"url": body}, "subject": ""}]
        for ev in events:
            _handle_single_event(ev)
