#!/usr/bin/env python3
"""Publish/refresh the OpenAlex parquet snapshot into the KohakuHub dataset.

Pulls straight from OpenAlex's public S3 bucket (no intermediate mirror) and writes
each parquet file as a content-addressed Git-LFS object into the rustfs bucket that
backs the hub, then commits the LFS pointers through the hub API.

The hub's own stored oid/size per path is the diff baseline, so the run is
idempotent, resumable and needs no local state file.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

HUB = os.environ["HUB_URL"].rstrip("/")
DATASET = os.environ["DATASET"]
SRC = os.environ["SRC_ENDPOINT"].rstrip("/")
PREFIX = os.environ.get("SRC_PREFIX", "data/parquet").strip("/")
DST_ENDPOINT = os.environ["DST_ENDPOINT"]
DST_BUCKET = os.environ["DST_BUCKET"]
ENTITIES = [e for e in os.environ["ENTITIES"].split(",") if e]
WORKERS = int(os.environ.get("WORKERS", "4"))
TOKEN = os.environ["HUB_TOKEN"]
ACCESS_KEY = os.environ["KOHAKU_HUB_S3_ACCESS_KEY"]
SECRET_KEY = os.environ["KOHAKU_HUB_S3_SECRET_KEY"]
COMMIT_EVERY = int(os.environ.get("COMMIT_EVERY", "200"))
BATCH = 100
START = time.time()
lock = threading.Lock()
done = {"files": 0, "bytes": 0, "failed": 0}


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def http(url, data=None, headers=None, method=None, timeout=900):
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def rclone_env():
    env = dict(os.environ)
    env.update({
        "RCLONE_CONFIG_LFS_TYPE": "s3",
        "RCLONE_CONFIG_LFS_PROVIDER": "Minio",
        "RCLONE_CONFIG_LFS_ACCESS_KEY_ID": ACCESS_KEY,
        "RCLONE_CONFIG_LFS_SECRET_ACCESS_KEY": SECRET_KEY,
        "RCLONE_CONFIG_LFS_ENDPOINT": DST_ENDPOINT,
        "RCLONE_CONFIG_LFS_REGION": "us-east-1",
        "RCLONE_CONFIG_LFS_FORCE_PATH_STYLE": "true",
    })
    return env


def desired_files():
    """Every parquet file the current OpenAlex snapshot advertises."""
    want = {}
    for entity in ENTITIES:
        url = f"{SRC}/{PREFIX}/{entity}/manifest.json"
        _, raw = http(url, timeout=120)
        manifest = json.loads(raw)
        for entry in manifest["files"]:
            rel = entry["url"].split("/data/", 1)[1]  # parquet/<entity>/...
            want[rel] = int(entry["meta"]["content_length"])
        log(f"manifest {entity}: {len(manifest['files'])} files")
    return want


def hub_state(paths):
    """oid/size per path as the hub currently records them."""
    state = {}
    for i in range(0, len(paths), BATCH):
        chunk = paths[i:i + BATCH]
        body = urllib.parse.urlencode([("paths", p) for p in chunk]).encode()
        try:
            _, raw = http(f"{HUB}/api/datasets/{DATASET}/paths-info/main", body,
                          {"Authorization": f"Bearer {TOKEN}",
                           "Content-Type": "application/x-www-form-urlencoded"},
                          method="POST", timeout=300)
        except urllib.error.HTTPError as ex:
            log(f"paths-info batch {i // BATCH} failed: {ex.code} {ex.read()[:200].decode(errors='replace')}")
            continue
        items = json.loads(raw)
        if isinstance(items, dict):
            items = items.get("paths-info") or items.get("results") or []
        for item in items:
            state[item["path"]] = int(item.get("size", -1))
    return state


def put_object(local, oid):
    key = f"{DST_BUCKET}/lfs/{oid[:2]}/{oid[2:4]}/{oid}"
    proc = subprocess.run(
        ["rclone", "copyto", local, f"lfs:{key}", "--no-traverse", "--retries", "4",
         "--low-level-retries", "10", "--s3-no-check-bucket", "--stats", "0"],
        env=rclone_env(), capture_output=True, text=True, timeout=7200)
    if proc.returncode != 0:
        raise RuntimeError(f"rclone exit {proc.returncode}: {(proc.stderr or proc.stdout)[-300:]}")


def fetch_and_upload(rel, want_size):
    last = None
    for attempt in range(3):
        tmp = tempfile.NamedTemporaryFile(prefix="openalex-", suffix=".parquet", delete=False)
        try:
            digest = hashlib.sha256()
            got = 0
            with urllib.request.urlopen(f"{SRC}/{rel}", timeout=3600) as resp:
                while True:
                    chunk = resp.read(1 << 22)
                    if not chunk:
                        break
                    got += len(chunk)
                    digest.update(chunk)
                    tmp.write(chunk)
            tmp.close()
            if got != want_size:
                raise RuntimeError(f"short read: got {got} want {want_size}")
            oid = digest.hexdigest()
            put_object(tmp.name, oid)
            return {"path": rel, "oid": oid, "size": got}
        except Exception as ex:  # noqa: BLE001 - retried below
            last = ex
            time.sleep(5 * (attempt + 1))
        finally:
            try:
                os.unlink(tmp.name)
            except OSError:
                pass
    raise RuntimeError(f"{type(last).__name__}: {last}")


def commit(records, summary):
    lines = [json.dumps({"key": "header", "value": {"summary": summary,
              "description": "Synced from the public OpenAlex snapshot by services.openalex-sync"}})]
    for rec in records:
        lines.append(json.dumps({"key": "lfsFile",
                     "value": {"path": rec["path"], "oid": rec["oid"], "size": rec["size"]}}))
    body = ("\n".join(lines) + "\n").encode()
    for attempt in range(5):
        try:
            status, raw = http(f"{HUB}/api/datasets/{DATASET}/commit/main", body,
                               {"Authorization": f"Bearer {TOKEN}",
                                "Content-Type": "application/x-ndjson"},
                               method="POST", timeout=900)
            log(f"committed {len(records)} files: {status} {raw[:120].decode(errors='replace')}")
            return True
        except urllib.error.HTTPError as ex:
            log(f"commit failed ({ex.code}): {ex.read()[:200].decode(errors='replace')}")
            time.sleep(10 * (attempt + 1))
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true", help="report the diff and exit")
    ap.add_argument("--limit", type=int, default=0, help="upload at most N files")
    args = ap.parse_args()

    want = desired_files()
    log(f"snapshot advertises {len(want)} files, {sum(want.values()) / 2**30:.1f} GiB")
    have = hub_state(sorted(want))
    todo = [p for p in sorted(want) if have.get(p) != want[p]]
    removed = sorted(set(have) - set(want))
    log(f"in the hub: {len(have)}; to add or refresh: {len(todo)}; vanished upstream: {len(removed)}")
    if removed:
        log("upstream no longer lists (left in place): " + ", ".join(removed[:5]))
    if args.dry_run or not todo:
        log("nothing to do" if not todo else "dry run, stopping")
        return 0
    if args.limit:
        todo = todo[:args.limit]

    pending = []
    failures = []

    def record(rec, ok):
        if ok:
            with lock:
                done["files"] += 1
                done["bytes"] += rec["size"]
                n = done["files"]
                if n % 25 == 0 or n == len(todo):
                    rate = done["bytes"] / 2**20 / max(time.time() - START, 1)
                    log(f"{n}/{len(todo)} files  {done['bytes'] / 2**30:.1f} GiB  {rate:.1f} MiB/s")
            pending.append(rec)
            if len(pending) >= COMMIT_EVERY:
                batch, pending[:] = pending[:], []
                commit(batch, f"OpenAlex: +{len(batch)} files")
        else:
            with lock:
                done["failed"] += 1
            failures.append(rec["path"])

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = {pool.submit(fetch_and_upload, p, want[p]): p for p in todo}
        for future, path in futures.items():
            try:
                record(future.result(), True)
            except Exception as ex:  # noqa: BLE001
                log(f"FAIL {path}: {ex}")
                record({"path": path}, False)

    if pending:
        commit(pending, f"OpenAlex: final +{len(pending)} files")
    log(f"done: {done['files']} files, {done['bytes'] / 2**30:.1f} GiB, {done['failed']} failures, "
        f"{(time.time() - START) / 60:.1f} min")
    if failures:
        log("failed paths: " + ", ".join(failures[:10]))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
