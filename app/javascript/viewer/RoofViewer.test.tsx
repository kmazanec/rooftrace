import React from "react";
import { render, screen } from "@testing-library/react";
import type { ViewerPayload } from "./types";

// The WebGL/map stack (@deck.gl/react, @deck.gl/layers, maplibre-gl) and CSS
// imports are stubbed via jest.config.mjs moduleNameMapper (manual mocks in
// ./__mocks__) — not via in-spec jest.mock, which ESM hoisting would let the
// real GPU/worker bootstrap defeat before the suite even loads.
import RoofViewer from "./RoofViewer";

const payload: ViewerPayload = {
  address: "123 Main St",
  generated_at: "2026-05-28T00:00:00Z",
  source: "lidar",
  confidence: 0.9,
  total_area_sq_ft: 1684,
  total_perimeter_ft: 168,
  primary_pitch_ratio: 6,
  primary_pitch_degrees: 26.57,
  bounds: [-89.6503, 39.7989, -89.6499, 39.7992],
  facets: [
    {
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
    },
  ],
  features: [
    { label: "chimney", bbox_norm: [0.4, 0.3, 0.5, 0.45], verified: true, source: "imagery", confidence: 0.8 },
  ],
  roof_outline: null,
  footprint: null,
  warnings: [],
  attributions: ["NAIP"],
};

describe("RoofViewer", () => {
  it("renders the deck.gl canvas and the viewer root", () => {
    render(<RoofViewer payload={payload} mapboxToken="pk.test" isPublic={false} />);
    expect(screen.getByTestId("roof-viewer-root")).toBeInTheDocument();
    expect(screen.getByTestId("deckgl-canvas")).toBeInTheDocument();
  });

  it("ships the LiDAR toggle DISABLED with a coming-soon affordance", () => {
    render(<RoofViewer payload={payload} mapboxToken="pk.test" isPublic={false} />);
    const toggle = screen.getByTestId("lidar-toggle");
    expect(toggle).toHaveTextContent(/coming soon/i);
    expect(toggle.querySelector("input")).toBeDisabled();
  });

  it("shows a basemap-unavailable notice when the Mapbox token is blank", () => {
    render(<RoofViewer payload={payload} mapboxToken="" isPublic />);
    expect(screen.getByTestId("basemap-notice")).toBeInTheDocument();
  });

  it("hides the basemap notice when a token is present", () => {
    render(<RoofViewer payload={payload} mapboxToken="pk.test" isPublic />);
    expect(screen.queryByTestId("basemap-notice")).not.toBeInTheDocument();
  });

  it("renders identically (same affordances) for public and private views", () => {
    const { unmount } = render(
      <RoofViewer payload={payload} mapboxToken="pk.test" isPublic={false} />
    );
    expect(screen.getByTestId("lidar-toggle")).toBeInTheDocument();
    unmount();
    render(<RoofViewer payload={payload} mapboxToken="pk.test" isPublic />);
    expect(screen.getByTestId("lidar-toggle")).toBeInTheDocument();
  });
});
