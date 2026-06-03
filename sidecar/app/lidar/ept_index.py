"""Resolve USGS public EPT resources by SPATIAL coverage, not by WESM name.

WESM gives coverage + collection year, but a WESM work-unit NAME is not always
the key the `usgs-lidar-public` bucket publishes the EPT under. Guessing the URL
from the name 404s and looks like a coverage gap when the data is there. Instead
we query the entwine/USGS boundaries index — a GeoJSON of every PUBLISHED
resource's footprint plus its real key — and pick resources whose footprint
covers the bbox.
"""

from __future__ import annotations

from dataclasses import dataclass

from shapely.geometry import box, shape
from shapely.geometry.base import BaseGeometry

USGS_EPT_BASE = "https://s3-us-west-2.amazonaws.com/usgs-lidar-public"

# Property keys the boundaries index may use for the resource name/key.
_KEY_PROPS = ("name", "id", "key")


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
