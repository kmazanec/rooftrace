# RoofTrace iOS — manual on-device test plan

These scenarios cover the paths the simulator + unit tests cannot exercise:
real LiDAR depth, real GPS, the camera, the device-orientation sensor, and the
network. Run them on the approved **iPhone 15 Pro** (iOS 17+). Record pass/fail
+ notes. The unit suite (`xcodebuild test`) covers token validation, the
row-major matrix transpose, manifest Codable, the state machine, depth encoding,
multipart assembly, and upload retry — do NOT re-test those by hand.

Pre-req: a RoofTrace backend reachable from the phone (the Debug build points at
`http://localhost:3000`; for a real device test, point a build at a reachable
host or run a tunnel). Create a Job in the web app to get a `job_id` +
`capture_token` (24h TTL).

| # | Scenario | Steps | Expected |
|---|---|---|---|
| 1 | **LiDAR setup check (happy path)** | Launch, enter token+job_id, Start. Point at a wall ~1 m away. | Setup check passes within ~5 s; advances to prompt 1 (front-left corner). |
| 2 | **Non-Pro / no-LiDAR rejection** | Install on a non-Pro iPhone (or a device without LiDAR) and run the setup check. | Terminal "Device not supported — requires an iPhone Pro or iPad Pro with LiDAR" screen; no crash; cannot proceed. |
| 3 | **Deep-link token pre-fill** | Open `rooftrace://capture?token=<32-char>&job_id=<uuid>` (e.g. from Notes). | App opens with both fields pre-filled; Start enabled (if valid). |
| 4 | **Token validation feedback** | Type a 31-char token, then a non-base58 char, then a valid 32-char token; type an invalid then valid job UUID. | Inline error while invalid; Start stays disabled until BOTH validate; 33rd char is rejected (field caps at 32). |
| 5 | **8-prompt walk-around** | Walk the house. At each prompt read the title/instruction, face the compass bearing, tap "Tap when ready". | Exactly 8 prompts in order (front-left corner → front facade → front-right corner → right facade → back-right corner → back facade → back-left corner → left facade). Button disabled while "Waiting for GPS accuracy…". After the 8th tap, upload starts automatically. |
| 6 | **Upload happy path** | Complete the walk-around with good network. | Progress bar advances; on success "Upload complete — view results at <url>"; tapping the URL copies it (paste elsewhere to confirm). Backend received an 18-part multipart with a valid session.json. |
| 7 | **Retry on airplane mode** | Just before the final tap, enable Airplane Mode. Complete the capture so upload fails; then disable Airplane Mode and tap Retry. | First attempt fails and auto-retries once; persistent failure shows the failure screen with Retry + Save locally. Retry after reconnect succeeds. The `session_id` in the re-sent bundle is unchanged (idempotent — backend returns 200 with the same record, no duplicate). |
| 8 | **Save bundle locally on persistent failure** | Force repeated upload failure (keep Airplane Mode on). Tap "Save bundle locally". | A `.zip` of the bundle is exported via the document picker; user can re-share/upload later. |
| 9 | **Token expiry 401 UX** | Use a `capture_token` whose 24h TTL has lapsed (or revoke it), complete a capture, attempt upload. | Upload fails with the token-expiry message ("Your capture link has expired…"); a retry does NOT loop (401 is surfaced immediately, not retried). |
| 10 | **Permissions denial** | On first launch deny Camera / Location. | Clear, non-crashing degradation; re-prompt guidance; GPS-gated capture button stays disabled with "Waiting for GPS accuracy…". |
| 11 | **HAE altitude sanity** | After a successful upload, inspect the stored `session.json`. | `gps_origin.altitude_m` and each `captures[].gps.altitude_m` are the WGS84 ellipsoidal height (HAE), ~30–50 m off the MSL value shown by a map app — confirms `ellipsoidalAltitude` is used, not `altitude`. |
| 12 | **Mesh export size** | Walk a full house, complete capture. | Exported `arkit_mesh.obj` is under the upload budget; if the mesh would exceed 256 MB the app surfaces an oversized error and offers Save locally. Backend rejects > 200 MB with 413. |

## Producing the real-capture fixture

After scenario 6 succeeds, retrieve the uploaded bundle from the backend's
storage (`uploads/<job_id>/`) and commit it to
`spec/fixtures/ios_sessions/real_capture/` with a short `README.md` noting the
device, date, and address. The synthetic fixture remains the CI acceptance gate;
the real capture is an additional, non-CI validation artifact.

## What requires hardware (cannot be run in CI / this environment)

Scenarios 1–2, 5, 10–12 need a physical LiDAR iPhone. Scenarios 3–4, 6–9 are
largely exercisable on a device with a reachable backend; the network paths (6–9)
are unit-tested via a `URLProtocol` stub but the real multipart round-trip and
the document-picker save are device/UX paths verified here.
