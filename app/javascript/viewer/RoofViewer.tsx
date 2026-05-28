import React, { useMemo, useState, useCallback, useEffect } from "react";
import DeckGL from "@deck.gl/react";
import { Map } from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import {
  buildFacetLayer,
  buildFeaturePins,
  buildFeatureLayer,
  buildFeatureLabelLayer,
  HoverHandlers,
  FeaturePin,
} from "./layers/buildLayers";
import { basemapStyle, hasBasemap } from "./utils/basemap";
import { boundsCenter } from "./utils/geometry";
import { confidenceLabel } from "./utils/confidenceLabel";
import { sourceLabel } from "./utils/sourceLabel";
import type { ViewerPayload, ViewerFacet } from "./types";

// Rendering mode: DeckGL renders on its own canvas above a separate maplibre-gl
// basemap canvas (overlaid / two-canvas mode), rather than the interleaved
// @deck.gl/mapbox MapboxOverlay path. This keeps the dependency surface to
// @deck.gl/core+layers+react + maplibre-gl (no @deck.gl/mapbox runtime), staying
// inside the bundle budget, and gives the React island a simpler WebGL-context
// lifecycle to clean up. See ADR-013 (overlaid-mode amendment) for the rationale.

interface Props {
  payload: ViewerPayload;
  mapboxToken: string | null;
  isPublic: boolean;
}

interface TooltipState {
  x: number;
  y: number;
  html: React.ReactNode;
}

const INITIAL_ZOOM = 19;

export default function RoofViewer({ payload, mapboxToken }: Props) {
  const [tooltip, setTooltip] = useState<TooltipState | null>(null);
  const mapRef = React.useRef<Map | null>(null);
  const containerRef = React.useRef<HTMLDivElement | null>(null);

  const center = useMemo(() => boundsCenter(payload.bounds) ?? [0, 0], [payload.bounds]);

  const initialViewState = useMemo(
    () => ({
      longitude: center[0],
      latitude: center[1],
      zoom: INITIAL_ZOOM,
      pitch: 0,
      bearing: 0,
    }),
    [center]
  );

  const handlers: HoverHandlers = useMemo(
    () => ({
      onFacetHover: (info) => {
        if (info.object) {
          const f = info.object;
          setTooltip({
            x: info.x,
            y: info.y,
            html: facetTooltip(f),
          });
        } else {
          setTooltip(null);
        }
      },
      onFacetClick: () => {
        /* selection is map-only in v1; side panel is static ERB */
      },
      onFeatureHover: (info) => {
        if (info.object) {
          const feat = (info.object as FeaturePin).feature;
          setTooltip({
            x: info.x,
            y: info.y,
            html: (
              <span>
                <strong>{feat.label}</strong> · {confidenceLabel(feat.confidence)} confidence ·{" "}
                {feat.verified ? "verified" : "unverified"}
              </span>
            ),
          });
        } else {
          setTooltip(null);
        }
      },
    }),
    []
  );

  const layers = useMemo(() => {
    const pins = buildFeaturePins(payload);
    return [
      buildFacetLayer(payload, handlers),
      buildFeatureLayer(pins, handlers),
      buildFeatureLabelLayer(pins),
    ];
  }, [payload, handlers]);

  // Mount the MapLibre basemap behind the DeckGL canvas. React calls a callback
  // ref with `null` when the node unmounts; we MUST destroy the Map there (and
  // again via the effect cleanup below) or each Turbo navigation leaks a WebGL
  // context. Browsers cap WebGL contexts (~16/page), so a leak silently breaks
  // the map after a handful of report-page visits in one Turbo session.
  const mapContainerCb = useCallback(
    (node: HTMLDivElement | null) => {
      if (node && !mapRef.current) {
        const map = new Map({
          container: node,
          style: basemapStyle(mapboxToken),
          center: center as [number, number],
          zoom: INITIAL_ZOOM,
          interactive: false, // DeckGL drives the camera.
          attributionControl: false,
        });
        mapRef.current = map;
      } else if (!node && mapRef.current) {
        mapRef.current.remove();
        mapRef.current = null;
      }
    },
    [mapboxToken, center]
  );

  // Belt-and-suspenders: release the MapLibre instance (and its WebGL context)
  // when React unmounts the island (Turbo navigation, ErrorBoundary fallback).
  useEffect(
    () => () => {
      mapRef.current?.remove();
      mapRef.current = null;
    },
    []
  );

  return (
    <div
      ref={containerRef}
      style={{ position: "relative", width: "100%", height: "100%" }}
      data-testid="roof-viewer-root"
    >
      <div ref={mapContainerCb} style={{ position: "absolute", inset: 0 }} />
      <DeckGL
        initialViewState={initialViewState}
        controller={true}
        layers={layers}
        style={{ position: "absolute", top: "0", left: "0", right: "0", bottom: "0" }}
        onViewStateChange={({ viewState }) => {
          const m = mapRef.current;
          const vs = viewState as {
            longitude: number;
            latitude: number;
            zoom: number;
            bearing?: number;
            pitch?: number;
          };
          if (m) {
            m.jumpTo({
              center: [vs.longitude, vs.latitude],
              zoom: vs.zoom,
              bearing: vs.bearing ?? 0,
              pitch: vs.pitch ?? 0,
            });
          }
        }}
      />
      {!hasBasemap(mapboxToken) && (
        <div
          style={{
            position: "absolute",
            top: 8,
            left: 8,
            background: "rgba(28,28,30,0.85)",
            color: "#fff",
            fontSize: 11,
            padding: "4px 8px",
            borderRadius: 4,
          }}
          data-testid="basemap-notice"
        >
          Satellite basemap unavailable
        </div>
      )}
      <LidarToggle />
      {tooltip && (
        <div
          style={{
            position: "absolute",
            left: tooltip.x + 8,
            top: tooltip.y + 8,
            background: "rgba(28,28,30,0.92)",
            color: "#fff",
            fontSize: 12,
            padding: "6px 8px",
            borderRadius: 4,
            pointerEvents: "none",
            maxWidth: 240,
            zIndex: 10,
          }}
          data-testid="map-tooltip"
        >
          {tooltip.html}
        </div>
      )}
    </div>
  );
}

function facetTooltip(f: ViewerFacet): React.ReactNode {
  return (
    <span>
      <strong>{f.facet_id}</strong>
      <br />
      {Math.round(f.area_sq_ft)} sq ft · {f.pitch_ratio}:12 pitch
      <br />
      {sourceLabel(f.source)} · {confidenceLabel(f.confidence)} confidence
    </span>
  );
}

// LiDAR point-cloud overlay ships DISABLED for v1: the Measurement row exposes
// only a Spaces cache key for the point array (not a browser-fetchable signed
// URL), and minting one is out of scope here. Render a labeled, disabled
// affordance with an explanatory tooltip — never a bare dead control.
function LidarToggle() {
  return (
    <label
      title="Point overlay coming soon — requires a browser-fetchable point reference"
      style={{
        position: "absolute",
        bottom: 8,
        left: 8,
        background: "rgba(255,255,255,0.92)",
        color: "#9CA3AF",
        fontSize: 12,
        padding: "6px 8px",
        borderRadius: 4,
        display: "flex",
        alignItems: "center",
        gap: 6,
        cursor: "not-allowed",
      }}
      data-testid="lidar-toggle"
    >
      <input type="checkbox" disabled aria-disabled="true" />
      Show LiDAR points (coming soon)
    </label>
  );
}
