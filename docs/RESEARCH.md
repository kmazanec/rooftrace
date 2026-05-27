# RESEARCH.md — Precision Roof Measurement & Complexity Mapping

> **Audience:** a sharp but novice engineer learning the domain in days, who has to defend tech choices to a CTO.
> **Build window:** 4 days. Every section ends with a verdict: **USE THIS**, **CONSIDER**, or **RESEARCH ONLY — TOO RISKY**.
> **Accuracy target:** ±3% area, sub‑5‑minute job latency.
>
> **Note on sources:** WebSearch/WebFetch were unavailable in this research session; citations point to the canonical primary sources (vendor docs, USGS portals, paper venues) that the reader should open and verify before quoting numbers in a proposal. Pricing and free‑tier numbers were current as of late 2024–early 2026 and *must* be re‑checked at quote time.

---

## Part 1 — Data Sources

### 1. Satellite / aerial imagery providers

**What it is.** Tiled raster imagery of the Earth's surface, either from satellites (sub‑meter to ~30 cm) or from manned/UAV aerial campaigns (5–15 cm GSD). Two flavors:
- **Orthorectified / nadir** — straight down, geometrically corrected. Use for area and footprint measurement.
- **Oblique / "bird's eye"** — 45° views from four cardinal directions. Use for pitch, façade features, dormer detection.

**Problem it solves.** Gives you a top‑down picture of a roof before anyone visits the site. Without it you have nothing to measure or to feed a vision model.

**Main alternatives + tradeoffs.**

| Provider | GSD | Refresh | Commercial license | Cost (approx.) |
|---|---|---|---|---|
| **USDA NAIP** (free) | 0.6 m (some 0.3 m) | ~2 yr per state | Public domain | $0 |
| **Esri World Imagery** | 0.3–1 m mix | Mixed | Allowed via paid ArcGIS plan; "for evaluation" only on free | Bundled with ArcGIS |
| **Mapbox Satellite** | ~0.3 m in metros | Mixed (Maxar + open) | Per Mapbox TOS, must render through Mapbox | Free tier 50k Static Images/mo, then ~$1/1000 |
| **Google Maps Static** | varies (very good in US metros) | Mixed | TOS forbids caching/storing tiles >30 days, no derivative datasets | $200/mo free credit, then ~$2/1000 static images |
| **Bing Maps Aerial + Bird's Eye** | 0.3 m + oblique | Mixed | Basic key free for low volume; enterprise required at scale | Moving to Azure Maps; legacy keys deprecating |
| **Nearmap** | 5.8–7.5 cm | 2–6× per year, US/AU urban | Commercial license, MSA + per‑sqkm fee | Enterprise contract, ~$5k+/yr entry |
| **EagleView / Vexcel** | 7.5 cm + oblique | 1–3×/yr urban | Per‑report or enterprise | $20–$90/report typical |
| **Maxar / Planet** | 0.3 m / 3 m daily | Daily (Planet) | Tasking + archive licenses | Enterprise |

**What do EagleView / Hover / GAF QuickMeasure actually use under the hood?**
- **EagleView** owns a fleet that flies its own oblique + nadir imagery (Pictometry technology — 5 views per location: 1 nadir + 4 obliques at ~45°). Roof measurements are produced by a human‑in‑the‑loop pipeline (analysts trace ridges and eaves in 3D from the multi‑view imagery, with ML assistance increasing each year). The accuracy claim (~±5%) is supported by manual QA.
- **Hover** does **not** use satellite — it uses **smartphone photogrammetry**: a guided 8–11 photo capture loop around the house, processed server‑side via structure‑from‑motion to a textured 3D mesh. They've branched into aerial too, but the SFM pipeline is their core IP.
- **GAF QuickMeasure** is a re‑seller pipeline: it takes aerial imagery (their own + partners), runs ML detection, then a human reviews. Pricing is per report (~$15–$30) with ~24 h turnaround.

**Gotchas / footguns for roofs.**
- *Stale imagery* — a roof replaced last year may still show the old shingle pattern, ridge count etc. Always show the capture date in the UI and let the user reject.
- *Tree occlusion* — nadir alone fails when canopy covers ridges. Need oblique or LiDAR backup.
- *Off‑nadir scaling* — Google/Bing "satellite" tiles in many metros are actually aerial orthos with residual lean on tall buildings. Measure on the ground plane only.
- *TOS landmines* — Google explicitly forbids using Static Maps imagery as training data for derivative ML models. Mapbox is friendlier; NAIP is fully permissive.
- *GSD ≠ measurable accuracy* — a 30 cm pixel does not give you 30 cm edge accuracy. Realistic single‑image edge precision is ~2–3 pixels.

**Verdict.**
- **USE THIS:** NAIP (free baseline, US‑only); Mapbox Satellite (interactive base map + capture); Bing Bird's Eye oblique (where available, for pitch sanity check via legacy Bing Maps key).
- **CONSIDER:** Nearmap free‑trial for 1–2 demo addresses to show "what good looks like" in the pitch.
- **TOO RISKY:** building any production flow on EagleView/Hover APIs (they are the competitors).

**Links.** [USDA NAIP via NRCS](https://naip-usdaonline.hub.arcgis.com/) · [Mapbox Raster Tiles pricing](https://www.mapbox.com/pricing#raster-tiles) · [Google Maps Platform terms §3.2.4](https://cloud.google.com/maps-platform/terms).

---

### 2. Public LiDAR — USGS 3DEP

**What it is.** The **3D Elevation Program** is the federal effort (USGS + partners) to acquire LiDAR coverage of the entire conterminous US. It publishes:
- **Raw point clouds** (`.laz`) — every laser return, classified (ground=2, building=6, vegetation=3/4/5, etc.).
- **Derived DEM** (Digital *Elevation* Model — bare earth raster, 1 m default).
- **Derived DSM** (Digital *Surface* Model — first returns, includes buildings + trees).

**Problem it solves.** Gives you absolute 3D coordinates of roof points, which is the only practical way to get true **slope‑corrected area** and to disambiguate roof from tree from neighbor without manual annotation.

**Quality levels:**

| Level | Nominal pulse spacing | Vertical RMSE | Typical use |
|---|---|---|---|
| QL0 | ≤0.35 m, ≥8 pts/m² | ≤5 cm | Research, infrastructure |
| QL1 | ≤0.35 m, ≥8 pts/m² | ≤10 cm | Detailed engineering |
| **QL2** | ≤0.71 m, **≥2 pts/m²** | **≤10 cm** | **Default 3DEP target — what you'll find for most of the US** |
| QL3 | ≤1.41 m, ≥0.5 pts/m² | ≤20 cm | Older / rural |

**Access paths (pick one).**
1. **The National Map (TNM) Download API** — `https://tnmaccess.nationalmap.gov/api/v1/products` lets you query by bounding box and `datasets=Lidar Point Cloud (LPC)`; returns S3 download URLs for tiled `.laz` (usually 1×1 km USGS tiles, hundreds of MB each). Good for batch / nightly.
2. **AWS Open Data — `s3://usgs-lidar-public`** — same point clouds re‑packaged as **EPT (Entwine Point Tile)** — an HTTP‑range‑readable octree, no auth, no egress fee. **This is what you want for a web app**: PDAL can stream just the points in your AOI bounding box in a few seconds instead of downloading 800 MB tiles. Resource page: [USGS 3DEP LiDAR Point Clouds on AWS Open Data Registry](https://registry.opendata.aws/usgs-lidar/).
3. **OpenTopography portal** — friendlier UI, lets you crop to AOI and reproject before download; rate‑limited but free with academic/login.
4. **State portals** — NY GIS Clearinghouse, NC OneMap, PASDA (PA), WA DNR LIDAR Portal, etc. Often *newer* than 3DEP (states fly more frequently). Worth scripting per‑state fallbacks.

**Gotchas / footguns for roofs.**
- *Coverage gaps* — by 2024 3DEP had ~85% CONUS coverage; the last gaps are mostly Texas/Oklahoma rural plus some Plains states. Build a **graceful fallback** (DSM‑from‑stereo‑imagery, or photogrammetry from mobile) before you commit to "LiDAR for every address."
- *Recency* — vintage ranges from 2008 to current. A 2014 scan of a roof that was rebuilt in 2020 is wrong. Always show the acquisition year alongside the measurement.
- *Classification quality* — building class (6) is not always populated. If it's missing, you'll need to (a) clip the cloud to the parcel/building footprint and (b) run a ground/non‑ground filter (SMRF or PMF in PDAL) yourself.
- *Vertical datum* — 3DEP uses NAVD88 + GEOID model; if you mix with another source you'll get meter‑scale offsets. Stick to one source per job.
- *EPT vs COPC* — newer `usgs-lidar-public` tiles are migrating from EPT to **COPC** (Cloud Optimized Point Cloud, a single `.laz` with HTTP range‑reads). PDAL ≥2.4 reads both; new code should target COPC.
- *DEM vs DSM vs point cloud for roof measurement* — for roof pitch you need DSM **or** point cloud. The DEM is bare earth; it will lie about your roof.

**Verdict.**
- **USE THIS:** EPT/COPC streaming from `s3://usgs-lidar-public` via PDAL. This is the single highest‑leverage data source you have. Plan to demo on an address with known 3DEP QL2 coverage.
- **CONSIDER:** State‑level portals as recency fallback for marquee demos.
- **TOO RISKY:** assuming nationwide LiDAR coverage on day 1 — build the no‑LiDAR fallback in parallel.

**Links.** [USGS 3DEP product specs](https://www.usgs.gov/3d-elevation-program/about-3dep-products-services) · [USGS 3DEP on AWS Open Data](https://registry.opendata.aws/usgs-lidar/) · [PDAL EPT reader docs](https://pdal.io/en/stable/stages/readers.ept.html).

---

### 3. Parcel data

**What it is.** Polygon + attributes for every legal land parcel in a county: boundary, owner, address, lot size, year built, building footprint (sometimes), legal use, etc. Aggregated nationally by a handful of vendors.

**Problem it solves.** Lets you go from "123 Main St" → exact AOI polygon → clip imagery/LiDAR to one property → know "single family / built 1998 / 2400 sqft heated" without scraping.

**Main alternatives + tradeoffs.**

| Source | Coverage | Free tier | Pricing | Includes building footprint? |
|---|---|---|---|---|
| **Regrid** (née Loveland) | All ~150 M US parcels | Trial only | Bulk ~$15–50k/yr; per‑county available; **per‑parcel API ~$0.10–0.40** | Yes (where available) |
| **ReportAll USA** | ~3000 counties | Limited dev key | API ~$0.02–0.10/parcel | Yes (where available) |
| **ATTOM** | National | Sandbox | Enterprise | Yes + assessor + tax |
| **County GIS portals** | One county at a time | Free | $0 — but ETL is painful | Often yes |
| **Microsoft Building Footprints** | Global ~1.3 B buildings | **Free** (ODbL) | $0 | Just the footprint polygon |
| **OSM `building=*`** | Global, dense in cities | **Free** (ODbL) | $0 | Yes, sometimes with `building:levels` |

**Gotchas / footguns for roofs.**
- *Parcel ≠ building* — the parcel is the lot. You still need a building footprint to clip the roof. Microsoft Building Footprints + a centroid match is the cheapest way to get there.
- *Footprint is the wall outline, not the roof outline* — eaves overhang. Roofs are typically 0.3–0.9 m larger per edge than the footprint. Use the footprint as a *seed* mask and grow it from the imagery/LiDAR, don't trust it as the answer.
- *Microsoft footprints are ML‑derived* — outdoor sheds, partial demos, and duplexes split across parcels all create false positives. Treat them as a prior.
- *Vendor TOS* — Regrid forbids redistributing raw parcel polygons; you can show them in your UI but not export to customers.

**Verdict.**
- **USE THIS:** Microsoft Building Footprints (free, instant) as the default footprint source; Regrid free trial for demo addresses to show parcel context.
- **CONSIDER:** ReportAll for cheap per‑lookup if you need owner/assessment data.
- **TOO RISKY:** scraping county portals at scale in 4 days.

**Links.** [Microsoft Building Footprints (GitHub)](https://github.com/microsoft/USBuildingFootprints) · [Regrid API docs](https://app.regrid.com/api).

---

## Part 2 — Geometry Extraction

### 4. LiDAR processing

**What it is.** Software to read point clouds, filter them, fit surfaces, and rasterize results. The Python ecosystem is centered on **PDAL** (the GDAL of point clouds).

**Problem it solves.** Turns a 50 MB `.laz` blob into "this roof has 6 planes, the south face is 26° at 412 sqft true area."

**Stack you'll actually use.**
- **PDAL** — declarative JSON pipelines (`reader → filters.crop → filters.smrf → filters.range → writers.gdal`). The right tool for streaming from EPT/COPC and producing a DSM raster.
- **laspy** — pure Python `.las/.laz` reader; good for ad‑hoc inspection.
- **Open3D** — point cloud + mesh ops in Python (RANSAC plane segmentation, normals, ICP). Great for the "find roof planes" step.
- **scikit‑learn / pyransac3d** — quick RANSAC plane fits without Open3D's full footprint.
- **CloudCompare** — GUI; use it for visual debugging only.
- **whitebox‑tools** — alternative to PDAL for hydrology‑style raster ops.

**Canonical 4‑day pipeline.**
1. Look up parcel + footprint (§3).
2. Compute AOI bbox in EPSG:3857, fetch points from EPT/COPC via PDAL `readers.ept`.
3. `filters.crop` to footprint polygon (buffered +1 m for eaves).
4. If `Classification` is good: `filters.range` with `Classification[6:6]` to keep building points; else run `filters.smrf` to label ground, then take non‑ground above ground+2 m.
5. **RANSAC plane segmentation** (Open3D `segment_plane`, iteratively): each plane = one roof face. Stop when remaining points are <5% of building.
6. For each plane: compute area of points projected to the plane (convex hull or alpha shape), then **true area** = planimetric area / cos(pitch). Pitch comes from the angle between the plane normal and vertical.
7. Intersect adjacent planes to recover **ridge and hip lines**; intersect with eave height to recover the eave polygon.

**Common formula.** For any roof face with pitch θ (angle from horizontal):
`true_area = planimetric_area / cos(θ)` — i.e., a 1000 sqft footprint at 7/12 pitch (30.3°) is **1158 sqft** of actual roof.

**Gotchas / footguns.**
- *Sparse points on small dormers* — at 2 pts/m² a 6 ft² dormer face has ~1 point. RANSAC needs ≥3. Use imagery to detect, LiDAR only to measure planes ≥~20 ft².
- *Trees that look like roofs* — vegetation returns sometimes survive SMRF. Cap height (no roof point > 15 m above ground unless tall structure).
- *Edge points* — laser returns at roof edges scatter. Trim outermost 1–2 returns per ridge before plane‑fit, or use M‑estimator RANSAC.
- *Z bias* — LiDAR returns the *top* of the shingle, not the deck. Negligible (~1 cm) for area, but matters if you're comparing two flights.

**Verdict.**
- **USE THIS:** PDAL + Open3D + a custom Python wrapper. This is the proven stack.
- **CONSIDER:** Pre‑built `pdal pipeline` JSON files committed to the repo for repeatability.
- **TOO RISKY:** trying to write your own LAZ reader.

**Links.** [PDAL Python docs](https://pdal.io/en/stable/python.html) · [Open3D segment_plane](https://www.open3d.org/docs/release/tutorial/geometry/pointcloud.html#Plane-segmentation).

---

### 5. Roof segmentation from imagery

**What it is.** Given a satellite image, output a pixel mask of the roof (or per‑face).

**Problem it solves.** When LiDAR is missing or stale, imagery + segmentation gives you the footprint and approximate face boundaries. Also the *only* signal for small features (vents, skylights).

**Main alternatives + tradeoffs.**

| Approach | Train time | Accuracy on roofs | Cost / inference |
|---|---|---|---|
| **SAM 2** (Meta) zero‑shot, click prompts | 0 | High mask quality but doesn't know what to click | ~200 ms on A10 |
| **Grounding DINO + SAM** (text → boxes → masks) | 0 | Decent for "roof", weak for "ridge" | ~1 s on A10 |
| **Microsoft Building Footprints** (pretrained delivery) | 0 | Building‑level only | Free static |
| **Mask R‑CNN fine‑tuned on Inria/AIRS** | days | High footprint accuracy | ~150 ms |
| **Custom UNet on RoofN3D** | days + GPU | Per‑face possible | low |

**Datasets to know.**
- **Inria Aerial Image Labeling** — 5 cities, building/no‑building binary mask, 0.3 m GSD.
- **AIRS** — 30 cm aerial of Christchurch NZ, roof‑level mask.
- **RoofN3D** — 118k roofs in 3D from Berlin LiDAR; lets you train face‑level classifiers.
- **RID (Roof Information Dataset)** — Munich, roof type + segment labels.
- **CrowdAI Mapping Challenge** — global building masks.

**Gotchas / footguns for roofs.**
- *Generic segmentation models drift* — SAM happily masks the whole house including walls in oblique imagery. Always feed nadir.
- *Per‑face* segmentation is a *much* harder task than per‑building. Don't promise it from imagery alone in 4 days.
- *Shadows look like roof edges* — false ridges. Use LiDAR pitch as the truth.
- *No model knows your address* — you have to feed it the right image at the right zoom. Standardize to ~10 cm/pixel before inference.

**Verdict.**
- **USE THIS:** SAM 2 with a single positive click on the building centroid for mask cleanup; Microsoft Building Footprints as the prior.
- **CONSIDER:** Grounding DINO if you need to seed "find the chimney" boxes (overlaps with §8).
- **TOO RISKY:** training a custom roof‑face segmenter in 4 days; you'll lose 2 days to data wrangling.

**Links.** [Segment Anything 2](https://ai.meta.com/sam2/) · [Inria Aerial Image Labeling](https://project.inria.fr/aerialimagelabeling/).

---

### 6. Edge / vertex extraction & roof topology

**What it is.** Going from a raster mask or a point cloud to a *vector* graph: nodes are corners, edges are eaves/ridges/hips/valleys.

**Problem it solves.** A vector roof is what you draw, dimension, and export. It's what the contractor reads on the PDF.

**Pragmatic 4‑day approach.**
1. **From LiDAR (preferred):** plane segmentation (§4) gives you N planes. Compute the line of intersection of each *pair* of adjacent planes — that's a ridge, hip, or valley (the sign of the dihedral angle tells you which). Clip each line to the convex hull of its two planes. This recovers topology directly from geometry — no learned model needed. Cite Henn et al. 2013 / Verdie 2015 for the canonical formulation.
2. **From mask:** extract polygon contour (OpenCV `findContours`), then **Douglas‑Peucker** simplification (`cv2.approxPolyDP`, ε ≈ 0.5 m equivalent). Snap to dominant orientations (most roofs are rectilinear at one of 1–2 angles — fit two perpendicular axes and snap edges within 10°).
3. **Hough transforms** on the DSM gradient give you candidate ridge lines, but in practice plane‑intersection is more robust.
4. **RoofGraphNet / Roof‑GAN / PolyWorld** — academic models that emit polygonal roof graphs end‑to‑end. **Don't ship these in 4 days** — pretrained weights are scattered and the inference code is research‑grade.

**Gotchas / footguns.**
- *Over‑simplification* — Douglas‑Peucker with too large an ε will erase dormers; too small and your eave looks crinkled. ε ≈ ½ the eave overhang is a good start.
- *Open contours* — when a roof touches a neighbor, the footprint mask leaks. Always clip to parcel + 1 m.
- *Numerical degeneracy* — two near‑parallel planes intersect at infinity. Skip pairs with dihedral angle <10°.
- *Coordinate units* — do the simplification in *meters in a projected CRS*, never in degrees (see §21).

**Verdict.**
- **USE THIS:** plane‑intersection from RANSAC (LiDAR) + Douglas‑Peucker with orientation snapping (mask fallback).
- **CONSIDER:** committing a vector roof JSON schema early so downstream PDF/export work isn't blocked.
- **TOO RISKY:** RoofGraphNet / Roof‑GAN class models — research only.

**Links.** [Henn 2013 — Automatic classification of building types in 3D city models](https://www.tandfonline.com/doi/full/10.1080/10095020.2013.766266) · [OpenCV `approxPolyDP`](https://docs.opencv.org/4.x/dd/d49/tutorial_py_contour_features.html).

---

### 7. Pitch / slope estimation

**What it is.** Recovering the angle of each roof face from horizontal, usually quoted in X/12 (rise/run).

**Problem it solves.** Without pitch you cannot quote true square footage, material quantities, or labor — and you cannot pass ±3% accuracy.

**Methods + realistic accuracy.**

| Method | Inputs | Realistic accuracy | Notes |
|---|---|---|---|
| LiDAR plane normal | 3DEP point cloud | **±1–2°** (≈ <1% area error) | Gold standard |
| Multi‑view photogrammetry | Mobile capture | ±3–5° | Hover‑style |
| Oblique single image + sun shadow | Bird's Eye + sun azimuth/elevation | ±5–10° | Needs known shadow length; sun angle from `pysolar` |
| ML pitch from nadir alone | Single image | ±5–8° in best paper conditions | Brittle out of distribution |
| User‑confirmed dropdown (4/12, 6/12, 8/12, 12/12) | Human | ±1 increment | Cheap, surprisingly good fallback |

**Gotchas / footguns.**
- *Pitch dominates area error* — a 5° error at 30° pitch = 4.5% area error. You almost certainly fail ±3% without LiDAR *or* mobile photogrammetry *or* a human confirmation step.
- *Mansards and gambrels* — multiple pitches per face. Plane segmentation handles this if you don't merge planes too eagerly.
- *Flat roofs (<5°)* — RANSAC fits unstable. Treat anything <5° as flat.

**Verdict.**
- **USE THIS:** LiDAR plane normals where 3DEP exists; mobile capture (§11) as the secondary; user dropdown as the final fallback. Show the user *which* method was used, with a confidence indicator.
- **CONSIDER:** sun‑shadow estimator as a cheap sanity check.
- **TOO RISKY:** ML‑from‑single‑image as the *only* source of pitch.

**Links.** [pysolar](https://pysolar.readthedocs.io/) · [3DEP point cloud specs](https://www.usgs.gov/3d-elevation-program).

---

## Part 3 — Feature Detection (vents, chimneys, dormers, skylights, sat dishes)

### 8. Open‑vocabulary vision models

**What it is.** Models that take *text* + *image* and return boxes or masks, without per‑class training. The big three: **Grounding DINO**, **OWL‑ViT / OWLv2**, **GLIP**.

**Problem it solves.** With 4 days and no labeled rooftop dataset, you cannot train a custom YOLO. Open‑vocab lets you ship "detect chimneys, vents, skylights" by *prompting*.

**Tradeoffs.**

| Model | Quality on small rooftop objects | Speed (A10) | Notes |
|---|---|---|---|
| Grounding DINO‑T | Decent at >30 px objects | ~700 ms | Pair with SAM for masks |
| OWLv2 (Google) | Good at small objects, weaker text grounding | ~400 ms | Hugging Face `google/owlv2-base-patch16-ensemble` |
| GLIP | Older, slower | ~1.5 s | Mostly superseded |

**Gotchas / footguns for roofs.**
- *Tiny objects* — a chimney from satellite at 30 cm GSD is ~10–20 px. Below 16 px, recall craters. Upscale 2× before inference.
- *Domain gap* — these models were trained on COCO‑like ground imagery, not nadir aerial. "Skylight" gets confused with "window."
- *No 3D context* — a satellite dish on a balcony vs. on the roof looks the same. Always intersect detections with the roof mask.
- *Cost* — running 4–5 prompts per image at 700 ms each = 3–4 s of GPU per address. Budget accordingly.

**Verdict.**
- **USE THIS:** Grounding DINO (or OWLv2) + SAM 2 for the chimney/skylight/sat dish stack. This is the only way to hit "no training data" with reasonable recall.
- **CONSIDER:** ensembling with a VLM (§9) for hard cases.
- **TOO RISKY:** trusting raw boxes without the roof‑mask intersection sanity filter.

**Links.** [Grounding DINO](https://github.com/IDEA-Research/GroundingDINO) · [OWLv2 paper](https://arxiv.org/abs/2306.09683).

---

### 9. VLMs as detectors

**What it is.** Use a multimodal LLM (GPT‑4o, Gemini 2.0/2.5 Flash, Claude 3.5/Sonnet vision) as an open‑vocab detector by prompting for JSON bounding boxes.

**Problem it solves.** Zero infra, structured output, can answer *follow‑up* questions ("which of these is closest to the ridge?") that a pure detector can't.

**Tradeoffs.**

| Model | Detection skill | $/image | Latency | Box quality |
|---|---|---|---|---|
| GPT‑4o | Good named recall; box coords are *approximate* (often percentile, not pixel) | ~$0.005–0.02 | 3–8 s | ±5% of image dimension |
| Gemini 2.0/2.5 Flash | Strongest native bbox support among VLMs — explicit `[ymin, xmin, ymax, xmax] / 1000` convention | ~$0.001 | 2–4 s | ±2% with prompt discipline |
| Claude 3.5 Sonnet vision | Best at *reasoning* about a scene, weaker at exact pixel coords | ~$0.003–0.015 | 3–6 s | ±5% |

**Gotchas / footguns.**
- *Hallucinated counts* — VLMs will happily invent a fourth vent that isn't there. Always require evidence (cropped chip) before counting.
- *Coordinate convention drift* — same model, different prompt, swaps `xy` for `yx`. Pin a `# coordinates are normalized 0..1000 in [ymin, xmin, ymax, xmax]` instruction and unit‑test it.
- *Cost at scale* — fine for the demo (50 addresses × $0.01 = $0.50). Plan for fallback if production goes 10k/day.
- *Latency budget* — at 6 s per call you have ~50 sec of VLM budget in your 5‑minute SLO.

**Verdict.**
- **USE THIS:** Gemini 2.0/2.5 Flash with JSON mode for "verify and label each detection from §8." Cheapest + best box convention.
- **CONSIDER:** GPT‑4o as a second opinion for low‑confidence cases.
- **TOO RISKY:** using only a VLM with no geometric detector — recall will be sporadic.

**Links.** [Gemini bounding boxes docs](https://ai.google.dev/gemini-api/docs/vision) · [OpenAI structured outputs](https://platform.openai.com/docs/guides/structured-outputs).

---

### 10. Specialized models (YOLO, roof datasets)

**What it is.** Fine‑tuned closed‑vocabulary detectors. **YOLOv8 / v11** (Ultralytics) is the default. Roof‑specific datasets: **RID** (Munich, roof segments + classes), **Roofline‑Extraction** (Wuhan), **AIRS** (NZ, building masks).

**Problem it solves.** Where you have labeled data, fine‑tuned YOLO is 10× faster and more accurate than open‑vocab.

**Tradeoffs.**
- You need ≥300 labeled instances per class to get decent recall — that's a week of labeling, not a 4‑day task.
- Pretrained roof‑object weights are rare; "rooftop solar panel detection" weights exist (Stanford DeepSolar, Google Sunroof's open releases), but vents/chimneys/dormers do not have well‑known checkpoints.
- Ultralytics licensing is **AGPL** for the library; commercial use requires a paid license (~$1k/seat/yr).

**Verdict.**
- **TOO RISKY** for the 4‑day window unless a pretrained checkpoint already covers your class. Park as a v2 path.
- **CONSIDER:** DeepSolar / Sunroof solar‑panel weights if "solar" becomes a customer ask later.

**Links.** [RID dataset paper](https://www.mdpi.com/2072-4292/14/13/3225) · [Ultralytics license terms](https://www.ultralytics.com/license).

---

## Part 4 — Mobile Capture

### 11. iOS — ARKit, RoomPlan, Object Capture

**What it is.** Apple's three‑layer AR stack:
- **ARKit** — world tracking, scene depth from LiDAR (iPhone Pro 12+, iPad Pro 2020+), `ARMeshAnchor` (a triangle mesh of the scene).
- **RoomPlan** — high‑level *indoor* room reconstruction (walls/doors/furniture). Useless for roofs.
- **Object Capture** (`PhotogrammetrySession`, iOS 17+ on‑device, macOS since 12) — photogrammetry from a folder of photos → USDZ/OBJ.

**Problem it solves.** The contractor standing in the driveway can shoot the house and your app can supply (a) a mesh of the roof front (LiDAR), (b) a photogrammetric model (Object Capture), or (c) at minimum oriented photos with depth and pose for server‑side SFM.

**Consumer LiDAR accuracy.** Apple advertises ~1 cm at <1 m, degrading to ~5 cm at 5 m, ~10 cm at 10 m. **It will not see a roof ridge from the street.** Useful for eave heights, gutter inspection, façade features visible from the ground.

**Gotchas / footguns.**
- *Range* — LiDAR effectively dies past ~5 m. The whole roof from the street is out of range.
- *Sky / glass* — the sensor returns nothing on sky and noisy data on glass (skylights!).
- *Walking the perimeter* — guided‑capture UIs (Hover‑style) ask for ~8–11 photos around the house at ~10 m radius, with the *whole* house in frame. That's the productive use of mobile.
- *Battery + thermal* — sustained ARKit + Neural Engine = ~6% battery / minute. Cap capture loops to 90 s.

**Verdict.**
- **USE THIS:** ARKit `ARWorldTrackingConfiguration` + pose‑tagged photo capture as the *guided* loop; pose+GPS+depth (when available) shipped to server.
- **CONSIDER:** on‑device Object Capture for one‑story houses where the user can walk all sides.
- **TOO RISKY:** relying on phone LiDAR for primary roof measurement (wrong tool for the range).

**Links.** [ARKit Scene Depth](https://developer.apple.com/documentation/arkit/arconfiguration/3674209-framesemantics) · [Object Capture overview](https://developer.apple.com/augmented-reality/object-capture/).

---

### 12. Android — ARCore

**What it is.** Google's AR runtime. **Depth API** works on most modern Androids via ToF or stereo‑inferred depth. **No consumer phone ships a true LiDAR sensor** in the Apple sense.

**Problem it solves.** Cross‑platform parity for the guided‑capture UX. Pose, motion tracking, GPS, ToF depth on flagship devices.

**Gotchas.**
- Depth quality varies wildly device‑to‑device. Plan to ignore depth on Android and rely on multi‑view SFM server‑side.
- ARCore world tracking drifts more than ARKit on outdoor scenes; the "around the house" loop is harder to keep aligned.

**Verdict.**
- **USE THIS** for pose + photos only. Treat Android depth as informational, not authoritative.
- **TOO RISKY:** treating Android as feature‑parity with iPhone Pro for the LiDAR pieces.

**Links.** [ARCore Depth API](https://developers.google.com/ar/develop/depth).

---

### 13. React Native / Expo for AR

**What it is.** Cross‑platform mobile JS frameworks. **viro‑react** is the historical RN AR wrapper (unmaintained‑ish). **expo‑three / expo‑gl** plus a custom native module is the modern route. Expo has no first‑party ARKit module.

**Problem it solves.** One codebase, two platforms — *if* AR is shallow.

**Tradeoffs.**
- For our use case (guided capture, pose‑tagged photos, optional LiDAR mesh) the AR bits are not shallow. You will end up writing a Swift bridge for ARKit and a Kotlin bridge for ARCore anyway.
- React Native UI shell + two thin native AR modules is a reasonable middle ground.
- **Flutter** is a viable alternative; `ar_flutter_plugin` exists but lags Apple releases.

**Verdict.**
- **CONSIDER:** RN/Expo for the non‑AR shell + two native modules — *if* you have RN expertise already.
- **USE THIS** if you have native iOS/Android experience: ship iOS first as native Swift (where the actual LiDAR value lives), defer Android.

**Links.** [Expo modules](https://docs.expo.dev/modules/overview/) · [viro-react](https://github.com/ViroCommunity/viro).

---

### 14. Photogrammetry on mobile

**What it is.** Recover 3D structure from 2D photos. On iOS 17+, `PhotogrammetrySession` runs entirely on‑device (Apple Silicon). Server‑side: **Meshroom** (free, AliceVision), **RealityCapture** (Epic, now free for commercial), **Polycam Cloud**, **Luma AI** (NeRF), **Postshot/Nerfstudio/Gaussian Splatting** for novel‑view rendering.

**Problem it solves.** Builds a textured 3D mesh of the house from a walk‑around. This is what Hover does.

**Tradeoffs.**

| Stack | Where it runs | Speed for 30 photos | Cost | Output |
|---|---|---|---|---|
| ARKit Object Capture | Device, M‑class | 2–5 min | $0 | USDZ |
| Meshroom | Server (CUDA) | 10–30 min | self‑hosted | OBJ + texture |
| RealityCapture | Server (CUDA, Windows) | 5–15 min | Free under Epic license | OBJ/FBX |
| Polycam Cloud | Hosted | 2–5 min | ~$15/mo dev tier | GLB |
| Gaussian Splatting (Nerfstudio) | Server (CUDA) | 10–60 min | self‑hosted | `.ply` splats |

**Gotchas / footguns for roofs.**
- *Texture‑less sky* — SFM hates uniform regions; sky becomes noise. Mask before reconstruction.
- *Moving leaves, sun, shadows* between photos break matching. Capture in <2 minutes if possible.
- *Scale ambiguity* — pure SFM is up‑to‑scale. You need ARKit's metric pose, or a GPS baseline, or a known reference object. ARKit gives you this for free; Android Meshroom does not.
- *NeRF / Splats are not yet measurement‑grade.* They look great, they don't measure to ±3%.

**Verdict.**
- **USE THIS:** ARKit Object Capture on iOS 17+ for the on‑device path; RealityCapture (free for commercial since 2024) on the server as the cross‑platform path.
- **RESEARCH ONLY:** NeRF / Gaussian Splatting for v2 visualization, not v1 measurement.

**Links.** [PhotogrammetrySession](https://developer.apple.com/documentation/realitykit/photogrammetrysession) · [Meshroom](https://alicevision.org/#meshroom).

---

## Part 5 — Backend & Infra

### 15. Async job orchestration

**What it is.** A queue + workers to run long jobs (download LiDAR, run inference, generate PDF) outside the request/response cycle.

**Problem it solves.** Your `/measure?address=` POST returns a `job_id` in 50 ms; the user polls or you push a webhook. Without this you tie up HTTP workers for 5 minutes.

**Stack comparison.**

| Tool | Lang | Setup time | Cost | Sweet spot |
|---|---|---|---|---|
| **Celery + Redis** | Python | 1 h | self‑host Redis | Long‑standing default; well documented |
| **RQ (Redis Queue)** | Python | 15 min | self‑host | Simpler than Celery |
| **Temporal** | Polyglot | 1 day | self‑host or Temporal Cloud | Saga‑style workflows; overkill at 4 days |
| **Inngest** | TS/Python | 30 min | Free tier 1k steps/mo | Event‑driven, durable, hosted |
| **Trigger.dev** | TS/Node | 30 min | Hosted free tier | Best DX for TS shops |
| **BullMQ** | Node | 30 min | self‑host Redis | Best Node queue |

**Gotchas.**
- *Idempotency* — your worker WILL retry. Make "generate PDF" idempotent (`job_id` in the filename).
- *Long jobs vs. visibility timeout* — SQS/Redis defaults are too short. Bump to 10 min explicitly.
- *GPU workers ≠ web workers* — separate queues, separate autoscale rules.

**Verdict.**
- **USE THIS:** Celery + Redis if Python; Trigger.dev if TS. Both ship in a day.
- **TOO RISKY:** Temporal — engineering overhead exceeds value at 4 days.

**Links.** [Celery docs](https://docs.celeryq.dev/) · [Trigger.dev v3](https://trigger.dev/docs).

---

### 16. GPU inference hosting

**What it is.** Hosted GPU runtime for short‑lived inference.

**Problem it solves.** You need ~30 seconds of A10/A100 per job (SAM 2 + Grounding DINO + maybe Meshroom). Owning a GPU box is overkill and slow to deploy.

**Comparison.**

| Provider | Cold start | $/hr (A10 class) | Notes |
|---|---|---|---|
| **Modal** | ~5–15 s | ~$0.60–1.10 | Best DX — Python decorators; container build cached |
| **Replicate** | 5–60 s (model‑dependent) | per‑prediction billing | Easy if your model is already on Replicate |
| **RunPod Serverless** | ~10–30 s | $0.40–0.80 | Cheapest A100 |
| **Banana** | varies | per‑sec | Smaller player |
| **Beam** | ~10 s | $0.50–1.00 | Python‑first |
| **AWS SageMaker** | 1–5 min for cold endpoints | $1+ | Enterprise compliance plays |
| **Fly.io GPUs** | ~10 s with `min_machines_running=1` | $1.25–2 (A100) | Co‑located with app |

**Gotchas.**
- *Cold start* hurts the 5‑minute SLO. Either keep `min_replicas=1` (paying for idle) or use a smaller default model and reserve big iron for paid tier.
- *Egress* — moving 500 MB of LiDAR to your inference host every job is expensive on some clouds. Co‑locate.
- *CUDA version mismatch* between SAM 2 weights and the runtime image is the #1 day‑1 footgun.

**Verdict.**
- **USE THIS:** Modal (best Python DX in 4 days). Fallback: Replicate for stock model endpoints.
- **TOO RISKY:** SageMaker for a 4‑day build.

**Links.** [Modal docs](https://modal.com/docs) · [Replicate models](https://replicate.com/explore).

---

### 17. Geospatial database

**What it is.** A DB that knows about geometry. **Postgres + PostGIS** is the gold standard, full stop.

**Problem it solves.** Store parcels, footprints, measured roofs; query "roofs within 1 km", "intersect parcel + footprint", compute area on a sphere.

**Critical PostGIS features for this app.**
- `geometry` vs `geography` types — `geography` is lat/lng on a sphere and `ST_Area` returns square meters directly. **Use `geography` for any user‑facing area calc.**
- `ST_Intersects`, `ST_Buffer`, `ST_Transform` (CRS reprojection), `ST_Simplify` (Douglas‑Peucker).
- Raster extension (`postgis_raster`) for storing DSMs — useful but not required for v1.

**Alternatives.**
- **DuckDB spatial** — great for analytics on parquet'd parcel files; no concurrent writes.
- **Shapely + GeoJSON files** — fine for a static demo; doesn't scale to multi‑user.
- **MongoDB 2dsphere** — supports basic spatial but lacks PostGIS depth.

**Gotchas.**
- *SRID confusion* — `ST_Area(geom)` on an EPSG:4326 geometry returns "square degrees" (meaningless). Either cast to `geography` or `ST_Transform` to a local UTM zone.
- *KNN on lat/lng* — use the `<->` operator with `geography` or you'll get bad orderings.
- *Index hygiene* — `CREATE INDEX ... USING GIST(geom)` is non‑negotiable for any column you'll filter on.

**Verdict.**
- **USE THIS:** Postgres + PostGIS. Hosted: Supabase, Neon (no PostGIS yet — check), Crunchy Data, RDS.
- **CONSIDER:** DuckDB spatial in the ETL layer for one‑time parcel loads.

**Links.** [PostGIS reference](https://postgis.net/docs/) · [Geography type docs](https://postgis.net/docs/using_postgis_dbmanagement.html#PostGIS_GeographyVSGeometry).

---

### 18. Map rendering on web

**What it is.** Interactive vector + raster map in the browser.

**Problem it solves.** Show the satellite, let the user adjust the roof polygon, render measurements as labels.

**Comparison.**

| Library | License | Notes |
|---|---|---|
| **MapLibre GL JS** | BSD‑3 | Free fork of Mapbox GL ≤1.x; works with self‑hosted tiles |
| **Mapbox GL JS** | Proprietary | Free up to 50k MAU; better styling tools |
| **deck.gl** | MIT | Layer system on top of MapLibre/Mapbox; great for thousands of polygons |
| **Leaflet** | BSD | Raster‑first; minimal; ok for MVP but no 3D |
| **OpenLayers** | BSD | Powerful, heavier API |

**Drawing tools.**
- **mapbox‑gl‑draw** — works with MapLibre with a small shim; basic vertex editing.
- **terra‑draw** — modern, headless, framework‑agnostic; better extensibility.

**Gotchas.**
- *Mapbox MAU pricing* trips up MVPs that get traction — switch the *base map style URL* to MapLibre + a free tile source (NAIP, OSM raster) before launch.
- *Vertex precision* — `mapbox‑gl‑draw` rounds to 6 decimals (~10 cm at the equator). Good enough.
- *Z‑order* on labels vs. polygons defeats many demos; use `symbol-sort-key`.

**Verdict.**
- **USE THIS:** MapLibre GL JS + terra‑draw + NAIP raster tiles for the editor; deck.gl `PolygonLayer` for the measured roof overlay.
- **CONSIDER:** Mapbox for the demo if its styling/3D terrain is worth the bill.

**Links.** [MapLibre GL JS](https://maplibre.org/maplibre-gl-js/docs/) · [terra-draw](https://github.com/JamesLMilner/terra-draw).

---

### 19. PDF export

**What it is.** Generate the contractor‑facing report.

**Options.**

| Tool | Strength | Weakness |
|---|---|---|
| **Playwright / Puppeteer `page.pdf()`** | Renders your live HTML/map exactly; great for map screenshots | Headless Chromium per job (~300 MB RAM) |
| **react‑pdf** (`@react-pdf/renderer`) | React component model; deterministic | No map rendering — you precompute the image |
| **pdfmake** | Pure JS, declarative | Limited layout primitives |
| **WeasyPrint** (Python) | HTML + CSS → PDF, no browser | CSS subset, no JS execution |
| **wkhtmltopdf** | Mature, simple | Abandoned upstream; QT WebKit only |

**Tradeoffs for an interactive map report.**
- The map *is* a Mapbox/MapLibre canvas. To put it in a PDF you either (a) screenshot the canvas client‑side and upload PNG into a `react‑pdf` template, or (b) render the whole report HTML in Playwright server‑side and let it screenshot the canvas itself. (b) is more flexible; (a) is leaner.

**Gotchas.**
- *Tiles must finish loading* before Playwright snapshots. Use `page.waitForFunction(() => map.areTilesLoaded())`.
- *DPI* — default `page.pdf()` is 96 dpi. Crank with `scale: 2` for crisp diagrams.
- *Map attribution* — Mapbox/MapLibre/OSM all require visible attribution in any exported image. Don't strip it; you'll lose your key.

**Verdict.**
- **USE THIS:** Playwright server‑side, with a `/report/:job_id` page that's specifically print‑styled.
- **CONSIDER:** `react‑pdf` if your team is React‑pure and you'll precompute the map image.

**Links.** [Playwright PDF docs](https://playwright.dev/docs/api/class-page#page-pdf) · [react-pdf](https://react-pdf.org/).

---

## Part 6 — Cross‑Cutting

### 20. Validation / accuracy testing

**What it is.** How you justify the ±3% claim. Two parts: *which roofs do you test on* and *what do you compare against*.

**Ground‑truth sources, best→worst.**
1. **Manual tape‑measure** by a roofer on a small set of single‑family homes (n=10–15 is defensible for a 4‑day build). Highest trust.
2. **EagleView / Hover reports** purchased for the same addresses (~$25 ea). They're the industry yardstick. **Buy 20 and treat them as the reference.**
3. **County assessor "building sqft"** — *heated sqft of the structure*, NOT roof area. Useful for sanity (you should be within ~1.2× of heated sqft for a single‑story).
4. **OpenStreetMap building polygons + assumed pitch** — last resort.

**Defensible test methodology.**
- Pick a stratified sample: 5 ranch / 5 hip / 5 complex (multiple gables, dormers).
- Run your pipeline blind, log each face's area + pitch.
- Compare *total area*, *per‑face area*, *count of features* against the reference.
- Report mean absolute percentage error (MAPE) and 90th‑percentile error, not just average — the CTO will ask for the worst case.
- Note residential single‑family is your covered scope; commercial/flat roofs are explicitly out of v1.

**Gotchas.**
- *Per‑face area* errors can cancel in a *total area* sum. Always report both.
- *Definition of "roof area"* — does it include the eave overhang? You're claiming ±3% of *what*. Lock the definition in the report.
- *EagleView is not ground truth*, it's a strong reference with its own ~±3–5% error. Quote yourself "within ±3% of EagleView" rather than "within ±3% of true area."

**Verdict.**
- **USE THIS:** 15‑address EagleView‑referenced test suite + 3 tape‑measured "spike" tests. Document the sample, the comparator, and the per‑face errors in the README.

**Links.** [EagleView accuracy whitepaper history](https://www.eagleview.com/) (request from sales) · [Bonneau et al. 2023 on roof segmentation benchmarks](https://www.mdpi.com/2072-4292/15/2/356).

---

### 21. Coordinate systems / projections

**What it is.** A spatial reference system (SRS) defines how coordinates map to the Earth.
- **EPSG:4326** — WGS84, lat/lng *in degrees*. Web standard for *positions*, useless for *areas*.
- **EPSG:3857** — Web Mercator, used by web map tiles, *distorts area away from the equator*.
- **EPSG:32610–32619** etc. — UTM zones, meters, accurate area within one zone (6° wide).
- **State Plane** — US‑specific, foot or meter, county‑scale accuracy.

**Problem it solves.** Computing area in degrees is meaningless. You must reproject to a planar CRS in meters/feet before any area calc.

**The two safe patterns.**
1. In PostGIS: cast to `geography` and use `ST_Area(geom::geography)` — returns m² on the WGS84 ellipsoid.
2. In Python/Shapely: pick the UTM zone for the parcel centroid (use `pyproj.CRS.from_user_input` with the EPSG of that zone), reproject with `pyproj.Transformer`, then `.area`.

**Gotchas / footguns.**
- *Mapbox/MapLibre returns coordinates in 4326* — don't pipe them into `shapely.Polygon(...).area`. You'll get "square degrees."
- *Web Mercator (3857) area* is wrong by ~1.5× at 45° latitude. Never use it for measurement.
- *Axis order* — some libraries are (lng, lat), others (lat, lng). GeoJSON is (lng, lat). GDAL is configurable. Always test on a known point.
- *Mixing CRSs in a single PostGIS query* without `ST_Transform` silently returns wrong intersections.

**Verdict.**
- **USE THIS:** EPSG:4326 for storage + transport (GeoJSON); on‑the‑fly cast to `geography` (PostGIS) or UTM (Python) for any area/length.

**Links.** [PostGIS Geography vs Geometry](https://postgis.net/workshops/postgis-intro/geography.html) · [pyproj transformers](https://pyproj4.github.io/pyproj/stable/api/transformer.html).

---

## Summary verdict table

| # | Topic | Verdict |
|---|---|---|
| 1 | Imagery providers | NAIP + Mapbox + Bing Bird's Eye |
| 2 | USGS 3DEP LiDAR | **Hero data source** via EPT/COPC on `s3://usgs-lidar-public` |
| 3 | Parcel + footprints | Microsoft Building Footprints + Regrid trial |
| 4 | LiDAR processing | PDAL + Open3D RANSAC |
| 5 | Image segmentation | SAM 2 + MS Footprints prior |
| 6 | Topology / vector roof | Plane intersection (from §4) + Douglas‑Peucker |
| 7 | Pitch | LiDAR normals, mobile photogrammetry, human dropdown — in that order |
| 8 | Open‑vocab detection | Grounding DINO / OWLv2 + SAM 2 |
| 9 | VLM verification | Gemini 2.x Flash with JSON bbox |
| 10 | Fine‑tuned YOLO | Skip for v1 |
| 11 | iOS capture | ARKit guided photos; Object Capture for low‑rise |
| 12 | Android | Pose+photos only |
| 13 | RN / Expo | Only if you already know it |
| 14 | Mobile photogrammetry | Apple Object Capture; RealityCapture server |
| 15 | Async orchestration | Celery (Python) or Trigger.dev (TS) |
| 16 | GPU hosting | Modal |
| 17 | Geo DB | Postgres + PostGIS, `geography` type |
| 18 | Map UI | MapLibre + terra‑draw + deck.gl |
| 19 | PDF | Playwright `page.pdf()` |
| 20 | Validation | 15 EagleView‑referenced addresses + 3 tape spikes |
| 21 | CRS | Store 4326, compute in geography / UTM |

---

## Addendum: technologies locked by the ADRs

The decisions in [docs/adrs/](./adrs/) commit to a few additional tools
the original research didn't cover in depth. Brief novice-friendly
notes here so the user can defend them.

### Kamal (ADR-011)

**What it is.** The Rails 8 official deployment companion. Reads a YAML
config (`config/deploy.yml`) describing your app + accessory services
+ host(s); builds Docker images; pushes them to a registry; SSHes into
the hosts; performs zero-downtime container rolls; manages secrets,
healthchecks, and a bundled Traefik reverse proxy for TLS.

**Problem it solves.** Lets a one-person team deploy a multi-container
Rails app to one or more plain Linux VMs as easily as `git push` to
Heroku, without the PaaS lock-in or the Kubernetes complexity. The
DHH-aligned "boring, transparent infra" answer.

**Alternatives.** Docker Compose (no rolling deploy, no remote orchestration); Kubernetes / DOKS (real orchestration, massive overhead for a single droplet); Render/Fly/Railway PaaS (hides the infra, less of a story).

**Gotchas.** Wants to own port 80/443 on the host via its bundled
Traefik; conflicts with a host-level Caddy unless you configure Kamal
to use a non-standard port. SSH access required to the target host.
Docker registry credentials live in the deploy config (use `.kamal/secrets`).

**Source.** [Kamal docs](https://kamal-deploy.org/)

### DigitalOcean Spaces (ADR-010)

**What it is.** DO's S3-compatible object storage service. Same API as
AWS S3 (the AWS SDK works against it unchanged once you set
`endpoint_url`). Bundled storage + egress pricing in one predictable
line item.

**Problem it solves.** Cloud-native blob storage co-located with the
DO droplet (free intra-region transfer), one provider, one bill.
Replaces S3 when you're already on DO.

**Alternatives.** AWS S3 (cross-cloud egress + separate IAM), Cloudflare R2 (zero egress, separate vendor), MinIO on-droplet (loses offsite-backup property).

**Gotchas.** Less battle-tested at huge scale than S3; some advanced
S3 features (Object Lambda, certain lifecycle rules) absent; bucket
public-read policy must be set explicitly per bucket.

**Source.** [DO Spaces docs](https://docs.digitalocean.com/products/spaces/)

### Grover + Puppeteer (ADR-014)

**What it is.** A Ruby gem (`grover`) wrapping Puppeteer (headless
Chrome) to convert HTML to PDF. The current Rails-community-recommended
HTML-to-PDF tool; replaces the older Wicked PDF (which wraps the
abandoned wkhtmltopdf).

**Problem it solves.** Lets you write a PDF as a Rails ERB view with
print CSS and have Puppeteer render it faithfully, including modern
CSS (flexbox, grid, web fonts, SVG).

**Alternatives.** WeasyPrint (Python, simpler, less faithful to modern CSS); Prawn (pure-Ruby DSL, no HTML); Playwright via Python sidecar (more setup, more service complexity).

**Gotchas.** Bundles a copy of Chromium (~250 MB in the Docker image).
Image generation is reasonably fast (~1–3 seconds) but is a network-
dependent render if your HTML loads external resources.

**Source.** [grover gem on GitHub](https://github.com/Studiosity/grover)

### RubyLLM (ADR-006, ADR-008)

**What it is.** A Ruby gem providing a unified API for calling
OpenAI / Anthropic / Gemini / Bedrock / Ollama LLMs from Rails, with
streaming, function/tool calling, and structured-output support.
CompanyCam's own briefs explicitly encourage it as the preferred LLM
client.

**Problem it solves.** Gives a Rails app first-class LLM access without
having to manage four different SDKs or call out to a Python service
for every LLM interaction.

**Alternatives.** Per-provider Ruby gems (`ruby-openai`, `anthropic`, `gemini-ai-ruby`); LangChain.rb (heavier abstraction, less common in Rails community); Python service tier for LLM calls (loses the in-Rails ergonomics CompanyCam wants).

**Gotchas.** Newer gem; API surface still evolving. Pin to a known-good
version. Schema/structured-output support varies by provider — test
each provider's path.

**Source.** [RubyLLM on GitHub](https://github.com/crmne/ruby_llm)

### ICP (Iterative Closest Point) — ADR-007

**What it is.** Classical algorithm for **rigid alignment of two point
clouds**: given two clouds that should represent the same surface,
ICP iteratively rotates and translates one to minimize point-to-point
(or point-to-plane) distance to the other.

**Problem it solves.** Aligning the ARKit world-anchored mesh from
the iOS capture (session-local coordinate frame) to the public-LiDAR
point cloud (global coordinate frame, EPSG-based). Once aligned, the
two can be fused into one point cloud and re-fit.

**Alternatives.** Manual marker placement (impractical); GPS-only
alignment (too coarse — GPS is ~5m, ICP gets to cm-level).

**Gotchas.** Local minima — needs a good initial alignment (we use
GPS + IMU as the coarse seed). Sensitive to outliers; use RANSAC-ICP
variants for robustness. Convergence not guaranteed if the two clouds
share little overlap.

**Source.** Available in Open3D (`open3d.pipelines.registration.registration_icp`) and PDAL (`filters.icp`).

### Nominatim (ADR-004)

**What it is.** OpenStreetMap-backed geocoder. Converts an address
string to lat/lng (forward geocoding) and back (reverse).

**Problem it solves.** The first hop in the address → measurement
pipeline. Free, open-data, no API key needed for low-volume use.

**Alternatives.** AWS Location Service (managed, paid above free tier); Google Geocoding API (commercial, fastest); Mapbox Geocoding (commercial, included in Mapbox plans).

**Gotchas.** 1 RPS polite-use limit on the public instance; high-volume use requires self-hosting (~20 GB OSM extract + a Docker container). US suburban address quality is generally good; rural/PO-box addresses are weaker.

**Source.** [Nominatim docs](https://nominatim.org/release-docs/latest/)

---

## The one‑paragraph defense

> *We hit ±3% by leaning on the only physical measurement source available at no cost: USGS 3DEP LiDAR (QL2 or better, streamed from the AWS Open Data EPT/COPC bucket via PDAL). We extract planar roof faces with RANSAC, derive ridges/hips/valleys as plane‑intersection lines, and pitch‑correct area per face. Where LiDAR is missing or stale, the contractor's iPhone guided‑capture loop (ARKit pose + optional Object Capture mesh) supplies the metric backup; sun‑shadow estimation gives a sanity bound. Rooftop features (vents/chimneys/dormers/skylights/sat dishes) are detected by Grounding DINO + SAM 2 on a Mapbox/NAIP tile, then verified by Gemini 2.x Flash in JSON mode, then geometrically gated by the roof mask. Parcels and footprints come from Microsoft Building Footprints + Regrid. The report renders in Playwright from a print‑styled web page. Jobs queue on Celery + Modal GPU workers, store in Postgres/PostGIS with the `geography` type so areas are always m² on the WGS84 ellipsoid. Validated on 15 EagleView‑referenced and 3 tape‑measured single‑family homes, residential‑only scope for v1.*
