"""In-process TTL cache for F-05 geo lookups.

Per ADR-008 the sidecar is stateless — it holds no DB connection.
This module provides an injectable in-memory cache that:

  • survives the request lifetime (module-level LRU dict with timestamps)
  • exposes a `CacheBackend` protocol so the Rails-side PostGIS cache
    (F-10) can swap it in as a dependency without touching this module

TTLs per the spec:
  • geocode results       7 days
  • parcel boundaries     7 days
  • building footprints  30 days

The Rails PostGIS cache (a `geo_cache` table) is deferred to the
orchestrator / F-10 integration. When that lands, inject a
`PostgresCacheBackend` that fulfils the same `CacheBackend` protocol.
"""

from __future__ import annotations

import time
from threading import Lock
from typing import Any, Generic, Protocol, TypeVar

V = TypeVar("V")

# TTLs in seconds
GEOCODE_TTL = 7 * 24 * 3600   # 7 days
PARCEL_TTL = 7 * 24 * 3600    # 7 days
FOOTPRINT_TTL = 30 * 24 * 3600  # 30 days


class CacheBackend(Protocol[V]):
    """Minimal key/value cache protocol.

    The default implementation is `InMemoryTTLCache`.  A future
    `PostgresCacheBackend` (F-10) fulfilling this protocol can be injected
    by changing the `_cache_*` module-level singletons or via FastAPI
    dependency override — no caller changes required.
    """

    def get(self, key: str) -> V | None:
        ...

    def set(self, key: str, value: V, ttl: float) -> None:
        ...


class InMemoryTTLCache(Generic[V]):
    """Thread-safe in-memory dict with per-entry TTL.

    Entries expire lazily on `get`; no background eviction thread so the
    memory footprint is bounded by the number of unique addresses seen
    since the last process restart.
    """

    def __init__(self) -> None:
        self._store: dict[str, tuple[V, float]] = {}  # key -> (value, expiry)
        self._lock = Lock()

    def get(self, key: str) -> V | None:
        with self._lock:
            entry = self._store.get(key)
            if entry is None:
                return None
            value, expiry = entry
            if time.monotonic() > expiry:
                del self._store[key]
                return None
            return value

    def set(self, key: str, value: V, ttl: float) -> None:
        with self._lock:
            self._store[key] = (value, time.monotonic() + ttl)

    def clear(self) -> None:
        """Flush all entries (useful in tests)."""
        with self._lock:
            self._store.clear()


# Module-level singletons — swapped by tests via monkeypatch or replaced
# wholesale when the F-10 Postgres backend lands.
geocode_cache: InMemoryTTLCache[Any] = InMemoryTTLCache()
parcel_cache: InMemoryTTLCache[Any] = InMemoryTTLCache()
footprint_cache: InMemoryTTLCache[Any] = InMemoryTTLCache()
