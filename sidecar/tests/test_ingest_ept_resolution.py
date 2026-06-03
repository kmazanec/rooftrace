"""Regression: spatial EPT resolution recovers a name-mismatched-but-covered roof.

The Chicago bug: WESM covers the address with a work unit whose NAME has no public
EPT resource (the name-guess URL 404s), but the entwine boundaries index resolves
the REAL published key the bucket uses. Hop 2 must try the spatially-resolved key
and reach LIDAR_AVAILABLE instead of returning no_ept_resource.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from app.lidar import ingest as ingest_mod
from app.lidar.ept_index import EptResourceIndex
from app.lidar.ingest import CroppedCloud, EptNotFound, ingest_lidar
from app.lidar.wesm import WorkUnit
from contracts.pipeline import LiDARStatus

_FIXTURE = Path(__file__).parent / "fixtures" / "ept_boundaries_sample.json"
_CHICAGO_POLY = {
    "type": "Polygon",
    "coordinates": [
        [
            [-87.660, 41.990],
            [-87.660, 41.99009],
            [-87.65988, 41.99009],
            [-87.65988, 41.990],
            [-87.660, 41.990],
        ]
    ],
}
_PUBLISHED_KEY = "IL_Chicago_LiDAR_2017_published_key"  # the fixture's Chicago key


class _NameMissingSpatialOkCropper:
    """404s the WESM-name URL; succeeds only for the spatially-resolved key URL."""

    def crop(self, work_unit, polygon, buffer_m=1.0, ept_url=None):
        if ept_url and _PUBLISHED_KEY in ept_url:
            # Class-6 (building) cluster sitting above a ground reference so the
            # height/class extraction in Hop 3 yields a real roof.
            pts = np.array(
                [
                    [0.0, 0.0, 110.0, 6.0],
                    [1.0, 0.0, 110.0, 6.0],
                    [0.0, 1.0, 111.0, 6.0],
                    [1.0, 1.0, 111.0, 6.0],
                    [0.5, 0.5, 110.5, 6.0],
                ],
                dtype=np.float64,
            )
            return CroppedCloud(points=pts, src_epsg=3857)
        raise EptNotFound(f"no public EPT for {work_unit.name}")


class _FakeWesm:
    def query(self, bbox):
        # WESM name deliberately != the published EPT key (the bug).
        return [
            WorkUnit(
                name="IL_Cook_2017_workunit_name",
                bbox=(-88.0, 41.6, -87.4, 42.1),
                epsg=3857,
                year=2017,
            )
        ]


def test_ingest_resolves_via_spatial_index_when_wesm_name_misses(monkeypatch):
    idx = EptResourceIndex.from_geojson(json.loads(_FIXTURE.read_text()))
    monkeypatch.setattr(ingest_mod, "load_ept_index", lambda: idx)

    out = ingest_lidar(
        _CHICAGO_POLY,
        index=_FakeWesm(),
        cropper=_NameMissingSpatialOkCropper(),
        put_bytes=lambda key, data: key,
    )
    assert out.status == LiDARStatus.AVAILABLE
    assert out.reason is None
    assert out.point_count and out.point_count > 0


def test_ingest_degrades_to_name_guess_when_index_unavailable(monkeypatch):
    def _boom():
        raise RuntimeError("boundaries index fetch failed")

    monkeypatch.setattr(ingest_mod, "load_ept_index", _boom)

    class _NameGuessOkCropper:
        # Succeeds on the legacy name-guess (ept_url is None), as if the bucket
        # DOES publish under the WESM name.
        def crop(self, work_unit, polygon, buffer_m=1.0, ept_url=None):
            if ept_url is None:
                pts = np.array(
                    [
                        [0.0, 0.0, 110.0, 6.0],
                        [1.0, 0.0, 110.0, 6.0],
                        [0.0, 1.0, 111.0, 6.0],
                        [1.0, 1.0, 110.0, 6.0],
                        [0.5, 0.5, 111.0, 6.0],
                    ],
                    dtype=np.float64,
                )
                return CroppedCloud(points=pts, src_epsg=3857)
            raise EptNotFound("resolved url not published")

    out = ingest_lidar(
        _CHICAGO_POLY,
        index=_FakeWesm(),
        cropper=_NameGuessOkCropper(),
        put_bytes=lambda key, data: key,
    )
    assert out.status == LiDARStatus.AVAILABLE
    assert "ept_index_unavailable" in out.warnings
