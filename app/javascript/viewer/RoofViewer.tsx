import React, { useMemo, useState, useCallback, useEffect } from "react";
import DeckGL from "@deck.gl/react";
import { Map } from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import {
  buildFacetLayer,
  buildFeaturePins,
  buildFeatureLayer,
  buildFeatureLabelLayer,
  buildLidarPointLayer,
  HoverHandlers,
  FeaturePin,
} from "./layers/buildLayers";
import type { LidarPointsResponse } from "./types";
import { basemapStyle, hasBasemap } from "./utils/basemap";
import { boundsCenter } from "./utils/geometry";
import { groundBaselineMeters } from "./utils/elevation";
import { confidenceLabel } from "./utils/confidenceLabel";
import { sourceLabel } from "./utils/sourceLabel";
import OnSiteGallery from "./OnSiteGallery";
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
  // Endpoint that returns the LiDAR point-cloud overlay ([lon,lat,elev_ft]),
  // or null when this measurement has no usable LiDAR (toggle stays disabled).
  lidarPointsUrl?: string | null;
}

interface TooltipState {
  x: number;
  y: number;
  html: React.ReactNode;
}

const INITIAL_ZOOM = 19;
// Camera tilt for the 3D view. Stays under MapController's default maxPitch (60)
// so deck.gl accepts it, while giving a clear oblique read of the extruded roof.
const THREE_D_PITCH = 50;

interface ViewState {
  longitude: number;
  latitude: number;
  zoom: number;
  pitch: number;
  bearing: number;
}

export default function RoofViewer({ payload, mapboxToken, lidarPointsUrl }: Props) {
  const [tooltip, setTooltip] = useState<TooltipState | null>(null);
  // Facet<->gallery cross-highlight (ADR-019): a facet selected on the map and
  // the active on-site composite are shared state. Selecting a facet activates
  // the gallery; selecting a gallery item records which on-site photo is shown.
  const [selectedFacetId, setSelectedFacetId] = useState<string | null>(null);
  // Cross-highlight with the side-panel facet table (ADR-013): hover state is
  // shared with the server-rendered table via window "roof:facet-hover" events.
  const [highlightedFacetId, setHighlightedFacetId] = useState<string | null>(null);
  const [activeViz, setActiveViz] = useState<number | null>(null);
  // 3D view (ADR-013, per-facet elevation by pitch): off by default (top-down).
  // When on, the camera tilts, facets extrude by pitch, and the LiDAR overlay
  // lifts to true elevation — so the user can view the roof in all dimensions.
  const [is3D, setIs3D] = useState(false);
  // LiDAR point-cloud overlay (ADR-013): off by default; lazily fetched the first
  // time it's switched on (a roof crop is large — don't pay for it unviewed).
  const [lidarOn, setLidarOn] = useState(false);
  const [lidarPoints, setLidarPoints] = useState<[number, number, number][] | null>(null);
  const [lidarState, setLidarState] = useState<"idle" | "loading" | "loaded" | "error" | "empty">(
    "idle"
  );
  const mapRef = React.useRef<Map | null>(null);
  const containerRef = React.useRef<HTMLDivElement | null>(null);

  const hasVisualizations = (payload.on_site_visualizations ?? []).length > 0;

  const center = useMemo(() => boundsCenter(payload.bounds) ?? [0, 0], [payload.bounds]);

  // Controlled camera so the 3D toggle can tilt it programmatically and the
  // MapLibre basemap can be kept in lockstep (see the sync effect below).
  const [viewState, setViewState] = useState<ViewState>(() => ({
    longitude: center[0],
    latitude: center[1],
    zoom: INITIAL_ZOOM,
    pitch: 0,
    bearing: 0,
  }));

  // Re-center if the payload (and thus its bounds) changes under us.
  useEffect(() => {
    setViewState((vs) => ({ ...vs, longitude: center[0], latitude: center[1] }));
  }, [center]);

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
          setHighlightedFacetId(f.facet_id); // thicken this facet's own stroke
          emitFacetHover(f.facet_id); // and highlight its row in the table
        } else {
          setTooltip(null);
          setHighlightedFacetId(null);
          emitFacetHover(null);
        }
      },
      onFacetClick: (info) => {
        // Cross-highlight: selecting a facet on the map activates the on-site
        // gallery (a contractor inspecting a facet wants the photos of it).
        const f = info.object;
        setSelectedFacetId(f ? f.facet_id : null);
        if (f && hasVisualizations) setActiveViz((prev) => prev ?? 0);
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
    [hasVisualizations]
  );

  // Shared ground datum for the 3D view (metres): the lowest elevation across the
  // facet vertices AND the loaded LiDAR points. The facets bottom out at the eave;
  // the LiDAR cloud reaches the true ground below it, so once points load the
  // datum drops to the ground — the roof then floats at its real height and no
  // returns sink below the basemap. Both layers subtract this SAME datum, so they
  // stay aligned. Null when there's nothing to anchor to.
  const elevationBaseline = useMemo(
    () => groundBaselineMeters(payload.facets, lidarPoints),
    [payload.facets, lidarPoints]
  );

  const layers = useMemo(() => {
    const pins = buildFeaturePins(payload);
    return [
      // LiDAR points UNDER the facets so the measured polygons stay readable.
      lidarOn && lidarPoints ? buildLidarPointLayer(lidarPoints, is3D, elevationBaseline) : null,
      buildFacetLayer(payload, handlers, highlightedFacetId, is3D, elevationBaseline ?? 0),
      buildFeatureLayer(pins, handlers),
      buildFeatureLabelLayer(pins),
    ].filter(Boolean);
  }, [payload, handlers, highlightedFacetId, lidarOn, lidarPoints, is3D, elevationBaseline]);

  // Tilt into (or out of) the oblique 3D camera. The basemap follows via the
  // viewState sync effect below.
  const toggle3D = useCallback(() => {
    setIs3D((prev) => {
      const next = !prev;
      setViewState((vs) => ({ ...vs, pitch: next ? THREE_D_PITCH : 0, bearing: next ? vs.bearing : 0 }));
      return next;
    });
  }, []);

  // Toggle the overlay; fetch the points on first activation, then cache them.
  const toggleLidar = useCallback(() => {
    if (lidarOn) {
      setLidarOn(false);
      return;
    }
    setLidarOn(true);
    if (lidarPoints || !lidarPointsUrl || lidarState === "loading") return;

    setLidarState("loading");
    fetch(lidarPointsUrl, { headers: { Accept: "application/json" } })
      .then((r) => {
        if (!r.ok) throw new Error(`lidar-points ${r.status}`);
        return r.json() as Promise<LidarPointsResponse>;
      })
      .then((data) => {
        const pts = (data.points ?? []) as [number, number, number][];
        if (pts.length === 0) {
          setLidarState("empty");
          setLidarPoints([]);
        } else {
          setLidarPoints(pts);
          setLidarState("loaded");
        }
      })
      .catch((e) => {
        console.error("[viewer] lidar points fetch failed", e);
        setLidarState("error");
      });
  }, [lidarOn, lidarPoints, lidarPointsUrl, lidarState]);

  // Listen for facet-hover events from the side-panel table (and ignore our own
  // map-origin echoes) so hovering a table row highlights the map polygon.
  useEffect(() => {
    const onHover = (event: Event) => {
      const detail = (event as CustomEvent<{ facetId: string | null; origin?: string }>).detail;
      if (detail?.origin === "map") return;
      setHighlightedFacetId(detail?.facetId ?? null);
    };
    window.addEventListener("roof:facet-hover", onHover);
    return () => window.removeEventListener("roof:facet-hover", onHover);
  }, []);

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

  // Keep the MapLibre basemap locked to the deck.gl camera — including pitch and
  // bearing — so the satellite imagery tilts with the 3D roof. This is the single
  // sync point for both user interaction (onViewStateChange) and the programmatic
  // 3D toggle, which both flow through `viewState`.
  useEffect(() => {
    mapRef.current?.jumpTo({
      center: [viewState.longitude, viewState.latitude],
      zoom: viewState.zoom,
      bearing: viewState.bearing,
      pitch: viewState.pitch,
    });
  }, [viewState]);

  return (
    <div
      ref={containerRef}
      style={{ position: "relative", width: "100%", height: "100%" }}
      data-testid="roof-viewer-root"
    >
      <div ref={mapContainerCb} style={{ position: "absolute", inset: 0 }} />
      <DeckGL
        viewState={viewState}
        controller={{ dragRotate: true, touchRotate: true }}
        layers={layers}
        style={{ position: "absolute", top: "0", left: "0", right: "0", bottom: "0" }}
        onViewStateChange={({ viewState: vs }) => {
          const v = vs as Partial<ViewState>;
          setViewState((prev) => ({
            longitude: v.longitude ?? prev.longitude,
            latitude: v.latitude ?? prev.latitude,
            zoom: v.zoom ?? prev.zoom,
            pitch: v.pitch ?? prev.pitch,
            bearing: v.bearing ?? prev.bearing,
          }));
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
      <button
        type="button"
        onClick={toggle3D}
        aria-pressed={is3D}
        title={
          is3D
            ? "Return to the top-down plan view"
            : "Tilt into a 3D view of the roof — drag to orbit"
        }
        style={{
          position: "absolute",
          bottom: 40,
          left: 8,
          background: is3D ? "rgba(28,28,30,0.92)" : "rgba(255,255,255,0.92)",
          color: is3D ? "#fff" : "#1C1C1E",
          fontSize: 12,
          padding: "6px 10px",
          border: "none",
          borderRadius: 4,
          cursor: "pointer",
          zIndex: 11,
        }}
        data-testid="threed-toggle"
      >
        {is3D ? "2D view" : "3D view"}
      </button>
      <LidarToggle
        available={!!lidarPointsUrl}
        on={lidarOn}
        state={lidarState}
        onToggle={toggleLidar}
      />
      {selectedFacetId && hasVisualizations && (
        <div
          data-testid="selected-facet-badge"
          style={{
            position: "absolute",
            top: 8,
            right: 8,
            background: "rgba(28,28,30,0.85)",
            color: "#fff",
            fontSize: 11,
            padding: "4px 8px",
            borderRadius: 4,
            zIndex: 11,
          }}
        >
          Facet {selectedFacetId} · see on-site photos below
        </div>
      )}
      {hasVisualizations && (
        <div
          style={{
            position: "absolute",
            bottom: 0,
            left: 0,
            right: 0,
            maxHeight: "45%",
            overflow: "auto",
            background: "rgba(255,255,255,0.96)",
            zIndex: 9,
          }}
        >
          <OnSiteGallery
            visualizations={payload.on_site_visualizations}
            onSelect={setActiveViz}
          />
        </div>
      )}
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

// Broadcast a map-origin facet hover to the side-panel table bridge. Tagged
// origin:"map" so the table can highlight while the map's own subscribe effect
// ignores the echo.
function emitFacetHover(facetId: string | null) {
  window.dispatchEvent(
    new CustomEvent("roof:facet-hover", { detail: { facetId, origin: "map" } })
  );
}

function facetTooltip(f: ViewerFacet): React.ReactNode {
  return (
    <span>
      <strong>{f.facet_id}</strong>
      <br />
      {Math.round(f.area_sq_ft)} sq ft · {f.pitch_ratio == null ? "pitch unknown" : `${f.pitch_ratio}:12 pitch`}
      <br />
      {sourceLabel(f.source)} · {confidenceLabel(f.confidence)} confidence
    </span>
  );
}

// LiDAR point-cloud overlay control. The facets are fit from real 3DEP LiDAR;
// this toggles the underlying points on the map (fetched lazily — see
// toggleLidar). When the measurement has no usable LiDAR (imagery-only fallback)
// the control is disabled with an honest label, never a dead "coming soon".
interface LidarToggleProps {
  available: boolean;
  on: boolean;
  state: "idle" | "loading" | "loaded" | "error" | "empty";
  onToggle: () => void;
}

function LidarToggle({ available, on, state, onToggle }: LidarToggleProps) {
  let label = "Show LiDAR points";
  if (!available) label = "LiDAR not available for this address";
  else if (state === "loading") label = "Loading LiDAR points…";
  else if (state === "error") label = "LiDAR points unavailable";
  else if (state === "empty") label = "No LiDAR points to show";

  const disabled = !available || state === "loading";

  return (
    <label
      title={
        available
          ? "Show the 3DEP LiDAR points the roof facets were measured from"
          : "This roof was measured from satellite imagery only — no LiDAR coverage"
      }
      style={{
        position: "absolute",
        bottom: 8,
        left: 8,
        background: "rgba(255,255,255,0.92)",
        color: disabled ? "#9CA3AF" : "#1C1C1E",
        fontSize: 12,
        padding: "6px 8px",
        borderRadius: 4,
        display: "flex",
        alignItems: "center",
        gap: 6,
        cursor: disabled ? "not-allowed" : "pointer",
        zIndex: 11,
      }}
      data-testid="lidar-toggle"
    >
      <input
        type="checkbox"
        checked={on}
        disabled={disabled}
        aria-disabled={disabled}
        onChange={onToggle}
      />
      {label}
    </label>
  );
}
