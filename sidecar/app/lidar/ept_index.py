"""Resolve USGS public EPT resources by SPATIAL coverage, not by WESM name.

WESM gives coverage + collection year, but a WESM work-unit NAME is not always
the key the `usgs-lidar-public` bucket publishes the EPT under. Guessing the URL
from the name 404s and looks like a coverage gap when the data is there. Instead
we query the entwine/USGS boundaries index — a GeoJSON of every PUBLISHED
resource's footprint plus its real key — and pick resources whose footprint
covers the bbox.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from urllib.request import urlopen

from shapely.geometry import box, shape
from shapely.geometry.base import BaseGeometry

from app import flags

USGS_EPT_BASE = "https://s3-us-west-2.amazonaws.com/usgs-lidar-public"

# The boundaries index keys the resource under `name` (the S3 path segment).
_KEY_PROPS = ("name", "key")


@dataclass(frozen=True)
class EptResource:
    key: str
    geometry: BaseGeometry | None  # None only for url-only stubs (tests)

    def ept_url(self) -> str:
        return f"{USGS_EPT_BASE}/{self.key}/ept.json"


class EptResourceIndex:
    """A queryable set of published EPT resources with footprints."""

    def __init__(self, resources: list[EptResource]) -> None:
        self._resources = resources

    @classmethod
    def from_geojson(cls, geojson: dict) -> "EptResourceIndex":
        resources: list[EptResource] = []
        for feat in geojson.get("features", []):
            props = feat.get("properties") or {}
            key = next((props[k] for k in _KEY_PROPS if props.get(k)), None)
            geom = feat.get("geometry")
            if not key or geom is None:
                continue
            resources.append(EptResource(key=str(key), geometry=shape(geom)))
        return cls(resources)

    def resolve(self, bbox: tuple[float, float, float, float]) -> list[EptResource]:
        """Published resources whose footprint intersects the bbox, best-fit first.

        Ordering: largest intersection area first (a tight local collect beats a
        sprawling statewide one when both cover the building).
        """
        query = box(*bbox)
        hits: list[tuple[float, EptResource]] = []
        for r in self._resources:
            if r.geometry is not None and r.geometry.intersects(query):
                hits.append((r.geometry.intersection(query).area, r))
        hits.sort(key=lambda t: t[0], reverse=True)
        return [r for _area, r in hits]


# Entwine/USGS published EPT footprints + keys (the usgs.entwine.io map's source).
USGS_EPT_BOUNDARIES_URL = "https://usgs.entwine.io/boundaries/resources.geojson"

_FIXTURE_PATH_VAR = "EPT_INDEX_FIXTURE_PATH"


@lru_cache(maxsize=1)
def _cached_index() -> EptResourceIndex:
    if flags.ept_index_fixture():
        path = os.environ.get(_FIXTURE_PATH_VAR)
        if not path:
            raise RuntimeError("EPT_INDEX_FIXTURE=1 but EPT_INDEX_FIXTURE_PATH unset")
        return EptResourceIndex.from_geojson(json.loads(Path(path).read_text()))
    with urlopen(USGS_EPT_BOUNDARIES_URL, timeout=20) as resp:  # noqa: S310 (fixed https URL)
        return EptResourceIndex.from_geojson(json.loads(resp.read()))


def load_ept_index() -> EptResourceIndex:
    """Process-cached boundaries index (fixture under the test opt-down)."""
    return _cached_index()
