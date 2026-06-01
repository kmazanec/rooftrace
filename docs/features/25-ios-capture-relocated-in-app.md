# Feature: iOS capture, relocated in-app (and restyled)

**ID:** F-25 · **Roadmap piece:** F-25 · **Status:** Done

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

## Build plan (planned 2026-05-31 · iteration `ios-full-app` · see `docs/BUILD-PLAN-ios-full-app.md`)

**Model tier:** Sonnet build → Opus review + **skeptic on the credential-handoff security
property + the frozen wire contract**. Depends on F-21 + F-24; ∥ F-26. Mostly a move +
re-seam + restyle (BUILD-PLAN §9.4, §9.6).

### Architecture decisions
- The 8-state `CaptureSessionState` machine is kept **verbatim** EXCEPT the `.tokenEntry` start is removed; the flow starts at `.setupCheck`.
- `CaptureViewModel` is initialized with an **immutable `CaptureHandoff`** instead of mutable `tokenInput`/`jobIDInput` — removing the mutable fields **is** the security property (no field left to swap; the runtime "only honor deep link on token-entry" guard becomes structurally unnecessary).
- The capture sub-flow lives inside ONE pushed `CaptureFlowView` routed by `.capture(CaptureHandoff)`; its internal switch stays inside that screen (preserving the legal-transition invariants), not flattened into `AppRouter.path`.
- **The wire contract is byte-for-byte untouched:** `buildParts`, part names (`session_json`/`photo_NN`/`depth_NN`/`world_mesh`), manifest (`manifest_version 1.0.0`), `MultipartUploader`, `AppConfig.captureSessionURL`, the `capture_token` bearer.
- Restyle only: every `.tint`/`.green`/`.red`/`.borderedProminent` → cc-*/brand components.

### Adds
- VM change: `CaptureViewModel.init(handoff:)`; `activeCredentials` seeded from the immutable handoff; `tokenInput`/`jobIDInput`/`canStart`/field-mutating `applyDeepLink` removed; initial state `.setupCheck`.
- Views: `CaptureFlowView` (pushed host); restyled `SetupCheckView`, `CapturePromptView`, `UploadProgressView`; **`TokenEntryView` deleted from the normal flow**.
- Components: **`CompassCard`** (redrawn high-contrast compass); **reuse `SegmentedProgress`** (F-24) for 8-step + mono "N OF 8"; brand success check; orange-tint recoverable failure.
- **No new Endpoint/DTO** — consumes `CaptureHandoff`; upload stays on `MultipartUploader`, NOT the JSON `APIClient`.

### Contrarian failure modes
- Payload/manifest MUST stay byte-for-byte (18 parts, optional GPS / no Null Island, HAE altitude, row-major matrices); existing capture/manifest/upload-retry tests stay green; a **contract test** pins part names against `shared/ios_session_schema.json` (ADR-007 "test the wire contract").
- No token-entry screen in the normal flow — entering capture without a `CaptureHandoff` is impossible by construction (the route carries it); the credential-swap test proves no mutable field exists.
- Deep link still works: `rooftrace://capture?token=&job_id=` → `AppRouter` → `CaptureHandoff` → `.capture`; logged-out → stash+replay. `TokenValidator.parseDeepLink` reused verbatim.
- Setup-check LiDAR gate stays at the capture boundary (`runSetupCheck()` → `.lidarUnsupported`); the new screens never gate on LiDAR.
- Idempotency/double-tap guards preserved (`captureInFlight`, `uploadInFlight`, synchronous `.uploading` on the 8th capture).
- On success, pop back to the originating job (whose status reflects the fusion when ready).

### Ordered build steps (test-first)
- [ ] Update `CaptureSessionState` start state + transition tests to begin at `.setupCheck` (drop `.tokenEntry`).
- [ ] Refactor `CaptureViewModel.init` to take `CaptureHandoff`; seed `activeCredentials`; remove mutable inputs + `canStart` + field-mutating `applyDeepLink`.
- [ ] Update the deep-link guard test to the `CaptureHandoff` model; prove no mutable credential field exists.
- [ ] Run existing capture/manifest/upload-retry tests — confirm green (wire unchanged).
- [ ] Add/confirm the contract test: part names + manifest vs `shared/ios_session_schema.json`.
- [ ] Build `CompassCard`; reuse `SegmentedProgress` (mono "N OF 8").
- [ ] Restyle `SetupCheckView`/`CapturePromptView`/`UploadProgressView` (kill `.tint`/stoplight/`.borderedProminent`); brand success check, orange-tint failure with "Try again" + "Save bundle locally".
- [ ] Build `CaptureFlowView`; route `.capture(handoff)` to it; delete `TokenEntryView` from the flow.
- [ ] Wire `AppRouter` deep-link → `CaptureHandoff` → `.capture`; stash+replay logged-out.
- [ ] On `uploadComplete`, pop back to the originating job.

### Test list
- **Unit:** state machine starts at `.setupCheck` given a handoff; deep-link guard / credential-swap property; existing capture/manifest/upload-retry suites stay green.
- **Contract:** multipart part names + manifest match `shared/ios_session_schema.json`.
- **Manual (device, Pro iPhone):** full 8-prompt walk-around + upload; restyled screens in bright sun; deep-link launch (logged-in + logged-out replay).

### Contract touchpoints frozen
Consumes `CaptureHandoff` (the only entry); freezes that the capture wire contract is
unchanged (pinned by the contract test); builds `CompassCard`; **reuses** F-24's
`SegmentedProgress` (do not ship a second).

## Implementation notes (filled in by the building agent)

- Replaced the normal capture entry path with `.capture(CaptureHandoff)`. `CaptureFlowView`
  now creates a fresh `CaptureViewModel` from the immutable handoff; token-entry state,
  mutable token/job inputs, and `TokenEntryView` are removed from the app flow.
- `CaptureSessionState` now starts at `.setupCheck`; setup still requests location
  authorization and performs the existing LiDAR probe before prompt 0.
- Deep links still route through `AppRouter`, but capture links must carry a valid
  32-character base58 token and valid `job_id` before becoming a capture route.
  Tests prove a later deep link can create a new route without mutating an active
  capture model's credentials.
- Upload and manifest wire behavior stayed on the existing `MultipartUploader`,
  `UploadRequest`, `ManifestBuilder`, multipart part names, and `capture_token`
  bearer path. Existing manifest, multipart, and upload retry suites stayed green.
- Restyled setup, prompt, LiDAR failure, upload, success, failure, and saved-bundle
  screens onto the `cc-*` tokens. The prompt screen reuses F-24 `SegmentedProgress`
  for the eight-step flow and adds a high-contrast `CompassCard`.
- Successful upload briefly shows the completion state and then pops back to the
  originating job route.
- Validation: `python3 gen_pbxproj.py`; `xcodebuild test -scheme RoofTrace -destination
  'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -derivedDataPath ./DerivedData`
  passed with 119 tests and 0 failures.
