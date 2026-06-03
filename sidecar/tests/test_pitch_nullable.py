from contracts.pipeline import (
    Facet, MeasurementGeometry, GeometrySource, PIPELINE_SCHEMA_VERSION,
)


def test_facet_allows_null_pitch():
    f = Facet(
        facet_id="f1",
        vertices=[[0.0, 0.0], [0.0, 1.0], [1.0, 1.0]],
        pitch_ratio=None,
        pitch_degrees=None,
        area_sq_ft=100.0,
        source=GeometrySource.IMAGERY,
        confidence=0.5,
    )
    assert f.pitch_ratio is None and f.pitch_degrees is None


def test_geometry_allows_null_primary_pitch():
    g = MeasurementGeometry(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        facets=[],
        total_area_sq_ft=100.0,
        primary_pitch_ratio=None,
        primary_pitch_degrees=None,
        source=GeometrySource.IMAGERY,
        confidence=0.5,
    )
    assert g.primary_pitch_ratio is None
    assert g.primary_pitch_degrees is None
