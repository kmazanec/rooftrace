"""Tests for the spatial EPT resource index (ept_index.py).

Verifies that resolution is driven by geometric coverage, not by work-unit name
guessing — the mismatch between WESM names and published EPT keys is the bug
this module exists to fix.
"""

import json
from pathlib import Path

from app.lidar.ept_index import EptResource, EptResourceIndex

_FIXTURE = Path(__file__).parent / "fixtures" / "ept_boundaries_sample.json"


def _index() -> EptResourceIndex:
    return EptResourceIndex.from_geojson(json.loads(_FIXTURE.read_text()))


def test_resolve_returns_resource_covering_chicago_bbox():
    bbox = (-87.661, 41.989, -87.659, 41.991)  # 5859 N Winthrop Ave, Chicago
    resources = _index().resolve(bbox)
    assert [r.key for r in resources] == ["IL_Chicago_LiDAR_2017_published_key"]


def test_resolve_returns_empty_for_uncovered_bbox():
    bbox = (-120.0, 35.0, -119.9, 35.1)
    assert _index().resolve(bbox) == []


def test_resource_url_is_the_published_key_not_a_guess():
    r = EptResource(key="IL_Chicago_LiDAR_2017_published_key", geometry=None)
    assert r.ept_url() == (
        "https://s3-us-west-2.amazonaws.com/usgs-lidar-public/"
        "IL_Chicago_LiDAR_2017_published_key/ept.json"
    )


def test_load_ept_index_uses_fixture_under_flag(monkeypatch):
    from app.lidar import ept_index as mod

    monkeypatch.setenv("EPT_INDEX_FIXTURE", "1")
    monkeypatch.setenv("EPT_INDEX_FIXTURE_PATH", str(_FIXTURE))
    mod._cached_index.cache_clear()
    try:
        idx = mod.load_ept_index()
        bbox = (-87.661, 41.989, -87.659, 41.991)
        assert [r.key for r in idx.resolve(bbox)] == ["IL_Chicago_LiDAR_2017_published_key"]
    finally:
        mod._cached_index.cache_clear()


def test_live_fetch_sends_a_real_user_agent(monkeypatch):
    """The entwine CDN 403s the default Python-urllib UA, so the live fetch must
    send our own. Mock urlopen and assert the Request carries it (no network)."""
    import contextlib
    import io

    from app.lidar import ept_index as mod

    captured = {}

    @contextlib.contextmanager
    def _fake_urlopen(req, timeout=None):
        captured["user_agent"] = req.get_header("User-agent")
        yield io.BytesIO(_FIXTURE.read_bytes())

    monkeypatch.setattr(mod.flags, "ept_index_fixture", lambda *a, **k: False)
    monkeypatch.setattr(mod, "urlopen", _fake_urlopen)
    mod._cached_index.cache_clear()
    try:
        mod.load_ept_index()
        assert captured["user_agent"] == mod._BOUNDARIES_USER_AGENT
        assert "urllib" not in captured["user_agent"].lower()
    finally:
        mod._cached_index.cache_clear()
