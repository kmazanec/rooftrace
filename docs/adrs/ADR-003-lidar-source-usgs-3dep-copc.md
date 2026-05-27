# ADR-003: Use USGS 3DEP LiDAR streamed via COPC + PDAL as the 3D measurement source

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

ADR-001 picks satellite + LiDAR fusion as the geometry architecture. The
LiDAR half of that fusion is the entire reason the system can claim ±3%
area accuracy: each LiDAR return is a real `(x, y, z)` point on the roof
surface, and pitch / area / facet topology fall out of geometric fitting
rather than ML inference.

The question this ADR answers is: **what LiDAR source, and what access
pattern?**

Realistic public LiDAR options for US-wide coverage in 2026:

| Source | Coverage | Resolution (typical) | Access | Notes |
|---|---|---|---|---|
| **USGS 3DEP** | Nationwide, uneven — strong east of the Rockies and West Coast; gaps in rural West / parts of Midwest | QL2 ≈ 2 pts/m²; QL1 ≈ 0.5 m | TNM API + S3 (`s3://usgs-lidar-public`) as Entwine Point Tiles / COPC | The canonical answer |
| **State programs** (e.g., NC OneMap, NY GIS, MA MassGIS) | Per state, often higher density than 3DEP in covered areas | 0.3–1 m | Variable: bulk download, sometimes WMS/WFS | Higher quality where they exist; per-state integration cost |
| **OpenTopography portal** | Mostly redistributes 3DEP + research datasets | Varies | REST API | Useful aggregator UI for picking demo addresses |
| **Commercial (e.g., Nearmap LiDAR, Vexcel)** | Wider, current | High | Paid, expensive | Out of budget |

Two distinct access patterns for 3DEP:

- **Bulk LAZ download** (legacy): fetch the entire LAZ tile that covers
  your area-of-interest, decompress, then crop locally. Tile sizes range
  ~50 MB – several GB. Slow cold path; bandwidth and time cost dominate.
- **COPC** (Cloud-Optimized Point Cloud) streamed via PDAL: random-access
  reads of just the spatial chunks you need from `s3://usgs-lidar-public`,
  similar in spirit to cloud-optimized GeoTIFF. Order of magnitude less
  data transferred per job.

And one indexing decision: how do we know which tile covers an address?

- **WESM** (Work Unit Extent Spatial Metadata) GeoPackage from USGS lists
  every 3DEP work unit's footprint, project name, QL, acquisition date,
  and the path to its COPC. Spatial index → tile lookup is one query.

## Options considered

**A. USGS 3DEP via COPC + PDAL, indexed by WESM.** Stream the spatial
crop directly from S3; never download a whole tile.
*Tradeoff:* requires understanding the COPC spec and PDAL pipeline
syntax — a learning cliff for a geospatial-novice, but very small once
climbed. Compute and bandwidth are minimized; latency is bounded.

**B. USGS 3DEP via bulk LAZ download.** Conceptually simpler ("just curl
the tile"). Works fine for batch / offline workflows.
*Tradeoff:* tile sizes blow the sub-5-min latency budget on a cold
fetch over residential broadband. Caching helps but the first hit per
work unit is brutal.

**C. State LiDAR programs as primary, 3DEP fallback.** Higher quality
where available.
*Tradeoff:* every state is a custom integration — coordinate-system
conventions, file formats, classification schemes vary. Not realistic
in 4 days.

**D. Skip public LiDAR, use commercial.** Off the table on budget.

## Decision

**A. USGS 3DEP via COPC + PDAL, with WESM as the spatial index.**
PDAL is the workhorse — its JSON-pipeline interface composes the
read → filter (classification 6 = building) → crop (to building
footprint) → write steps cleanly.

State LiDAR programs are a **future enhancement**, not v1.

## Rationale

COPC + PDAL is the only combination that hits the brief's <5 min latency
budget on a cold (uncached) address without violating the "free public
data" cost story. Streaming the spatial chunks the job actually needs —
roughly the bounding box of the parcel — typically transfers
single-digit MBs versus hundreds of MBs for a bulk LAZ. That is the
difference between "demo lands in 90 seconds" and "demo eats the room's
patience."

PDAL is the right abstraction because the pipeline (LAZ → filter ground
vs non-ground → keep class 6 → crop to footprint → write to memory for
plane fitting) is exactly the example pipeline its docs are organized
around. The candidate gets to learn it on the documented happy path
instead of fighting it.

Indexing via WESM is the small-but-load-bearing decision that prevents a
common failure mode: blindly trying multiple tiles and discovering after
the fetch that the address is in a 3DEP gap. WESM lets us **check
coverage upfront** — within the first second of a job — and route to the
ADR-001 fallback path immediately when LiDAR is unavailable. That's the
honesty layer the architecture depends on.

## Tradeoffs & risks

- **3DEP coverage is uneven.** This is the largest risk to the
  architecture, not to this specific access decision. WESM gives us
  honest "do we have LiDAR for this address?" answers; the fallback to
  imagery-only (ADR-001) handles the rest.
- **3DEP recency varies wildly by region** (some captures are 5+ years
  old; new construction won't be in the cloud). Mitigation: surface the
  acquisition year alongside the measurement; cross-check the LiDAR
  outline against the NAIP imagery and flag large discrepancies as
  "likely new construction — verify."
- **PDAL is C++ underneath with Python bindings**; install can be
  finicky in some environments (especially via pip on macOS arm64).
  Mitigation: pin to a known-good conda-forge build; document the
  install path in README. Worst case the geospatial pipeline runs in a
  Docker container with PDAL pre-installed.
- **COPC is newer than EPT;** some older 3DEP work units may only have
  EPT. Mitigation: PDAL reads both via the same `readers.ept` /
  `readers.copc` drivers; the access module abstracts over them.
- **Classification quality varies by vendor/year.** USGS 3DEP uses
  ASPRS classes (class 6 = building, class 2 = ground), but some
  contractors mis-classify aggressively. Mitigation: cross-check
  classified-building points against the building footprint polygon
  and re-classify outliers locally.

## Consequences for the build

- **The LiDAR ingest module** has three responsibilities, in this order:
  1. **Coverage check** against the WESM GeoPackage (returns `LIDAR_AVAILABLE`
     / `LIDAR_MISSING` with acquisition metadata).
  2. **Streamed crop** via PDAL pipeline on the address's bounding box.
  3. **Building-class filter + footprint mask** (intersect with the
     MS Building Footprints polygon from ADR-004).
- **Output of the module** is a NumPy `(N, 3)` ground-classified-building
  point array in a **local projected CRS** (UTM zone for the address,
  selected via `pyproj`), not WGS84 lat/lng. Areas are computed in this
  CRS.
- **Caching:** WESM is a one-time download (~200 MB); cache locally.
  Per-address cropped point clouds cache to disk (small, ~1 MB
  typical).
- **PDAL is the dependency boundary.** No other parts of the system
  speak LAZ/COPC. Plane fitting (ADR-NNN forthcoming) consumes the
  cropped NumPy array.
- **The fallback path is wired now:** `LIDAR_MISSING` from the
  coverage check immediately routes to the imagery-only pipeline.
