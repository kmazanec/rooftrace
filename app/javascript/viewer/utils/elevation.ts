import type { ViewerFacet } from "../types";

// Elevation helpers for the 3D roof view (ADR-013).
//
// The LiDAR plane-fit now emits each facet vertex as [lon, lat, elev_m] (and the
// LiDAR overlay points carry [lon, lat, elev_ft]), so the viewer renders facets
// as TRUE tilted planes — real pitch — rather than flat extruded slabs. deck.gl
// positions in the default LNGLAT coordinate system carry their z in METRES.

const FEET_PER_METER = 3.280839895;

export function feetToMeters(feet: number): number {
  return feet / FEET_PER_METER;
}

// The lowest facet-vertex elevation (metres) across all facets that carry a z,
// or null when none do (the imagery-only path has no per-vertex elevation).
export function facetElevationBaseline(facets: ViewerFacet[]): number | null {
  let min: number | null = null;
  for (const f of facets) {
    for (const v of f.vertices) {
      const z = v[2];
      if (z !== undefined && (min === null || z < min)) min = z;
    }
  }
  return min;
}

// The ground datum (metres) for the 3D view: the lowest elevation across the
// facet vertices AND the LiDAR overlay points (points in feet, converted). The
// facet polygons bottom out at the eave, but the LiDAR cloud reaches the true
// ground below it — so anchoring z=0 here puts the ground on the basemap and the
// roof floats at its real height, instead of sinking the eave to the basemap and
// pushing sub-eave LiDAR returns below it. Both layers subtract this SAME datum,
// so they stay aligned (same source cloud, same vertical datum). Null when there
// is no elevation to anchor to (imagery-only, no points loaded).
export function groundBaselineMeters(
  facets: ViewerFacet[],
  lidarPointsFt: [number, number, number][] | null
): number | null {
  const candidates: number[] = [];
  const facetMin = facetElevationBaseline(facets);
  if (facetMin !== null) candidates.push(facetMin);
  if (lidarPointsFt && lidarPointsFt.length > 0) {
    let min = Infinity;
    for (const p of lidarPointsFt) if (p[2] < min) min = p[2];
    if (Number.isFinite(min)) candidates.push(feetToMeters(min));
  }
  return candidates.length > 0 ? Math.min(...candidates) : null;
}
