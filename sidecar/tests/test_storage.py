"""Tests for the shared blob-storage helper (app/storage.py).

Focus: the local-root mode used in tests/demo, and the path-traversal guard
(a *_ref key from the contract must not escape STORAGE_LOCAL_ROOT).
"""

from __future__ import annotations

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
