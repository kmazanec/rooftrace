"""WESM coverage lookup for the LiDAR ingest stage.

WESM = USGS "Work Unit Extent Spatial Metadata": a GeoPackage that says which
3DEP work unit (and therefore which COPC product) covers a given footprint. The
ingest stage queries it FIRST, before any data fetch, so an address in a 3DEP
gap fast-fails as LIDAR_MISSING within the latency budget instead of attempting
a doomed multi-hundred-MB stream.

Two index backends behind one interface so tests need no 200 MB GeoPackage:

- `GeoPackageWesmIndex` — the real thing, reads the WESM `.gpkg` via GDAL/OGR.
  GDAL is conda-only (installed in the image), so its import is guarded and this
  class is only constructed on the live path (`LIDAR_LIVE=1`).
- `FixtureWesmIndex` — a list of work-unit extents from a JSON file (or literal),
  for tests and the demo fixtures. Same `.query(bbox)` contract.

A work unit's geographic extent is stored/queried in WGS84 (EPSG:4326) lon/lat;
its `epsg` field is the native CRS the COPC product is delivered in.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from app import flags


@dataclass(frozen=True)
class WorkUnit:
    """A 3DEP work unit covering some extent. `bbox` is WGS84 [w, s, e, n]."""

    name: str
    bbox: tuple[float, float, float, float]
    epsg: int
    year: int | None = None
    quality_level: str | None = None
    copc_url: str | None = None


def _bbox_intersects(a: tuple[float, float, float, float], b: tuple[float, float, float, float]) -> bool:
    aw, as_, ae, an = a
    bw, bs, be, bn = b
    return not (ae < bw or be < aw or an < bs or bn < as_)


class WesmIndex(Protocol):
    """Coverage-lookup interface: which work units cover a WGS84 bbox."""

    def query(self, bbox: tuple[float, float, float, float]) -> list[WorkUnit]: ...


class FixtureWesmIndex(WesmIndex):
    """In-memory index from a list of WorkUnits or a JSON file. Test/demo backend."""

    def __init__(self, work_units: list[WorkUnit]):
        self._work_units = work_units

    @classmethod
    def from_json(cls, path: str | Path) -> "FixtureWesmIndex":
        raw = json.loads(Path(path).read_text())
        return cls([
            WorkUnit(
                name=w["name"],
                bbox=(w["bbox"][0], w["bbox"][1], w["bbox"][2], w["bbox"][3]),
                epsg=int(w["epsg"]),
                year=w.get("year"),
                quality_level=w.get("quality_level"),
                copc_url=w.get("copc_url"),
            )
            for w in raw
        ])

    def query(self, bbox: tuple[float, float, float, float]) -> list[WorkUnit]:
        # Prefer the most recent covering work unit first.
        hits = [w for w in self._work_units if _bbox_intersects(w.bbox, bbox)]
        return sorted(hits, key=lambda w: (w.year or 0), reverse=True)


class GeoPackageWesmIndex(WesmIndex):
    """Real WESM GeoPackage backend (GDAL/OGR). Live path only (LIDAR_LIVE=1)."""

    def __init__(self, gpkg_path: str | Path):
        self._gpkg_path = str(gpkg_path)

    def query(self, bbox: tuple[float, float, float, float]) -> list[WorkUnit]:
        # GDAL is conda-only; imported lazily so the module loads without it.
        from osgeo import ogr  # type: ignore

        # OGR DataSource has no .close(); use try/finally + ds=None so the
        # CPython refcount drops to zero and __del__ releases the file handle.
        ds = ogr.Open(self._gpkg_path)
        try:
            if ds is None:
                raise RuntimeError(f"cannot open WESM GeoPackage at {self._gpkg_path}")
            layer = ds.GetLayer(0)
            w, s, e, n = bbox
            layer.SetSpatialFilterRect(w, s, e, n)
            out: list[WorkUnit] = []
            for feat in layer:
                geom = feat.GetGeometryRef()
                env = geom.GetEnvelope()  # (minX, maxX, minY, maxY)
                out.append(
                    WorkUnit(
                        name=_field(feat, "workunit") or _field(feat, "project") or "unknown",
                        bbox=(env[0], env[2], env[1], env[3]),
                        epsg=int(_field(feat, "horiz_crs") or _field(feat, "epsg") or 4326),
                        year=_safe_int(_field(feat, "collect_end") or _field(feat, "year")),
                        quality_level=_field(feat, "ql"),
                        copc_url=_field(feat, "copc_url") or _field(feat, "lpc_link"),
                    )
                )
        finally:
            ds = None  # release the OGR handle (triggers __del__ / Destroy)
        return sorted(out, key=lambda u: (u.year or 0), reverse=True)


def _field(feat, name: str):
    """Read an OGR field by name, returning None if the column is absent.

    OGR's `Feature.GetField(name)` RAISES KeyError for a column that isn't in the
    layer schema (it does NOT return None), so the `GetField(a) or GetField(b)`
    fallback pattern blows up the moment `a` doesn't exist. The real WESM.gpkg
    schema has `lpc_link`/`horiz_crs`/`collect_end` (not `copc_url`/`epsg`/`year`),
    so probe the field index first. An empty string is normalised to None so it
    participates in the `or`-fallback like a missing value.
    """
    if feat.GetFieldIndex(name) < 0:
        return None
    value = feat.GetField(name)
    if isinstance(value, str) and value == "":
        return None
    return value


def _safe_int(value: object) -> int | None:
    try:
        return int(str(value)[:4])
    except (TypeError, ValueError):
        return None


def default_index() -> WesmIndex:
    """The index to use given the environment.

    The REAL GeoPackage (`WESM_GPKG_PATH`) is the default — dev + prod always use
    real 3DEP data. A fixture index from `WESM_FIXTURE_PATH` is used only when
    `LIDAR_FIXTURE=1` (the test suites). Raising here keeps the failure at the
    boundary instead of deep in a PDAL pipeline.
    """
    if flags.lidar_fixture():
        fixture = os.environ.get("WESM_FIXTURE_PATH")
        if not fixture:
            raise RuntimeError(
                "LIDAR_FIXTURE=1 but WESM_FIXTURE_PATH is unset (tests/demo)"
            )
        return FixtureWesmIndex.from_json(fixture)
    gpkg = os.environ.get("WESM_GPKG_PATH")
    if not gpkg:
        raise RuntimeError(
            "no WESM GeoPackage configured: set WESM_GPKG_PATH to the real 3DEP "
            "WESM.gpkg (bin/setup downloads it), or LIDAR_FIXTURE=1 + "
            "WESM_FIXTURE_PATH for the test suites"
        )
    return GeoPackageWesmIndex(gpkg)
