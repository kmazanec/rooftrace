# Feature: iOS new measurement (native MapKit address entry)

**ID:** F-23 · **Roadmap piece:** F-23 · **Status:** Not started

## What this delivers (before → after)

**Before:** A contractor can't start a job from the app; jobs are created only on
the web.

**After:** From the home, the contractor enters a property address with native
**MapKit typeahead** (or taps "use my location"), submits, and the app creates the
job and moves to its live-status screen.

## How it fits the roadmap

The "start a job from the app" capability. Depends on F-21 + F-22; consumes F-20's
`POST /api/v1/jobs`.

## Requirements traced (from the PRD)

"Start a job from either web or app — enter an address or detect it from the
user's location." The backend re-geocodes with Nominatim on create, so the address
*string* is what flows (native MapKit is the entry UX, not the authoritative
geocoder).

## Dependencies (must exist before this starts)

- **F-21 iOS foundation + login** — design system, `APIClient`, nav.
- **F-22 iOS job list** — the create flow is reached from the home CTA and returns
  to the (refreshed) list / pushes to status.
- **F-20 `POST /api/v1/jobs`** (JSON create) — fakeable until it lands.

## Unblocks (what waits on this)

- **F-24 iOS live status** — create pushes straight to it with the new `job_id`.

## Contracts touched

- **iOS API client contract** (ADR-007 amendment) — *extends*: `Endpoint.createJob`
  + the `CreatedJob` decode (`job_id`, `capture_token`, `capture_token_expires_at`)
  — this is the `CaptureHandoff` source for F-25.
- **iOS native design system** (ADR-020) — *extends*: the new-job screen (eyebrow +
  Archivo headline + the address field/typeahead listbox + "use my location"
  secondary affordance) in the `cc-*` palette.

## Acceptance criteria (product behavior)

- The screen offers a single address field with **`MKLocalSearchCompleter`
  typeahead**; selecting a suggestion fills the field.
- A **"use my current location"** affordance (secondary, not competing with the
  primary CTA) reverse-geocodes the device location (`CLGeocoder`/CoreLocation,
  reusing the existing `NSLocationWhenInUseUsageDescription`) into the address
  field; on permission-denied it shows an inline, actionable message (not a dead
  end, not a system alert for the domain error).
- The **primary "Start measurement" CTA** is disabled until an address is present;
  on tap it calls `POST /api/v1/jobs` with the address and, on success, pushes to
  the live-status screen (F-24) for the returned `job_id`, carrying the
  `capture_token` for a later capture.
- **Typeahead states:** "keep typing" under the min length, a loading row while
  querying, and a "no matches — check the address" empty result.
- **Create error** (network/`422`) shows an inline error and leaves the entered
  address intact for retry.

## Testing requirements

- **Unit tests** (fakes): the create view-model enables the CTA only with an
  address; submit calls `createJob` and routes to status on success; error keeps
  state; the "use my location" path maps a fake placemark to an address string.
- **Hardware/manual:** real `MKLocalSearchCompleter` typeahead and real
  location-permission + reverse-geocode are device-side (manual test plan); the
  submit/route logic is unit-tested behind protocols.

## Manual setup required

- None beyond F-21. (Location permission is already declared.)

## Build plan (planned 2026-05-31 · iteration `ios-full-app` · see `docs/BUILD-PLAN-ios-full-app.md`)

**Model tier:** Sonnet build → Opus review. Depends on F-21 + F-22; ∥ F-26. Built against
fakes. **Produces** the `CaptureHandoff` chain (BUILD-PLAN §9.4).

### Architecture decisions
- `MKLocalSearchCompleter` wrapped behind an `AddressCompleting` protocol with a `TypeaheadState` enum (`tooShort / searching / results([Suggestion]) / noMatches`); a `FakeAddressCompleter` drives unit tests (real completer is device/manual).
- Location behind a `LocationResolving` protocol (`authStatus`, `requestWhenInUse`, `reverseGeocodeCurrent() -> String`) wrapping `CLLocationManager`+`CLGeocoder` — mirrors F-15's `LocationProviding` seam; reuses the existing `NSLocationWhenInUseUsageDescription`.
- The authoritative datum is the address **string** (backend re-geocodes with Nominatim); MapKit is entry UX only.
- Permission-denied is an inline `InlineErrorBlock` (+ Settings deep-link), never a system alert for the domain error.
- `createJob` success builds the `CaptureHandoff` (from the server response) and pushes `.jobDetail(newID)` (status).

### Adds
- View-model `CreateJobViewModel` (typeahead state machine, `canSubmit`=non-empty address, `submit()`, `useMyLocation()`); view `CreateJobView` (eyebrow + Archivo header + address field + typeahead listbox + "use my location" `GhostButton` + `PrimaryButton`).
- Component **`GhostButton`** (reserved by F-21). Consumes F-21's `createJob(address:) -> CreateJobResponse` = `{jobId, captureToken, captureTokenExpiresAt}`.

### Contrarian failure modes
- Typeahead state churn: drop stale async results (bind listbox to the current query); below min-length show "keep typing", not stale matches.
- Permission states: `.notDetermined`→request; `.denied/.restricted`→inline + Settings; `.authorizedWhenInUse`→proceed. No system alert for the already-denied domain error (the OS won't show one → silent dead-end).
- Reverse-geocode can fail / return no placemark → inline message, field stays editable, no crash on `nil`.
- CTA disabled until address present; both typeahead-select and raw typing set `address`.
- Create error (422/network) keeps the entered address for retry; disable CTA while in-flight (no double-create).
- `CaptureHandoff` is built from the **server** response, never the typed values.

### Ordered build steps (test-first)
- [ ] Define `AddressCompleting`/`TypeaheadState`/`LocationResolving` protocols + fakes.
- [ ] `CreateJobViewModel` tests: `canSubmit` gating; typeahead transitions + stale-drop; `useMyLocation()` maps fake placemark→string; permission-denied→inline; submit success→handoff+route; submit error→keeps address.
- [ ] Implement `CreateJobViewModel`.
- [ ] Build `GhostButton`; build `CreateJobView`.
- [ ] Wrap real `MKLocalSearchCompleter` (device); wrap real `CLLocationManager`/`CLGeocoder` (device).
- [ ] Wire success → `CaptureHandoff` + `router.path.append(.jobDetail(id))`; 401 → `handleUnauthorized`.

### Test list
- **Unit (fakes):** CTA gating; submit routes + builds handoff; error keeps state; fake-placemark→address; all typeahead states; permission-denied→inline (not alert).
- **Manual/device:** real typeahead; real permission grant/deny; real reverse-geocode; Settings deep-link.

### Contract touchpoints frozen
Freezes `CreateJobResponse`; **produces `CaptureHandoff`** (consumed by F-25; stashed on the
`.jobDetail` it pushes for F-24's "Improve with a scan"); routes create→status (F-24).

## Implementation notes (filled in by the building agent)

> Owned by the builder. Starts empty.
