import React from "react";
import { render, screen, fireEvent } from "@testing-library/react";
import OnSiteGallery from "./OnSiteGallery";
import type { OnSiteVisualization } from "./types";

function viz(overrides: Partial<OnSiteVisualization> = {}): OnSiteVisualization {
  return {
    composite_url: "https://signed/composite.png",
    overlay_svg_url: "https://signed/overlay.svg",
    pose_confidence: 0.9,
    low_pose_confidence: false,
    caption: null,
    ...overrides,
  };
}

describe("OnSiteGallery", () => {
  it("renders nothing when there are no visualizations", () => {
    const { container } = render(
      <OnSiteGallery visualizations={[]} />
    );
    expect(container.firstChild).toBeNull();
  });

  it("shows the active composite image", () => {
    render(<OnSiteGallery visualizations={[viz()]} />);
    const img = screen.getByTestId("on-site-composite") as HTMLImageElement;
    expect(img.src).toContain("composite.png");
  });

  it("renders one thumb per usable visualization and switches the stage on click", () => {
    render(
      <OnSiteGallery
        visualizations={[
          viz({ composite_url: "https://signed/a.png" }),
          viz({ composite_url: "https://signed/b.png" }),
        ]}
      />
    );
    expect(screen.getByTestId("on-site-thumb-0")).toBeInTheDocument();
    expect(screen.getByTestId("on-site-thumb-1")).toBeInTheDocument();

    fireEvent.click(screen.getByTestId("on-site-thumb-1"));
    const img = screen.getByTestId("on-site-composite") as HTMLImageElement;
    expect(img.src).toContain("b.png");
  });

  it("shows a low-pose-confidence warning instead of a broken overlay", () => {
    render(
      <OnSiteGallery
        visualizations={[viz({ composite_url: null, low_pose_confidence: true })]}
      />
    );
    expect(screen.getByTestId("low-pose-warning")).toBeInTheDocument();
    expect(screen.queryByTestId("on-site-composite")).not.toBeInTheDocument();
  });

  it("notifies the parent on selection (cross-highlight)", () => {
    const calls: number[] = [];
    const onSelect = (i: number) => calls.push(i);
    render(
      <OnSiteGallery
        visualizations={[viz(), viz({ composite_url: "https://signed/b.png" })]}
        onSelect={onSelect}
      />
    );
    fireEvent.click(screen.getByTestId("on-site-thumb-1"));
    expect(calls).toContain(1);
  });
});
