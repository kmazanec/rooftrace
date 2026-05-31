# Status — RoofTrace

**Updated:** 2026-05-31 · **Roadmap:** [ROADMAP.md](./ROADMAP.md)

## Now

v1 (F-01–F-19) is built and deployed. The current work is the **full-featured iOS
app** track (F-20–F-26): make the native app do everything the web does — sign in,
list jobs, start a job (MapKit address entry), watch live status, do the LiDAR
capture in-app, and view the report natively. Architecture + design are locked
(ADR-007 amendment, ADR-016 amendment, ADR-020).

**The whole track is now planned as one iteration (slug `ios-full-app`).** The
orchestration index + frozen shared contract is `docs/BUILD-PLAN-ios-full-app.md`
(Status: **Draft, awaiting human approval**); each feature spec carries its checkbox
build plan. **Next up: resolve the 7 open questions, flip BUILD-PLAN Status to
Approved, then launch the build.**

## Features

| ID | Feature | Status | Notes |
|----|---------|--------|-------|
| F-01 … F-19 | v1 system (skeleton, pipeline, web surfaces, thin iOS capture, validation) | Shipped | Deployed to `rooftrace.biograph.dev`. |
| F-20 | Mobile JSON API (sessions/jobs-index/status/create, bearer) | Not started | Backend; critical-path dep for the iOS screens. |
| F-21 | iOS foundation + login (glob pbxproj, design system, APIClient, Keychain auth, nav shell) | Not started | Builds concurrently with F-20 against a fake APIClient. |
| F-22 | iOS job list / home | Not started | Needs F-21; consumes F-20 `GET /api/v1/jobs`. |
| F-23 | iOS new measurement (MapKit address entry) | Not started | Needs F-21, F-22; consumes F-20 `POST /api/v1/jobs`. |
| F-24 | iOS live status (poll) | Not started | Needs F-21, F-23; consumes F-20 `GET /api/v1/jobs/:id`. Polling, not ActionCable. |
| F-25 | iOS capture, relocated in-app | Not started | Needs F-21, F-24. Move + re-seam + restyle of F-15; capture payload unchanged. |
| F-26 | iOS native report viewer (MapKit + SwiftUI) | Not started | Needs F-21 + F-20 bearer pass-through; builds early against the frozen `json_export.schema.json`. |

## Concurrency at a glance

- **F-20 (backend) ∥ F-21 (iOS foundation)** — build at the same time; F-21's
  screens run against a fake `APIClient` until F-20 lands.
- **F-26 (native report)** depends only on F-21 + the *already-frozen* JSON export
  schema, so it can be built early in parallel with the F-22→F-25 chain.
- The serial spine is **F-20 → F-21 → F-22 → F-23 → F-24 → F-25**.

## What's next

1. Plan **F-20** (mobile JSON API) and **F-21** (iOS foundation) — they form the
   foundation the rest of the track builds on and can be planned together.
2. Then F-22 → F-26 (with F-26 pullable early against the frozen export schema).
