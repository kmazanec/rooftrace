import React from "react";
import { jest } from "@jest/globals";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
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
  attributions: ["Mapbox"],
  on_site_visualizations: [],
};

describe("RoofViewer", () => {
  it("renders the deck.gl canvas and the viewer root", () => {
    render(<RoofViewer payload={payload} mapboxToken="pk.test" isPublic={false} />);
    expect(screen.getByTestId("roof-viewer-root")).toBeInTheDocument();
    expect(screen.getByTestId("deckgl-canvas")).toBeInTheDocument();
  });

  it("enables the LiDAR toggle when a points URL is available", () => {
    render(
      <RoofViewer
        payload={payload}
        mapboxToken="pk.test"
        isPublic={false}
        lidarPointsUrl="/jobs/1/report/lidar_points"
      />
    );
    const toggle = screen.getByTestId("lidar-toggle");
    expect(toggle).toHaveTextContent(/show lidar points/i);
    expect(toggle.querySelector("input")).not.toBeDisabled();
  });

  it("disables the LiDAR toggle with an honest label when no LiDAR is available", () => {
    render(<RoofViewer payload={payload} mapboxToken="pk.test" isPublic={false} lidarPointsUrl={null} />);
    const toggle = screen.getByTestId("lidar-toggle");
    expect(toggle).toHaveTextContent(/not available/i);
    expect(toggle.querySelector("input")).toBeDisabled();
  });

  it("lazily fetches LiDAR points when the toggle is switched on", async () => {
    const fetchMock = jest.fn(async () => ({
      ok: true,
      json: async () => ({
        points: [
          [-89.6502, 39.799, 12.5],
          [-89.6501, 39.7991, 13.0],
        ],
        point_count: 2,
        returned_count: 2,
        bounds: [-89.6502, 39.799, -89.6501, 39.7991],
      }),
    }));
    (global as unknown as { fetch: typeof fetch }).fetch = fetchMock as unknown as typeof fetch;

    render(
      <RoofViewer
        payload={payload}
        mapboxToken="pk.test"
        isPublic={false}
        lidarPointsUrl="/jobs/1/report/lidar_points"
      />
    );
    // No fetch until the user opts in.
    expect(fetchMock).not.toHaveBeenCalled();
    fireEvent.click(screen.getByTestId("lidar-toggle").querySelector("input")!);
    await waitFor(() =>
      expect(fetchMock).toHaveBeenCalledWith(
        "/jobs/1/report/lidar_points",
        expect.objectContaining({ headers: expect.any(Object) })
      )
    );
  });

  it("shows a basemap-unavailable notice when the Mapbox token is blank", () => {
    render(<RoofViewer payload={payload} mapboxToken="" isPublic />);
    expect(screen.getByTestId("basemap-notice")).toBeInTheDocument();
  });

  it("hides the basemap notice when a token is present", () => {
    render(<RoofViewer payload={payload} mapboxToken="pk.test" isPublic />);
    expect(screen.queryByTestId("basemap-notice")).not.toBeInTheDocument();
  });

  it("omits the On-Site Visualization gallery when there are none", () => {
    render(<RoofViewer payload={payload} mapboxToken="pk.test" isPublic={false} />);
    expect(screen.queryByTestId("on-site-gallery")).not.toBeInTheDocument();
  });

  it("renders the On-Site Visualization gallery when visualizations are present", () => {
    const withViz: ViewerPayload = {
      ...payload,
      on_site_visualizations: [
        {
          composite_url: "https://signed/composite.png",
          overlay_svg_url: "https://signed/overlay.svg",
          pose_confidence: 0.9,
          low_pose_confidence: false,
          caption: "Front facade",
        },
      ],
    };
    render(<RoofViewer payload={withViz} mapboxToken="pk.test" isPublic={false} />);
    expect(screen.getByTestId("on-site-gallery")).toBeInTheDocument();
    expect(screen.getByTestId("on-site-composite")).toBeInTheDocument();
  });

  it("offers a 3D-view toggle that flips between 3D and 2D", () => {
    render(<RoofViewer payload={payload} mapboxToken="pk.test" isPublic={false} />);
    const toggle = screen.getByTestId("threed-toggle");
    expect(toggle).toHaveTextContent(/3d view/i);
    fireEvent.click(toggle);
    expect(toggle).toHaveTextContent(/2d view/i);
    fireEvent.click(toggle);
    expect(toggle).toHaveTextContent(/3d view/i);
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
