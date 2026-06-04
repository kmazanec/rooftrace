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
// or null when none do (the imagery-only path has no per-vertex elevation). Used
// as the ground datum: facet/point elevations are rendered RELATIVE to it so the
// 3D roof sits on the basemap instead of floating at its absolute height.
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
