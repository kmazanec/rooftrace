# Feature: iOS capture, relocated in-app (and restyled)

**ID:** F-25 · **Roadmap piece:** F-25 · **Status:** Not started

## What this delivers (before → after)

**Before:** The guided LiDAR walk-around (F-15) is the *whole* app, reached by a
token-entry screen or a `rooftrace://capture` deep link — disconnected from the
rest of the experience and visually utilitarian.

**After:** The capture flow is launched **from a job inside the app** (the
`job_id` + `capture_token` already in hand, no token re-entry), runs as one pushed
screen in the navigation graph, and is restyled onto the design system — while the
capture **payload and manifest stay byte-for-byte unchanged**.

## How it fits the roadmap

Relocates shipped F-15 code into the full-featured app. Mostly a **move +
re-seam + restyle**, low-risk despite sitting late in the chain. Depends on F-21 +
F-24. Per the [ADR-007 amendment](../adrs/ADR-007-mobile-capture-thin-ios-app.md).

## Requirements traced (from the PRD)

"In the app, let them do the extra step of adding the images and scan that we
already built." Keeps the smart-pipe capture (ADR-007) intact; changes only how
it's entered and how it looks.

## Dependencies (must exist before this starts)

- **F-21 iOS foundation + login** — the nav shell + design system the flow plugs
  into.
- **F-24 iOS live status** — the capture flow is launched from a job's status/detail
  (carrying the `capture_token`).
- **F-15 iOS capture app** — the existing `CaptureViewModel`, `CaptureSessionState`,
  ARKit/GPS services, `MultipartUploader` — all reused.

## Unblocks (what waits on this)

- **None directly** (the capture result feeds the existing server-side fusion path,
  unchanged).

## Contracts touched

- **iOS API client contract** (ADR-007 amendment) — *consumes*: the `CaptureHandoff`
  (`job_id` + `capture_token`) value the create/status flow carries; the upload
  still uses the separate `MultipartUploader` (not the JSON `APIClient`).
- **iOS native design system** (ADR-020) — *extends*: restyles the capture prompt,
  setup-check, compass, progress, and upload screens onto the `cc-*` palette
  (segmented progress, the redrawn `CompassCard`, mono step counter, the
  determinate upload bar, brand check/error treatments).
- **Capture-bundle manifest** (ADR-007, `shared/ios_session_schema.json` 1.0.0) —
  *unchanged*: the payload, part names, and manifest are identical; this feature
  must not touch the wire contract.

## Acceptance criteria (product behavior)

- The capture flow is entered from a job (e.g. status/detail "Improve with a scan")
  with the `job_id` + `capture_token` **already provided** — there is **no
  token-entry screen** in the normal flow; the credentials arrive as an immutable
  `CaptureHandoff` and the flow starts at the setup check.
- The 8-prompt walk-around, LiDAR setup check, capture, and upload behave exactly
  as before; the upload still POSTs to `POST /api/v1/capture-sessions/:job_id` with
  the **`capture_token`** bearer and the unchanged 18-part multipart bundle.
- The flow is **restyled** onto the design system (no `.tint`/stoplight/`.borderedProminent`):
  segmented 8-step progress + mono "N OF 8", the redrawn high-contrast compass, the
  determinate upload bar, a brand-orange success check, and a recoverable
  orange-tint failure with "Try again" + "Save bundle locally".
- The **credential-handoff security property still holds**: because the flow
  receives an immutable `CaptureHandoff`, there is no mutable token field to swap;
  the existing deep-link guard behavior is preserved (now structurally). A
  `rooftrace://capture` deep link still works, routed through the app router.
- On successful upload, the flow returns to the job (whose status/report reflects
  the fusion when ready).

## Testing requirements

- **Unit tests:** the relocated `CaptureSessionState` starts at the setup check
  given a `CaptureHandoff` (the `.tokenEntry` start is removed); the existing
  capture/manifest/upload-retry tests stay green (the wire contract is unchanged);
  the deep-link guard test is updated to the `CaptureHandoff` model and proves the
  credential-swap property.
- **Contract test:** the multipart part names/manifest still match the frozen
  `shared/ios_session_schema.json` (the "test the wire contract" rule from ADR-007).
- **Manual (device):** the full walk-around + upload on a Pro iPhone in the manual
  test plan; the restyled screens reviewed in bright-light conditions.

## Manual setup required

- **Pro iPhone** for on-device capture verification (as F-15).

## Implementation notes (filled in by the building agent)

> Owned by the builder. Starts empty.
