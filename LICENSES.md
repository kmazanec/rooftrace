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

### NAIP — National Agriculture Imagery Program

- **Used for:** measurement-input aerial imagery.
- **Provider:** USDA Farm Service Agency, distributed via AWS Open Data.
- **License / attribution:** *To be filled in when consumed.*

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

- **Used for:** UI basemap tiles in the web viewer (ADR-002).
- **Provider:** Mapbox.
- **License / attribution:** *To be filled in when consumed.*

### Nominatim (OpenStreetMap)

- **Used for:** address geocoding.
- **Provider:** OpenStreetMap Foundation / Nominatim service.
- **License / attribution:** *To be filled in when consumed.*
