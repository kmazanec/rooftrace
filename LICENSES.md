# Licenses & Attributions

RoofTrace builds on public data and third-party services. Every data source
with an attribution requirement is listed here; the rendered viewer and PDF
will surface the relevant attributions per [ROADMAP.md cross-cutting
concerns](docs/ROADMAP.md).

This file starts with placeholder sections; each provider is filled in as the
feature that consumes it lands.

## RoofTrace source code

Copyright (c) 2026 Keith Mazanec. All rights reserved (license TBD).

## Data sources

### NAIP — National Agriculture Imagery Program (dropped)

- **Status:** NOT used. NAIP was the originally-planned imagery source (ADR-002),
  but its AWS S3 buckets are Requester Pays, so it was dropped in favor of Mapbox
  for all imagery (ADR-002 amended 2026-05-29). Kept here only to record that the
  product does not consume NAIP and must not attribute imagery to it.

### USGS 3DEP — 3D Elevation Program

- **Used for:** public LiDAR point clouds (COPC-streamed).
- **Provider:** U.S. Geological Survey.
- **License / attribution:** *To be filled in when consumed.*

### Microsoft Building Footprints

- **Used for:** building polygons used as outline prior.
- **Provider:** Microsoft / Bing Maps.
- **License / attribution:** *To be filled in when consumed.*

### Regrid parcel data

- **Used for:** parcel polygons cropping the building footprint.
- **Provider:** Regrid (free tier).
- **License / attribution:** *To be filled in when consumed.*

### Mapbox

- **Used for:** ALL satellite imagery (ADR-002 amended) — the measurement-pipeline
  imagery fetch (outline refinement + feature detection), the web viewer basemap,
  and the server-side PDF map render.
- **Provider:** Mapbox (satellite imagery © Maxar).
- **License / attribution:** Mapbox Terms require visible attribution of Mapbox and
  its imagery provider on every surface that displays a tile. Attribution string:
  **© Mapbox © Maxar** (name `Mapbox`), link https://www.mapbox.com/about/maps/.
  Do NOT label this imagery public domain.

### Nominatim (OpenStreetMap)

- **Used for:** address geocoding.
- **Provider:** OpenStreetMap Foundation / Nominatim service.
- **License / attribution:** *To be filled in when consumed.*
