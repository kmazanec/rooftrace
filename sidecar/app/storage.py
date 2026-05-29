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

`put_bytes` is the symmetric write (e.g. the LiDAR stage caching a cropped `.npy`).
"""

from __future__ import annotations

import os
from pathlib import Path


class StorageError(RuntimeError):
    pass


class StorageTooLargeError(StorageError):
    """The object exceeds the caller-supplied size cap.

    Subclasses StorageError so existing ``except StorageError`` handlers still
    catch it, while callers that care (e.g. the project-photo endpoint mapping
    over-limit to HTTP 413) can distinguish it from a not-found.
    """


def _local_root() -> Path | None:
    root = os.environ.get("STORAGE_LOCAL_ROOT")
    return Path(root) if root else None


def _safe_local_path(root: Path, key: str) -> Path:
    """Join key under root, refusing any key that escapes the root (`../`).

    The contract's *_ref keys come from internal callers, but defense-in-depth:
    a key like `../../etc/passwd` must not read outside the storage root.
    """
    root_resolved = root.resolve()
    candidate = (root_resolved / key).resolve()
    if root_resolved != candidate and root_resolved not in candidate.parents:
        raise StorageError(f"object key escapes storage root: {key!r}")
    return candidate


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
        path = _safe_local_path(root, key)
        if not path.is_file():
            raise StorageError(f"local object not found: {path}")
        return path.read_bytes()
    resp = _client().get_object(Bucket=_bucket(), Key=key)
    return resp["Body"].read()


def get_bytes_capped(key: str, max_bytes: int) -> bytes:
    """Resolve an object key to its bytes, rejecting objects over ``max_bytes``
    BEFORE allocating the whole thing in memory.

    A bearer-authenticated caller could otherwise point a *_ref at a multi-GB
    object and force the worker to allocate it all before any size check ran
    (worker OOM). So:
      - Local: stat() the file; reject on st_size > max_bytes WITHOUT reading.
      - Live S3: head_object for ContentLength; reject before get_object. As
        defense-in-depth (ContentLength absent/lying) the streamed read is also
        capped at max_bytes+1 and rejected if it overflows.

    Raises StorageTooLargeError when over the cap, StorageError when not found
    (or no backend), matching get_bytes' not-found contract.
    """
    if max_bytes < 0:
        raise ValueError("max_bytes must be non-negative")

    root = _local_root()
    if root is not None:
        path = _safe_local_path(root, key)
        if not path.is_file():
            raise StorageError(f"local object not found: {path}")
        if path.stat().st_size > max_bytes:
            raise StorageTooLargeError(
                f"object exceeds max_bytes ({max_bytes}): {key}"
            )
        return path.read_bytes()

    client = _client()
    bucket = _bucket()
    # Reject up-front via ContentLength when the backend reports it.
    try:
        head = client.head_object(Bucket=bucket, Key=key)
    except Exception as exc:  # noqa: BLE001 — boto/client errors → StorageError
        raise StorageError(f"object not found or unreadable: {key}") from exc
    content_length = head.get("ContentLength")
    if content_length is not None and content_length > max_bytes:
        raise StorageTooLargeError(
            f"object exceeds max_bytes ({max_bytes}): {key}"
        )

    resp = client.get_object(Bucket=bucket, Key=key)
    # Defense-in-depth: cap the streamed read at max_bytes+1; if it overflows,
    # the object was larger than ContentLength claimed (or it was absent).
    raw = resp["Body"].read(max_bytes + 1)
    if len(raw) > max_bytes:
        raise StorageTooLargeError(
            f"object exceeds max_bytes ({max_bytes}): {key}"
        )
    return raw


def put_bytes(key: str, data: bytes) -> str:
    """Write bytes to a Spaces object key; returns the key. Local-root or live."""
    root = _local_root()
    if root is not None:
        path = _safe_local_path(root, key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return key
    _client().put_object(Bucket=_bucket(), Key=key, Body=data)
    return key
