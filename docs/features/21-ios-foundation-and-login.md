# Feature: iOS foundation + login (glob pbxproj, design system, API client, auth, nav shell)

**ID:** F-21 · **Roadmap piece:** F-21 · **Status:** Not started

## What this delivers (before → after)

**Before:** The iOS app is a single-screen capture harness with no login, no API
client beyond the one multipart uploader, no navigation graph, and raw SwiftUI
default styling. New Swift files must be hand-listed in `gen_pbxproj.py`.

**After:** The app launches to a branded **login screen**, authenticates against
`POST /api/v1/sessions`, stores the bearer in the Keychain, and lands on a
`NavigationStack` home — with the **design system**, the **typed API client**, the
**Keychain auth store**, and the **navigation shell** all in place for the
screens that follow. Adding a Swift file no longer requires editing a file list.

## How it fits the roadmap

The iOS foundation. Builds **concurrently with F-20** (backend) against a fake
`APIClient`. Per the [ADR-007 amendment](../adrs/ADR-007-mobile-capture-thin-ios-app.md)
(architecture) and [ADR-020](../adrs/ADR-020-ios-native-design-system-light-only.md)
(design system + light-only).

## Requirements traced (from the PRD)

The native client's entry surface + the scaffolding every other native feature
needs. Realizes the "everything the web does, natively" capability's auth +
shell + brand.

## Dependencies (must exist before this starts)

- **F-15 iOS capture app** — the existing Xcode project, `gen_pbxproj.py`,
  `AppConfig`, `TokenValidator`, and the patterns to follow (DI protocols,
  `@Observable @MainActor`, the `StubURLProtocol` test seam).
- **F-20 Mobile JSON API** — `POST /api/v1/sessions` is what login calls. (Login
  can be built + unit-tested against a fake `AuthService` before F-20 lands; the
  live wire-up needs F-20.)

## Unblocks (what waits on this)

- **F-22, F-23, F-24, F-25, F-26** — every native screen consumes the design
  system, the `APIClient`, the `AuthStore`, and the nav shell introduced here.

## Contracts touched

- **iOS API client contract** (source: ADR-007 amendment) — *introduces* the
  `actor APIClient`, `Endpoint<Response>`, `APIError`, the snake_case `Codable`
  DTOs, and the `JobStatus` lifecycle enum. The streamed `MultipartUploader` is
  kept separate and untouched.
- **iOS native design system** (source: ADR-020) — *introduces* `Color.CC.*` /
  `Color.Brand.*` asset sets, the bundled Archivo+Inter fonts, the SF-Mono
  measurement style, and the component kit (login is the first consumer).
- **Mobile app bearer auth** (ADR-016 amendment) — *consumes*: `KeychainTokenStore`
  + `AuthStore` store the bearer and attach it; `401` → clear + re-login.

## Acceptance criteria (product behavior)

- **`gen_pbxproj.py` is glob-based:** it discovers `*.swift` under `RoofTrace/`
  and `RoofTraceTests/` (and the test fixtures) by sorted globbing; adding a new
  Swift file and re-running needs **no manual list edit**; the regenerated project
  builds and the existing unit suite stays green. `project.pbxproj` is still never
  hand-edited.
- **Design system in place:** `Color.CC.*` and `Color.Brand.*` resolve from the
  asset catalog; Archivo + Inter are bundled and render; a `MonoValue`/measurement
  style uses SF Mono; the core components (`PrimaryButton`, `Card`, `ScreenHeader`,
  `EyebrowLabel`, `InlineErrorBlock`, at minimum) exist and are used by login. The
  app is **light-only** (`.preferredColorScheme(.light)`). No view uses
  `.borderedProminent` or system stoplight colors.
- **API client in place:** an `actor APIClient` sends a typed `Endpoint<Response>`,
  injects the bearer from the token store in one place, maps status codes to
  `APIError` (incl. `.unauthorized` for `401`), and decodes snake_case JSON; it is
  protocol-fronted so a `FakeAPIClient` can back every screen.
- **Auth + Keychain:** `KeychainTokenStore` (an `actor`, `…AfterFirstUnlockThisDeviceOnly`)
  stores/reads/clears the bearer; `AuthStore` is boolean-driven
  (`unauthenticated`/`authenticated`), bootstraps from the Keychain on launch, and
  flips to `unauthenticated` (clearing the token) on a `401`.
- **Login screen:** in the `cc-*` palette with the Archivo hero; username +
  password fields; "Sign In" shows an inline loading state; a wrong credential
  shows an inline error (`InlineErrorBlock`), never a system alert; on success the
  bearer is stored and the root swaps to the `NavigationStack` home (empty for
  now). A relaunch with a stored, valid token skips login.
- **Navigation shell:** the app root is `isAuthenticated ? NavigationStack : LoginView`;
  an `@Observable AppRouter` owns a value-based `[AppRoute]` path with the
  destinations enumerated in the ADR-007 amendment (job-detail, create-job,
  capture, report); `rooftrace://` deep links route through the router (stashed +
  replayed if logged out).

## Testing requirements

- **Unit tests against fakes** (no Keychain, no network — follow the existing
  `StubURLProtocol`/protocol-fake discipline): `APIClient` decoding + `APIError`
  mapping (incl. `401` → `.unauthorized`) via `StubURLProtocol`; `AuthStore`
  store-on-login / clear-on-`401` / bootstrap-from-stored against a
  `FakeTokenStore`; the `JobStatus` lifecycle decode (every status string → the
  right case; unknown → a defined fallback); router push/deep-link translation.
- **Build/CI:** the glob `gen_pbxproj.py` regenerates a buildable project; the iOS
  unit suite runs green on the simulator (the existing GitHub Actions macOS
  runner).
- **Hardware/manual:** real Keychain persistence across relaunch is in the manual
  test plan (the `KeychainTokenStore` is the thin untested seam behind its
  protocol).

## Manual setup required

- The **bundled font files** (Archivo ExtraBold, Inter Regular/Medium/SemiBold/Bold)
  added to the project + `UIAppFonts`; the **asset-catalog color sets** + the
  **app icon / launch screen** (roof-peak glyph) per ADR-020 — human design-asset
  review.
- On-device login + Keychain verification (the device-only seam).

## Implementation notes (filled in by the building agent)

> Owned by the builder. Starts empty. Record the `AppEnvironment` factory shape,
> the exact `Endpoint` signatures, the glob refactor approach, and any deviations;
> propagate cross-cutting discoveries to ROADMAP.md / the ADRs.
