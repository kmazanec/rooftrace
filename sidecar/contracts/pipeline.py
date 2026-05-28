"""Python (Pydantic) view of the Rails<->sidecar pipeline contract.

Mirrors `shared/pipeline_schema.json` (the JSON Schema source of truth, ADR-008).
The Rails side validates via `app/services/pipeline_schema.rb`; both sides
validate the same fixture corpus in `spec/fixtures/pipeline/` so the two
language views cannot silently diverge.

Boundary convention: all coordinates WGS84 (EPSG:4326), GeoJSON [lon, lat].
Local UTM (ADR-003) is internal to the sidecar and never crosses this contract.
"""

from __future__ import annotations

from enum import Enum
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, RootModel

PIPELINE_SCHEMA_VERSION = "0.2.0"

Confidence = Annotated[float, Field(ge=0.0, le=1.0)]
# Non-empty so an empty version can't slip past the major-version check.
SchemaVersion = Annotated[str, Field(min_length=1)]


class GeometrySource(str, Enum):
    LIDAR = "lidar"
    IMAGERY = "imagery"
    FUSION = "fusion"
    CAPTURE = "capture"
    MANUAL = "manual"


class _Strict(BaseModel):
    # additionalProperties: false on every object in the JSON Schema.
    model_config = ConfigDict(extra="forbid")


class Address(_Strict):
    raw: str
    normalized: str | None = None
    lon: Annotated[float, Field(ge=-180.0, le=180.0)] | None = None
    lat: Annotated[float, Field(ge=-90.0, le=90.0)] | None = None
    source: GeometrySource | None = None
    confidence: Confidence | None = None


class JobSpec(_Strict):
    job_id: str
    address: Address
    requested_at: str | None = None


Position = Annotated[list[float], Field(min_length=2, max_length=3)]
LinearRing = Annotated[list[Position], Field(min_length=4)]


class Polygon(_Strict):
    type: Literal["Polygon"]
    coordinates: Annotated[list[LinearRing], Field(min_length=1)]
    source: GeometrySource | None = None
    confidence: Confidence | None = None


class WorkUnit(_Strict):
    name: str
    year: int | None = None
    quality_level: str | None = None
    epsg: int | None = None


class LiDARStatus(str, Enum):
    AVAILABLE = "LIDAR_AVAILABLE"
    MISSING = "LIDAR_MISSING"


class LiDARResult(_Strict):
    status: LiDARStatus
    point_array_ref: str | None = None
    point_count: Annotated[int, Field(ge=0)] | None = None
    work_unit: WorkUnit | None = None
    source: GeometrySource | None = None
    confidence: Confidence | None = None


class Facet(_Strict):
    facet_id: str
    vertices: Annotated[list[Position], Field(min_length=3)]
    pitch_ratio: Annotated[float, Field(ge=0.0)]
    pitch_degrees: Annotated[float, Field(ge=0.0, le=90.0)]
    area_sq_ft: Annotated[float, Field(ge=0.0)]
    source: GeometrySource
    confidence: Confidence


class FeatureLabel(str, Enum):
    VENT = "vent"
    CHIMNEY = "chimney"
    DORMER = "dormer"
    SKYLIGHT = "skylight"
    SATELLITE_DISH = "satellite_dish"
    OTHER = "other"


class Feature(_Strict):
    label: FeatureLabel
    bbox_norm: Annotated[list[Annotated[float, Field(ge=0.0, le=1.0)]], Field(min_length=4, max_length=4)]
    verified: bool
    source: GeometrySource
    confidence: Confidence


class Measurement(_Strict):
    job_id: str
    footprint: Polygon | None = None
    roof_outline: Polygon | None = None
    lidar: LiDARResult | None = None
    facets: list[Facet]
    features: list[Feature]
    total_area_sq_ft: Annotated[float, Field(ge=0.0)] | None = None
    predominant_pitch_ratio: Annotated[float, Field(ge=0.0)] | None = None
    source: GeometrySource
    confidence: Confidence


class PipelineRequest(_Strict):
    pipelineSchemaVersion: SchemaVersion
    job: JobSpec


class PipelineStatus(str, Enum):
    OK = "OK"
    PARTIAL = "PARTIAL"
    FAILED = "FAILED"


class PipelineResponse(_Strict):
    pipelineSchemaVersion: SchemaVersion
    job_id: str
    measurement: Measurement | None = None
    status: PipelineStatus


class RenderImageRequest(_Strict):
    pipelineSchemaVersion: SchemaVersion
    job_id: str
    bbox: Annotated[list[float], Field(min_length=4, max_length=4)]
    width_px: Annotated[int, Field(ge=1)]
    height_px: Annotated[int, Field(ge=1)]


class RenderImageResponse(_Strict):
    pipelineSchemaVersion: SchemaVersion
    job_id: str
    image_ref: str


class FuseCaptureRequest(_Strict):
    pipelineSchemaVersion: SchemaVersion
    job_id: str
    capture_mesh_ref: str
    lidar: LiDARResult | None = None


class FuseCaptureResponse(_Strict):
    pipelineSchemaVersion: SchemaVersion
    job_id: str
    measurement: Measurement | None = None
    icp_rmse_m: Annotated[float, Field(ge=0.0)] | None = None


class CameraPose(_Strict):
    intrinsics: Annotated[list[float], Field(min_length=9, max_length=9)]
    extrinsics: Annotated[list[float], Field(min_length=16, max_length=16)]


class ProjectPhotoRequest(_Strict):
    pipelineSchemaVersion: SchemaVersion
    job_id: str
    photo_ref: str
    camera_pose: CameraPose
    facets: list[Facet]


class ProjectPhotoResponse(_Strict):
    pipelineSchemaVersion: SchemaVersion
    job_id: str
    overlay_ref: str


NullablePolygon = Polygon | None


class AttributionItem(_Strict):
    name: str
    license: str | None = None
    url: str | None = None
    retrieved_at: str | None = None


class SourceAttribution(RootModel[list[AttributionItem]]):
    # JSON Schema `SourceAttribution` is an array, not an object; RootModel lets
    # the contract test validate an array payload through ENTITY_MODELS uniformly.
    root: list[AttributionItem]


class ResolveAddressRequest(_Strict):
    pipelineSchemaVersion: SchemaVersion
    address: Annotated[str, Field(min_length=1)]


class ResolveAddressResponse(_Strict):
    pipelineSchemaVersion: SchemaVersion
    geocode: Address
    parcel_polygon: NullablePolygon = None
    building_polygons: Annotated[list[Polygon], Field(min_length=1)]
    attribution: list[AttributionItem]
    warnings: list[str] = Field(default_factory=list)


class IngestLidarRequest(_Strict):
    pipelineSchemaVersion: SchemaVersion
    building_polygon: Polygon
    parcel_polygon: NullablePolygon = None


class IngestLidarResponse(_Strict):
    pipelineSchemaVersion: SchemaVersion
    lidar: LiDARResult
    utm_zone: int | None = None
    bounds_utm: Annotated[list[float], Field(min_length=4, max_length=4)] | None = None
    warnings: list[str] = Field(default_factory=list)
    attribution: list[AttributionItem] = Field(default_factory=list)


class RefineOutlineRequest(_Strict):
    pipelineSchemaVersion: SchemaVersion
    image_tile_ref: str
    prior_polygon: Polygon
    image_geo_bounds: Annotated[list[float], Field(min_length=4, max_length=4)]


class SAM2Backend(str, Enum):
    MODAL = "modal"
    LOCAL = "local"


class RefineOutlineResponse(_Strict):
    pipelineSchemaVersion: SchemaVersion
    refined_polygon: Polygon
    iou_with_prior: Annotated[float, Field(ge=0.0, le=1.0)]
    sam2_backend: SAM2Backend
    warnings: list[str] = Field(default_factory=list)


class MeasurementGeometry(_Strict):
    pipelineSchemaVersion: SchemaVersion
    facets: list[Facet]
    total_area_sq_ft: Annotated[float, Field(ge=0.0)]
    total_perimeter_ft: Annotated[float, Field(ge=0.0)] | None = None
    primary_pitch_ratio: Annotated[float, Field(ge=0.0)]
    primary_pitch_degrees: Annotated[float, Field(ge=0.0, le=90.0)]
    source: GeometrySource
    confidence: Confidence
    warnings: list[str] = Field(default_factory=list)


class FitPlanesRequest(_Strict):
    pipelineSchemaVersion: SchemaVersion
    point_array_ref: str
    utm_zone: int
    refined_polygon: Polygon


class FallbackMeasurementRequest(_Strict):
    pipelineSchemaVersion: SchemaVersion
    refined_polygon: Polygon
    inferred_pitch_degrees: Annotated[float, Field(ge=0.0, le=90.0)]
    utm_zone: int


class DetectFeaturesRequest(_Strict):
    pipelineSchemaVersion: SchemaVersion
    image_tile_ref: str
    roof_polygon: Polygon


class DetectFeaturesResponse(_Strict):
    pipelineSchemaVersion: SchemaVersion
    features: list[Feature]
    detector: str
    warnings: list[str] = Field(default_factory=list)


# Maps the JSON-Schema `$defs` entity name -> Pydantic model, so the contract
# test can look up the right model for each fixture's `entity` field.
ENTITY_MODELS: dict[str, type[BaseModel]] = {
    "Address": Address,
    "JobSpec": JobSpec,
    "Polygon": Polygon,
    "LiDARResult": LiDARResult,
    "Facet": Facet,
    "Feature": Feature,
    "Measurement": Measurement,
    "PipelineRequest": PipelineRequest,
    "PipelineResponse": PipelineResponse,
    "RenderImageRequest": RenderImageRequest,
    "RenderImageResponse": RenderImageResponse,
    "FuseCaptureRequest": FuseCaptureRequest,
    "FuseCaptureResponse": FuseCaptureResponse,
    "ProjectPhotoRequest": ProjectPhotoRequest,
    "ProjectPhotoResponse": ProjectPhotoResponse,
    "SourceAttribution": SourceAttribution,
    "ResolveAddressRequest": ResolveAddressRequest,
    "ResolveAddressResponse": ResolveAddressResponse,
    "IngestLidarRequest": IngestLidarRequest,
    "IngestLidarResponse": IngestLidarResponse,
    "RefineOutlineRequest": RefineOutlineRequest,
    "RefineOutlineResponse": RefineOutlineResponse,
    "MeasurementGeometry": MeasurementGeometry,
    "FitPlanesRequest": FitPlanesRequest,
    "FallbackMeasurementRequest": FallbackMeasurementRequest,
    "DetectFeaturesRequest": DetectFeaturesRequest,
    "DetectFeaturesResponse": DetectFeaturesResponse,
}
