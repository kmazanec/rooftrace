import type { StyleSpecification } from "maplibre-gl";

// Mapbox Satellite raster basemap (ADR-002) consumed through MapLibre via the
// raster-tiles API + a public token. When the token is blank the viewer falls
// back to a neutral light-gray canvas (instrument aesthetic, never a blank
// black map) and the caller surfaces a small "basemap unavailable" notice.
export function basemapStyle(mapboxToken: string | null | undefined): StyleSpecification {
  if (mapboxToken && mapboxToken.trim().length > 0) {
    return {
      version: 8,
      sources: {
        satellite: {
          type: "raster",
          tiles: [
            `https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}@2x.png?access_token=${encodeURIComponent(
              mapboxToken
            )}`,
          ],
          tileSize: 256,
          attribution: "© Mapbox © Maxar",
        },
      },
      layers: [{ id: "satellite", type: "raster", source: "satellite" }],
    };
  }

  // Neutral fallback — no external tiles, a measured light-gray field.
  return {
    version: 8,
    sources: {},
    layers: [
      {
        id: "background",
        type: "background",
        paint: { "background-color": "#E5E7EB" },
      },
    ],
  };
}

export function hasBasemap(mapboxToken: string | null | undefined): boolean {
  return !!(mapboxToken && mapboxToken.trim().length > 0);
}
