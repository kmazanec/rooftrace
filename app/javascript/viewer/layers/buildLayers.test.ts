import { buildFacetLayer, buildLidarPointLayer, HoverHandlers } from "./buildLayers";
import { feetToMeters } from "../utils/elevation";
import type { ViewerPayload, ViewerFacet } from "../types";

// The @deck.gl/layers stubs (see __mocks__/deckgl-layers.js) record constructor
// props on `.props`, so these assertions check layer configuration without a GPU.

const facet: ViewerFacet = {
  facet_id: "F1",
  vertices: [
    [-89.6503, 39.7989],
    [-89.6501, 39.7989],
    [-89.6501, 39.799],
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
  it("renders flat (no extrusion) by default", () => {
    const layer = buildFacetLayer(payload, handlers, null) as unknown as {
      props: { extruded: boolean; getElevation: unknown };
    };
    expect(layer.props.extruded).toBe(false);
    expect(layer.props.getElevation).toBe(0);
  });

  it("extrudes facets by pitch in 3D mode", () => {
    const layer = buildFacetLayer(payload, handlers, null, true) as unknown as {
      props: { extruded: boolean; getElevation: (f: ViewerFacet) => number };
    };
    expect(layer.props.extruded).toBe(true);
    expect(typeof layer.props.getElevation).toBe("function");
    expect(layer.props.getElevation(facet)).toBeGreaterThan(0);
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

  it("renders points at true elevation (meters) in 3D mode", () => {
    const layer = buildLidarPointLayer(points, true) as unknown as {
      props: { getPosition: (p: [number, number, number]) => number[] };
    };
    expect(layer.props.getPosition(points[0])).toEqual([-89.6502, 39.799, feetToMeters(12.5)]);
  });
});
