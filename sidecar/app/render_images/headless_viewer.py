"""Self-contained HTML for a top-down MapLibre satellite view (ADR-014).

The page is fed to Playwright via ``page.set_content`` (NO listening port, so no
port contention) and fits the requested WGS84 bbox at the requested pixel size.
Mapbox satellite raster tiles are loaded through MapLibre GL using the public
token; on tile failure the map still renders a plain background so the
screenshot always returns something.
"""

from __future__ import annotations

import json


def viewer_html(bbox: list[float], width_px: int, height_px: int, mapbox_token: str) -> str:
    """Return a complete HTML document that renders the bbox top-down.

    Only numeric/validated values are interpolated (the bbox floats, integer
    dimensions, and the token as a JSON string), so there is no markup-injection
    surface.
    """
    min_lon, min_lat, max_lon, max_lat = (float(c) for c in bbox)
    bounds = json.dumps([[min_lon, min_lat], [max_lon, max_lat]])
    token_js = json.dumps(mapbox_token)
    w = int(width_px)
    h = int(height_px)

    return f"""<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<link href="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.css" rel="stylesheet" />
<script src="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.js"></script>
<style>
  html, body {{ margin: 0; padding: 0; }}
  #map {{ width: {w}px; height: {h}px; background: #e8e8e8; }}
</style>
</head>
<body>
<div id="map"></div>
<script>
  // Always define the signal flags FIRST, before touching maplibregl, so the
  // renderer can distinguish three outcomes deterministically regardless of
  // where a failure happens:
  //   __mapReady  -> the screenshot may be taken
  //   __mapFailed -> the MapLibre library never loaded (e.g. the CDN <script>
  //                  404'd / was unreachable). Without this guard the inline
  //                  `new maplibregl.Map(...)` would throw a ReferenceError and
  //                  the screenshot path could capture a featureless gray div
  //                  while the sidecar still returned HTTP 200 — a silent
  //                  degradation with no fallback signal to Rails.
  window.__mapReady = false;
  window.__mapFailed = false;
  if (typeof maplibregl === "undefined") {{
    // The MapLibre bundle did not load. Flag the failure so the renderer raises
    // and degrades to the placeholder PNG instead of screenshotting a gray box.
    window.__mapFailed = true;
    window.__mapReady = true;
  }} else {{
    const TOKEN = {token_js};
    const map = new maplibregl.Map({{
      container: "map",
      style: {{
        version: 8,
        sources: {{
          sat: {{
            type: "raster",
            tiles: ["https://api.mapbox.com/v4/mapbox.satellite/{{z}}/{{x}}/{{y}}@2x.png?access_token=" + TOKEN],
            tileSize: 256,
            attribution: "Mapbox, NAIP"
          }}
        }},
        layers: [{{ id: "sat", type: "raster", source: "sat" }}]
      }},
      interactive: false,
      attributionControl: false,
      bounds: {bounds},
      fitBoundsOptions: {{ padding: 0, animate: false }}
    }});
    map.on("idle", () => {{ window.__mapReady = true; }});
    // Belt-and-suspenders: flip ready after a hard timeout even if tiles stall,
    // so the screenshot path is never blocked indefinitely.
    setTimeout(() => {{ window.__mapReady = true; }}, 2500);
  }}
</script>
</body>
</html>"""
