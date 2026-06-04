import { buildFacetLayer, buildLidarPointLayer, HoverHandlers } from "./buildLayers";
import { feetToMeters } from "../utils/elevation";
import type { ViewerPayload, ViewerFacet } from "../types";

// The @deck.gl/layers stubs (see __mocks__/deckgl-layers.js) record constructor
// props on `.props`, so these assertions check layer configuration without a GPU.

const facet: ViewerFacet = {
  facet_id: "F1",
  vertices: [
    [-89.6503, 39.7989, 251.0], // eave (lowest)
    [-89.6501, 39.7989, 254.5], // ridge
    [-89.6501, 39.799, 251.0],
  ],
  pitch_ratio: 6,
  pitch_degrees: 26.57,
  area_sq_ft: 842,
  source: "lidar",
  confidence: 0.9,
};

const payload = {
  bounds: [-89.6503, 39.7989, -89.6499, 39.7992],
  facets: [facet],
} as unknown as ViewerPayload;

const handlers: HoverHandlers = {
  onFacetHover: () => {},
  onFacetClick: () => {},
  onFeatureHover: () => {},
};

describe("buildFacetLayer", () => {
  it("renders flat 2D polygons by default — z stripped so facets sit on the basemap", () => {
    const layer = buildFacetLayer(payload, handlers, null) as unknown as {
      props: { extruded: boolean; getPolygon: (f: ViewerFacet) => unknown };
    };
    expect(layer.props.extruded).toBe(false);
    // The vertices carry absolute elevation; top-down it must be dropped (a raw
    // z≈250m would float the facet off-screen under the pitch-0 camera).
    expect(layer.props.getPolygon(facet)).toEqual([
      [-89.6503, 39.7989],
      [-89.6501, 39.7989],
      [-89.6501, 39.799],
    ]);
  });

  it("never extrudes — 3D comes from the polygon's own per-vertex elevation", () => {
    const layer = buildFacetLayer(payload, handlers, null, true, 251.0) as unknown as {
      props: { extruded: boolean };
    };
    // A tilted plane, not a vertical-walled prism.
    expect(layer.props.extruded).toBe(false);
  });

  it("tilts facets to their real elevation above the ground baseline in 3D mode", () => {
    const baseline = 251.0;
    const layer = buildFacetLayer(payload, handlers, null, true, baseline) as unknown as {
      props: { getPolygon: (f: ViewerFacet) => [number, number, number][] };
    };
    const poly = layer.props.getPolygon(facet);
    // Each vertex keeps its lon/lat and carries z relative to the baseline, so the
    // ridge vertex sits above the eave vertices — a sloped plane.
    expect(poly).toEqual([
      [-89.6503, 39.7989, 0],
      [-89.6501, 39.7989, 3.5],
      [-89.6501, 39.799, 0],
    ]);
  });

  it("falls back to flat (z=0) for facets without a per-vertex elevation in 3D", () => {
    const flatFacet: ViewerFacet = {
      ...facet,
      vertices: [
        [-89.6503, 39.7989],
        [-89.6501, 39.7989],
        [-89.6501, 39.799],
      ],
    };
    const flatPayload = { ...payload, facets: [flatFacet] } as unknown as ViewerPayload;
    const layer = buildFacetLayer(flatPayload, handlers, null, true, 0) as unknown as {
      props: { getPolygon: (f: ViewerFacet) => [number, number, number][] };
    };
    expect(layer.props.getPolygon(flatFacet)).toEqual([
      [-89.6503, 39.7989, 0],
      [-89.6501, 39.7989, 0],
      [-89.6501, 39.799, 0],
    ]);
  });
});

describe("buildLidarPointLayer", () => {
  const points: [number, number, number][] = [
    [-89.6502, 39.799, 12.5],
    [-89.6501, 39.7991, 13.0],
  ];

  it("renders points flat (2D position) by default", () => {
    const layer = buildLidarPointLayer(points) as unknown as {
      props: { getPosition: (p: [number, number, number]) => number[] };
    };
    expect(layer.props.getPosition(points[0])).toEqual([-89.6502, 39.799]);
  });

  it("lifts points to their elevation above the lowest point (meters) in 3D mode", () => {
    const layer = buildLidarPointLayer(points, true) as unknown as {
      props: { getPosition: (p: [number, number, number]) => number[] };
    };
    // minElev is 12.5 ft, so the lowest point sits on the ground (z=0) and the
    // higher point rises by (13.0 - 12.5) ft converted to metres.
    expect(layer.props.getPosition(points[0])).toEqual([-89.6502, 39.799, feetToMeters(0)]);
    expect(layer.props.getPosition(points[1])).toEqual([-89.6501, 39.7991, feetToMeters(0.5)]);
  });
});
