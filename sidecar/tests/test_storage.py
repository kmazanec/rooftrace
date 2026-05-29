"""Tests for the shared blob-storage helper (app/storage.py).

Focus: the local-root mode used in tests/demo, and the path-traversal guard
(a *_ref key from the contract must not escape STORAGE_LOCAL_ROOT).
"""

from __future__ import annotations

from pathlib import Path

import pytest

from app import storage


def test_put_then_get_roundtrips(tmp_path, monkeypatch):
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    key = storage.put_bytes("cache/lidar/abc.npy", b"hello")
    assert key == "cache/lidar/abc.npy"
    assert storage.get_bytes("cache/lidar/abc.npy") == b"hello"


def test_get_missing_raises(tmp_path, monkeypatch):
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    with pytest.raises(storage.StorageError, match="not found"):
        storage.get_bytes("cache/nope.npy")


@pytest.mark.parametrize("evil", ["../../etc/passwd", "../outside.npy", "a/../../b"])
def test_path_traversal_is_refused(tmp_path, monkeypatch, evil):
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    with pytest.raises(storage.StorageError, match="escapes storage root"):
        storage.get_bytes(evil)
    with pytest.raises(storage.StorageError, match="escapes storage root"):
        storage.put_bytes(evil, b"x")


def test_no_backend_configured_raises(tmp_path, monkeypatch):
    monkeypatch.delenv("STORAGE_LOCAL_ROOT", raising=False)
    monkeypatch.delenv("STORAGE_ENDPOINT", raising=False)
    with pytest.raises(storage.StorageError, match="no storage backend"):
        storage.get_bytes("cache/x.npy")


# ---------------------------------------------------------------------------
# get_bytes_capped — size-bounded read (DoS guard, ADR-008)
# ---------------------------------------------------------------------------


def test_get_bytes_capped_returns_under_limit(tmp_path, monkeypatch):
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    storage.put_bytes("uploads/small.bin", b"hello")
    assert storage.get_bytes_capped("uploads/small.bin", max_bytes=1024) == b"hello"


def test_get_bytes_capped_local_rejects_before_read(tmp_path, monkeypatch):
    """Local backend rejects via stat() WITHOUT reading the file into memory."""
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    storage.put_bytes("uploads/big.bin", b"x" * 5000)

    # Spy on read_bytes: an over-limit object must be rejected before any read.
    called = {"read": False}
    real_read_bytes = Path.read_bytes

    def spy_read_bytes(self):
        called["read"] = True
        return real_read_bytes(self)

    monkeypatch.setattr(Path, "read_bytes", spy_read_bytes)

    with pytest.raises(storage.StorageTooLargeError):
        storage.get_bytes_capped("uploads/big.bin", max_bytes=1000)
    assert called["read"] is False, "over-limit object must be rejected before reading"


def test_get_bytes_capped_missing_raises_storage_error(tmp_path, monkeypatch):
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    with pytest.raises(storage.StorageError):
        storage.get_bytes_capped("uploads/nope.bin", max_bytes=1024)


def test_storage_too_large_is_a_storage_error():
    """StorageTooLargeError subclasses StorageError so existing handlers still
    catch it, but callers can distinguish it for a 413."""
    assert issubclass(storage.StorageTooLargeError, storage.StorageError)
