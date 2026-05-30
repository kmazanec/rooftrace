# RoofTrace: Technical Writeup

## The problem

Measuring a roof from a street address (its total area, the pitch and area of each facet, and the location of rooftop features like vents, chimneys, dormers, skylights, and satellite dishes) is a geometry problem disguised as a data problem. The geometry is trivial given a dense 3D measurement of the structure. The difficulty is that an address alone yields only 2D overhead imagery and sparse, unevenly distributed public elevation data, and the two disagree about where the roof is. Trees overhang eaves, shadows hide edges, neighboring structures blur boundaries. Producing a number a user can act on means knowing when you are measuring versus estimating, and saying which.

## The approach

The core insight: public LiDAR is a measurement, not an estimate. Where it exists, fitting planes to a point cloud reads off pitch and area directly to within a few percent. So LiDAR is the primary geometry source, and everything else either localizes the roof or backfills where LiDAR is absent. The system never silently guesses. Every result carries a `source` (`lidar`, `imagery_only`, or `lidar+device+imagery`) and a `confidence`, surfaced through to the UI and the export.

The pipeline, from an address:

1. **Localize.** Geocode the address, then resolve a building footprint (Microsoft Building Footprints) intersected with a parcel boundary (Regrid). This yields a coarse roof polygon and the crop bounds for everything downstream. Polygons are stored in WGS84; area math runs in the local UTM zone.
2. **Measure.** Check public LiDAR coverage (USGS 3DEP, via a spatial index over work-unit extents), stream only the relevant COPC chunk, crop to the footprint, and keep the building-classified points. RANSAC multi-plane fitting segments the cloud into facets; each plane's normal gives pitch, its projected extent gives area.
3. **Refine the outline.** A foundation segmentation model (SAM2), prompted with the footprint as a prior, sharpens the roof boundary from overhead imagery; Douglas-Peucker simplifies it. This corrects the footprint's coarseness and cross-checks the LiDAR extent.
4. **Identify features.** A vision-language model runs on the cropped nadir tile to detect and localize rooftop features, with a verification pass that downgrades low-confidence detections rather than dropping them.
5. **Fall back honestly.** Where LiDAR is missing or too sparse, the system degrades to a planimetric estimate from imagery (`area / cos(pitch)`, pitch inferred) and labels it `imagery_only` with widened uncertainty. It does not fake a measurement it cannot make.

**Optional ground-truth augmentation.** A guided smartphone capture (an 8-prompt walk-around) uploads a full sensor bundle: an ARKit world-mesh, per-frame depth, GPS, and IMU. The backend ICP-aligns that device mesh to the public-LiDAR cloud and re-fits planes on the merged geometry, which helps most exactly where overhead data is weakest, at tree-occluded eaves and in LiDAR gaps. The captured photos then become an output surface: each facet is projected back onto the photo via pinhole-camera math with z-buffer occlusion, producing on-site overlay images.

One canonical measurement drives three deliverables: an interactive web report (3D facet extrusion with per-facet pitch and area, plus feature pins), a print-quality PDF with a rendered roof diagram, and a versioned JSON export for downstream integration.

## How it's built

**Two services, split on the geometry boundary.** A Rails monolith owns HTTP, auth, persistence, and job orchestration; a stateless Python sidecar (FastAPI) owns the geospatial numerics: PDAL/GDAL for LiDAR, Shapely/pyproj for geometry and coordinate transforms, the SAM2 client, RANSAC, and ICP. They talk HTTP/JSON over an internal network, behind a shared secret, against one versioned schema that is the contract for every call. The split follows the API of the geometric pipeline, not the org chart: Ruby gets the web stack and LLM ergonomics, Python gets the mature geospatial toolchain, neither reimplements the other.

**Long work runs as jobs.** Address submission returns immediately; a queued `GeometryJob` runs the pipeline and streams status to the browser. An iOS capture triggers a follow-on `FusionJob` (the ICP merge), then a `ProjectionJob` (the photo overlays). The synchronous request stays cheap; the heavy work stays bounded and observable.

**Latency is I/O-bound.** The wall-clock budget is dominated by fetching the imagery tile and streaming the COPC chunk from open-data buckets, not by compute. SAM2 runs warm on serverless GPU (~1s); plane fitting and transforms are sub-second. The happy path typically lands under ~90 seconds with warm caches.

**Loose coupling via the object store.** Point clouds and image tiles never cross the service boundary inline. They cross as object-store keys, fetched on demand through short-lived signed URLs scoped to a single key prefix. The contract carries only opaque references, keeping payloads small and the services decoupled.

**Fail fast, fail loud.** Every stage's real data path is the default in all environments; fixtures exist only as explicit, test-only opt-downs. Missing configuration (an env var, a required library, a schema file) raises at boot, not at request time. A bad deploy dies immediately with a clear message instead of serving a green health check while every request silently 500s.

## What it deliberately does not do

The smartphone capture is a smart camera, not a smart device: it records the richest possible sensor bundle and uploads it, running zero on-device reconstruction. All fusion happens server-side. So there is no live AR in the capture flow; AR appears instead as a server-rendered overlay on the returned photos. This trades the scope and fiddliness of on-device AR for a reconstruction the backend fully controls, and keeps the device doing the one thing it is good at: capturing clean, well-localized sensor data.

## Honest limits

A few-percent area error is achievable wherever dense public LiDAR exists. Nationwide coverage is genuinely uneven, and in the gaps the system degrades to an imagery-only estimate with honestly widened bounds rather than a confident wrong answer. Per-feature detection is a foundation-model zero-shot task with no large public training set for these classes, so it is a strong assistant, not a certified inventory. The design choice throughout is to make the system's confidence legible, not to overstate it.
