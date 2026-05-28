"""Shared blob access for pipeline stages.

Blobs (cropped point clouds, satellite tiles) never cross the Rails<->sidecar
contract inline — the contract carries a Spaces *object key* (`point_array_ref`,
`image_tile_ref`) in the one prefixed bucket (ADR-010). A stage that needs the
bytes resolves the key here.

Two resolution modes, selected by environment so tests need no live Spaces:

- **Live** (`STORAGE_ENDPOINT` set): read the object from DigitalOcean Spaces via
  boto3. The same single-bucket / key-prefix model the Rails side uses
  (`app/services/spaces_health.rb`).
- **Local** (`STORAGE_LOCAL_ROOT` set, or neither set in tests): read the key as
  a path under a local directory. Lets fixture point clouds / tiles live on disk
  and the geometry stages run with no network. CI uses this.

`put_bytes` is the symmetric write (e.g. F-06 caching a cropped `.npy`).
"""

from __future__ import annotations

import os
from pathlib import Path


class StorageError(RuntimeError):
    pass


def _local_root() -> Path | None:
    root = os.environ.get("STORAGE_LOCAL_ROOT")
    return Path(root) if root else None


def _client():
    # Imported lazily so the local path doesn't require boto3 to be importable.
    import boto3

    endpoint = os.environ.get("STORAGE_ENDPOINT")
    if not endpoint:
        raise StorageError(
            "no storage backend configured: set STORAGE_LOCAL_ROOT (local/fixtures) "
            "or STORAGE_ENDPOINT + STORAGE_* creds (live Spaces)"
        )
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        region_name=os.environ.get("STORAGE_REGION", "us-east-1"),
        aws_access_key_id=os.environ.get("STORAGE_ACCESS_KEY"),
        aws_secret_access_key=os.environ.get("STORAGE_SECRET_KEY"),
    )


def _bucket() -> str:
    bucket = os.environ.get("STORAGE_BUCKET")
    if not bucket:
        raise StorageError("STORAGE_BUCKET is unset")
    return bucket


def get_bytes(key: str) -> bytes:
    """Resolve a Spaces object key to its bytes (local-root or live Spaces)."""
    root = _local_root()
    if root is not None:
        path = root / key
        if not path.is_file():
            raise StorageError(f"local object not found: {path}")
        return path.read_bytes()
    resp = _client().get_object(Bucket=_bucket(), Key=key)
    return resp["Body"].read()


def put_bytes(key: str, data: bytes) -> str:
    """Write bytes to a Spaces object key; returns the key. Local-root or live."""
    root = _local_root()
    if root is not None:
        path = root / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return key
    _client().put_object(Bucket=_bucket(), Key=key, Body=data)
    return key
