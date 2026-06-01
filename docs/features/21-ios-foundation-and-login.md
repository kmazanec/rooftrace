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

## Build plan (planned 2026-05-31 · iteration `ios-full-app` · see `docs/BUILD-PLAN-ios-full-app.md`)

**Model tier:** Sonnet build → Opus review (all 6 dimensions). Builds **concurrently with
F-20** against a `FakeAPIClient`. This is the largest, highest-blast-radius feature — it
lands BUILD-PLAN §4–§8. **Glob the pbxproj FIRST.**

### Two live bugs this feature fixes (verified during planning)
- **Stale pbxproj:** `RoofTraceTests/DeepLinkGuardTests.swift` is on disk but **absent** from `gen_pbxproj.py`'s hand-list — it isn't compiling today. The glob refactor (step 1) picks it up; the build must confirm the suite count rises and it's green.
- **`UIRequiredDeviceCapabilities = [arkit]`** would refuse to install the full app on non-LiDAR iPhones (blocking login). **Remove `arkit`** — capture self-gates via `runSetupCheck()` → `.lidarUnsupported`.

### Architecture decisions
- **Glob pbxproj first:** `sorted(glob("RoofTrace/**/*.swift"))` + same for `RoofTraceTests/`, byte-wise sort, forward-slash paths, exclude dotfiles/`Preview Content`. Keep `TEST_RESOURCES` an explicit list (the fixture lives outside `ios/`). Reuse the existing path→OID hash. Add `*.xcassets` (folder ref) + font files to the app Resources phase (currently empty). Run twice + `diff` for determinism.
- **One custom ISO8601 date strategy** (fractional + non-fractional fallback) on the shared decoder (BUILD-PLAN C1) — the single most likely silent decode break, paid 5× if wrong.
- **`actor APIClient` behind `APIClientProtocol`**; bearer injected in one place from the token store; `MultipartUploader` untouched + separate. `FakeAPIClient`/`FakeTokenStore` live **only in the test target** (real-data-default rule — `live()` cannot wire a fake).
- **`JobStatus` rich enum** with `.unknown(String)` + degrade-not-crash for the wire's optional `share_token`/`last_error` (no force-unwrap); exhaustive `switch`, no `default`.
- **`AuthStore.handleUnauthorized()` is idempotent** (N concurrent 401s flip once, clear Keychain once); `APIClient` never touches `AuthStore` — it only maps 401 → `.unauthorized`.
- **Light-only enforced twice** (Info.plist `UIUserInterfaceStyle=Light` + `.preferredColorScheme(.light)`).
- **Capture seam untouched:** F-21 does NOT modify `CaptureViewModel`/`CaptureSessionState`/`applyDeepLink`; it adds the auth-gated root around them. F-25 relocates capture later. The existing `onOpenURL → model.applyDeepLink` path stays intact; the new `AppRouter` owns only the new app routes for now.

### File-by-file (grouped; all in `ios/`)
- [ ] `gen_pbxproj.py` (edit) — glob discovery + assets/fonts Resources + exclusions.
- [ ] `RoofTrace/Info.plist` (edit) — add `UIUserInterfaceStyle=Light`, `UIAppFonts`; **remove `arkit`** from `UIRequiredDeviceCapabilities`.
- [ ] `RoofTrace/Assets.xcassets/` — `Color.CC.*` + `Color.Brand.*` color sets (fill from ADR-020 hex now); placeholder `AppIcon`.
- [ ] `DesignSystem/Color+Tokens.swift`, `Typography.swift` (incl `monoXL`), `Modifiers.swift`.
- [ ] `Components/` — `PrimaryButton`, `Card`, `ScreenHeader`, `EyebrowLabel`, `InlineErrorBlock` (the login-consumed subset; reserve the rest for later features).
- [ ] `Networking/` — `Endpoint.swift`, `APIError.swift`, `APIClient.swift` (+ `APIClientProtocol`), `DTOs.swift`, `JobStatus.swift`.
- [ ] `Auth/` — `TokenStoring.swift`, `KeychainTokenStore.swift` (actor, `AfterFirstUnlockThisDeviceOnly`), `AuthStore.swift`.
- [ ] `Navigation/` — `AppRoute.swift` (+ `CaptureHandoff`), `AppRouter.swift`; `App/AppEnvironment.swift` (`live()`, no fakes).
- [ ] `Views/` — `LoginView.swift` (cc palette, Archivo hero, inline loading, `InlineErrorBlock` not alert), `HomeView.swift` (empty placeholder for F-22).
- [ ] `App/RoofTraceApp.swift` (edit) — env wiring, auth-gated root, `.preferredColorScheme(.light)`, `.onOpenURL`; preserve the existing capture path.
- [ ] `RoofTraceTests/` — extract `StubURLProtocol.swift`; `FakeAPIClient`, `FakeTokenStore`, + the test files below.

### Ordered build steps (glob FIRST; test-first where logic allows)
- [ ] Glob `gen_pbxproj.py`; run twice + diff; build + full existing suite green; confirm `DeepLinkGuardTests` now compiles/runs (fix if bit-rotted).
- [ ] Add asset catalog (color sets from ADR hex) + wire assets/fonts into Resources; Info.plist (`Light`, `UIAppFonts`, remove `arkit`); build green.
- [ ] DesignSystem (Color/Typography/Modifiers) + the 5 components.
- [ ] `JobStatusDecodeTests` + `DTODecodeTests` (RED): every Rails string → case; unknown → `.unknown`; ready+null-share_token + failed+null-last_error decode without throw; **fractional AND non-fractional ISO8601 dates decode**. → DTOs + JobStatus + decoder config (GREEN).
- [ ] `APIClientTests` via `StubURLProtocol` (RED): 200 decode; 401→`.unauthorized`; 404→`.notFound`; 5xx→`.server`; bad JSON→`.decoding`; bearer present iff `requiresAuth`. → Endpoint/APIError/APIClient (GREEN). Add `FakeAPIClient`.
- [ ] `AuthStoreTests` vs `FakeTokenStore` (RED): store-on-signIn; clear-on-401; bootstrap-from-stored; **N concurrent `handleUnauthorized()` → one flip / one clear**. → TokenStoring/KeychainTokenStore/AuthStore (GREEN).
- [ ] `AppRouterTests` + deep-link tests (RED): push/pop; `rooftrace://` → route; logged-out stash → post-login replay; 401-during-replay re-stashes. → AppRoute/AppRouter (GREEN).
- [ ] `LoginView` + small `LoginViewModel` (test the model: success→signIn, wrong-cred→inline error not alert).
- [ ] `AppEnvironment.live()`, auth-gated root in `RoofTraceApp`, empty `HomeView`; preserve capture path; `.preferredColorScheme(.light)`.
- [ ] Regenerate pbxproj; full simulator suite green; confirm no `.borderedProminent`/stoplight on F-21 surfaces.

### Test list
- **Unit (fakes/StubURLProtocol, CI simulator):** DTO + date decode; `JobStatus` every-string + unknown + invariant-violation degrade; `APIClient` status→`APIError` + bearer injection; `AuthStore` store/clear/bootstrap + idempotent multi-401; `AppRouter` push/deep-link/stash-replay; design tokens resolve from the catalog. Existing capture/manifest/matrix/depth/`DeepLinkGuard` suites stay green.
- **Manual/device-gated:** real Keychain persistence across relaunch (skips login); install + login on a **non-LiDAR** iPhone (validates the `arkit` removal); fonts render (Archivo/Inter/SF Mono) + color fidelity + light-only holds in system dark; on-device login vs live F-20.

### Design assets — GENERATED 2026-05-31 (no longer human-gated)
Already in the tree — the build **wires** them, doesn't create them:
- **Fonts:** `ios/RoofTrace/Resources/Fonts/{Archivo-ExtraBold,Inter-Regular,Inter-Medium,Inter-SemiBold,Inter-Bold}.ttf` (OFL static instances, unique PostScript names — `Resources/Fonts/README.md` has the `UIAppFonts` + `Font`-scale wiring table). Add the 5 filenames to Info.plist `UIAppFonts`.
- **Color sets:** `ios/RoofTrace/Assets.xcassets/{CC,Brand}/*.colorset` — all 27 tokens (`Color.CC.*` ×11, `Color.Brand.*` ×16), light-only, faithful to `cc.css`/`brand.css` (`ink75`/`ink55` = ink at 0.75/0.55 alpha). Namespaced → `Color("CC/blue")` / `Color("Brand/orange")`.
- **App icon:** `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` (ADR-020 roof-peak, 1024², opaque). Editable source: `Resources/AppIcon.svg`.
- **Launch screen:** still built by this feature as a SwiftUI/storyboard layout (chalk + glyph + Archivo wordmark + orange rule) — a layout, not a binary asset.

Final font/icon **visual review** stays on the manual/device pass; the build is unblocked.

### Open questions (mirrored in BUILD-PLAN): unknown-status presentation (Q4), date format from F-20 (C1 — confirm `iso8601`), human-gated assets (Q7).

## Implementation notes (filled in by the building agent)

### Completed 2026-05-31

- Replaced the hand-maintained Swift source lists in `gen_pbxproj.py` with sorted
  glob discovery for app and test sources. The generator now also wires
  `Assets.xcassets` and bundled `.ttf` fonts into the app resources phase; two
  consecutive generator runs were deterministic.
- Wired the generated fonts and light-only policy in `Info.plist`, and removed
  `arkit` from `UIRequiredDeviceCapabilities` so non-LiDAR devices can install
  the shell and self-gate only at capture time.
- Added the CC/Brand color accessors, typography helpers, and the login-consumed
  component subset: `PrimaryButton`, `Card`, `ScreenHeader`, `EyebrowLabel`, and
  `InlineErrorBlock`.
- Added the typed networking foundation: `Endpoint<Response>`,
  `APIClientProtocol`, `APIClient`, `APIError`, snake-case DTO decoding, and the
  custom ISO8601 date decoder that accepts fractional and whole-second timestamps.
- Added the auth/navigation foundation: `TokenStoring`, `KeychainTokenStore`,
  `AuthStore`, `AppRoute`, immutable `CaptureHandoff`, `AppRouter`, and
  `AppEnvironment.live()` with no fakes in production wiring.
- Added `LoginViewModel`, `LoginView`, `HomeView`, and an auth-gated
  `RoofTraceApp` root while preserving the existing capture deep-link path until
  the later capture relocation feature.
- Extracted `StubURLProtocol` into a shared test helper and added unit coverage
  for API status mapping/bearer injection, job-status decoding, auth bootstrap
  and idempotent unauthorized handling, router deep-link stash/replay, and login
  success/error behavior. `DeepLinkGuardTests.swift` is now included by the glob
  generator and runs.

### Validation

- `python3 gen_pbxproj.py` twice plus `diff`: passed.
- `xcodebuild build -scheme RoofTrace -destination 'generic/platform=iOS' -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO`: passed when run with Xcode/CoreSimulator access outside the sandbox.
- `xcodebuild test -scheme RoofTrace -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -derivedDataPath ./DerivedData`: passed, 86 tests, 0 failures, when run with Xcode/CoreSimulator access outside the sandbox.

### Assumptions and deferrals

- The real Keychain persistence and visual font/icon review remain device-manual
  checks, as planned.
- The empty `HomeView` intentionally stays minimal; the job list feature replaces
  it with the real home surface.
