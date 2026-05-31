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

## Implementation notes (filled in by the building agent)

> Owned by the builder. Starts empty.
