# Convergence Report — Wave 3 (parallel iteration): user-facing report surfaces

**Iteration:** Wave 3 (parallel iteration)
**Frozen contracts (base):** `build/wave-3-surfaces` @ `3b7c51d1618a8f96337c1a863c7661764236c4fc`
**Integration branch (throwaway):** `integration/wave-3-surfaces` @ `a55f3f8`
**Integration worktree:** `/Users/keith/dev/gauntlet/companycam/rooftrace/.claude/worktrees/wave-3-surfaces/integration`
**Date:** 2026-05-28
**Outcome:** ✅ All four features assembled cleanly. Full integrated suite green
(Rails 475/0, sidecar 299/0, JS 19/19, rubocop 0, brakeman 0). End-to-end docker-compose
smoke green on the production image (one expected Spaces-credential gap on the PDF path).
**This report is a CHECK only — no PR/MR opened, no merge to main. The human owns landing
this as one linear MR (recipe below).**

---

## Per-feature status

### F-12 — Web report viewer (`feat/f-12`)
- **Shippable:** YES
- **Acceptance:** Met. Shared Hotwire report surface (contractor `/jobs/:id/report` +
  public `/r/:token`), React/MapLibre/deck.gl island that bakes a server-serialized
  `MeasurementViewerSerializer` payload into `data-viewer-measurement-value` (no JSON-fetch /
  CORS surface), brand-styled facet/pitch encoding, feature pins, contractor-only share
  affordance, `noindex` on the public view. All 9 review gating findings auto-fixed in
  `6327d76` (JS suite repaired 19/19, Node/Yarn toolchain gated in CI + Docker before
  `assets:precompile`, UNIQUE index on `reports.job_id` closing the find_or_create race,
  ADR-013/016 amended).
- **Unresolved gating findings:** NONE.
- **Deferred low findings:** F-0.3 facet click doesn't update side panel (scope cut);
  F-0.4 feature pins use Scatterplot+Text not IconLayer; F-0.5 share control labeled
  "Share link"; F-0.6 `@deck.gl/mapbox` declared-but-unimported; F-1.0/1.1 share-token mint
  + single demo credential; F-2.1 MapLibre cleanup ordering; **F-2.2 dead
  `show_public.html.erb` stub** (see note below); F-2.3 unused `isPublic` prop; F-2.4/5.4
  null bounds → Gulf of Guinea; F-2.5 MultiPolygon bounds flatten bug; F-3.0–3.8 deck.gl /
  serializer / asset-walk micro-perf; F-3.8 double mount listener; F-5.5 `:js` specs skip
  if Chrome absent in CI. (Full list in the feature build result; all low / non-gating.)
- **QA evidence:** `yarn test` → 4 suites / 19 tests passed. Report model + report_viewer
  request + serializer specs → 28/0 on-branch. Live: public `/r/:token` 200 + `x-robots-tag:
  noindex`, contractor `/jobs/:id/report` 302→login unauth. Re-verified in integration smoke
  (see batch evidence): public viewer renders address, area, the `data-controller="viewer"`
  island mount, and the now-wired footer; viewer.js bundle baked into the prod image.
- **Retro propagation (already at source on-branch):** ADR-013 records the as-built React-island
  contract (server-baked payload, bootstrap.ts self-mount, overlaid two-canvas deck.gl, Yarn
  Berry node-modules linker). ADR-016 records eager Report creation + the unique-index race
  safeguard + uniform 4-surface token resolution. Cross-cutting lesson: a feature that adds a
  JS bundle MUST provision Node/Yarn in the Dockerfile before `assets:precompile` AND gate
  `yarn install/build/test` in CI — propagated.

### F-13 — PDF report generation (`feat/f-13`)
- **Shippable:** YES
- **Acceptance:** Met. All 22 build chunks complete. `ReportPdf` service + print-layout ERB,
  `ArtifactStore` + SSRF-safe `MapboxStaticFallback`, real Playwright top-down map render in
  the sidecar behind `RENDER_IMAGES_LIVE`, authenticated (`/jobs/:id/report.pdf`) + public
  (`/r/:token.pdf`) routes. 7 review gating findings (1 lint, 2 high/medium nil-job public-500,
  1 medium silent-blank CDN, 2 ADR/spec deferral) resolved in `9bec5ef`; doc propagation in
  `6df5db2`.
- **Unresolved gating findings:** NONE.
- **Deferred low findings:** 1.1 Mapbox token in fallback URL (URL-encoded, SSRF-safe);
  1.2 no rate limit on token-gated render; 2.4 bbox WGS84 clamp; 2.5 TOCTOU idempotency;
  2.6 fallback doesn't follow redirects; 2.7 no explicit Grover timeout; 3.0 sync-in-request
  render blocks Puma thread; 3.1 three S3 clients per render; 3.2 extra Report→job query;
  3.3 Chromium relaunched per render; 3.4/5.3 MapLibre fetched from unpkg (now fails loud);
  3.5 @2x fallback; 3.6 bbox intermediates; 3.7 boto3 client per put; 3.8 dead grover_options;
  5.2 1x DPI; 5.4 24h public signed-URL TTL; 5.5 same-second cache staleness; 0.6 ETag
  idempotency wording; 0.8 warm <10s not auto-verified. (All low/medium efficiency-robustness;
  none gating.)
- **QA evidence:** rubocop 99 files / 0 offenses; brakeman 0; full Rails suite 403/0 on-branch;
  F-13 subset 39/0; sidecar 245/0. Real Grover produces `%PDF-` bytes with extracted
  address/area/source/attribution; real sidecar Playwright returns a real PNG under
  `RENDER_IMAGES_LIVE=1`. Re-verified in integration smoke: puppeteer's Chromium baked into the
  prod image at `/usr/local/puppeteer/chrome/linux-131.0.6778.204/...`.
- **Retro propagation (already at source):** ROADMAP "Headless-render robustness" cross-cutting
  row (CDN-dependence → silent blank at HTTP 200; sync-in-request render is v1-only, async
  ActiveJob is the upgrade). ADR-014 carries the single-`image_ref` + `page.set_content` +
  top-down-basemap-only amendments.

### F-14 — JSON export endpoint (`feat/f-14`)
- **Shippable:** YES
- **Acceptance:** Met. Versioned public contract: `shared/json_export.schema.json` (draft
  2020-12, `schema_version` const `1.0.0`), stateless `JobExportSerializer` (PORO; sets the
  `app/serializers/` pattern), `JsonExportSchema` loader/boot-check, two routes —
  `GET /api/v1/jobs/:id.json` (auth, **401 not 302**, no CORS) and `GET /r/:token.json`
  (public, token-gated, `Access-Control-Allow-Origin: *`, noindex). 3 gating findings fixed in
  `42da59b`/`1565f7b`: spec reconciled to the frozen nested shape; the anonymous CORS-open 500
  no longer leaks schema-validation detail (logs server-side, `head :internal_server_error`,
  CORS only on the validated 200 path; orphaned-token → 404); ADR-016 amended.
- **Unresolved gating findings:** NONE.
- **Deferred low findings:** ADR-015 example payload still shows the pre-freeze flat shape
  (add an "Amendment (F-14)" note pointing it at the frozen nested schema — findings 0.2/0.3/5.2);
  `share_url_for` uses `job.reports.first` with no ORDER BY (2.5/5.4); CORS preflight OPTIONS to
  `/r/:token.json` unhandled (2.6); auth-route 500 still returns schema-validation detail in the
  body (login-gated, no CORS — 1.0); perf micro-findings 3.0–3.4; serializer accepts an unwired
  `pdf_url:` kwarg → `artifacts.pdf_url` permanently null in v1 (1.1). (All low / non-gating.)
- **QA evidence:** Five F-14 spec suites green on-branch post-fix (42/0, 3.19s). Re-verified in
  integration smoke: public JSON returns `schema_version 1.0.0`, nested `job{id,address,status}`,
  CORS `*`, noindex, area 2480.5; auth route 401 + no CORS unauth; bad token 404.
- **Retro propagation (already at source):** ADR-016 amendment (orchestrator-mints-Report-on-:ready
  invariant); ROADMAP "Report row creation" + "JSON export public-share identity" cross-cutting rows.
  Residual doc-hygiene item for the human: the ADR-015 *example* still shows the flat shape (the
  spec was reconciled; the example was not) — non-gating.

### F-19 — Accuracy validation harness (`feat/f-19`)
- **Shippable:** YES
- **Acceptance:** Met. All 9 chunks complete. Sidecar harness package (pure-function accuracy
  metrics, stratified test-address set + ground-truth controls, accuracy-report markdown
  generation, Rails-side measurement runner rake task, feature-detection dataset + model scorer +
  candidate sweep). 4 code/doc gating findings auto-fixed in `4488b5f` (error-aware eval scoring,
  batch-safe runner rescue, ADR-014 + ADR-015 amendments). The one remaining gating item
  (fallback-path-consistency) is an explicit **human-resolution accepted deferral** blocked on an
  orchestrator `force-LiDAR-missing` flag that F-19 is correctly forbidden from adding; documented
  in ADR-017 + `docs/VALIDATION_REPORT.md`.
- **Unresolved gating findings:** NONE (the fallback-path-consistency deferral is documented and
  accepted, not blocking).
- **Deferred low findings:** F-0.1–0.8 spec-vs-realization notes (rake-task-not-run_harness.py,
  structural-consistency P90 baseline, TODO ground-truth placeholders) all met-as-specified;
  F-1.2 floor-division median in P90; F-1.3 no S3 timeout override; F-1.4 misleading cache
  comment; F-1.5 no CI job-level timeout. (All low / non-gating.)
- **QA evidence:** Sidecar `pytest` 293/0 on-branch (combined to 299/0 in the assembled suite).
  Four code/doc gating fixes confirmed in code (error-aware scoring, guarded rescue, ADR-014/015
  amendments). Re-verified in the integrated sidecar run (299 passed).
- **Retro propagation (already at source):** ADR-017 amendment (cross-language artifact defers to
  the runtime boundary — the runner is a Rails rake task because only Rails produces a Measurement).
  ADR-014 single-image render-images scope + ADR-015 `model_3d_url`-null-in-v1 amendments keep the
  ADRs and the frozen `json_export.schema.json` / render-images contracts in agreement. The
  forward dependency (ADR-017 fallback-path metric blocked on an orchestrator flag) is recorded
  where the next planner will see it.

---

## Batch-level

### Convergence conflicts hit + how resolved
Assembled by `git merge --no-ff` of each feature branch onto `integration/wave-3-surfaces` in
DAG order **F-12 → F-13 → F-14 → F-19** (all four branched off the same frozen base, so order is
by overlap surface: viewer foundation first, then the surfaces that consume it).

1. **F-12: clean** (first onto the base).
2. **F-13 × F-12** — 3 conflicts:
   - `package.json` (add/add): F-12 = Yarn-Berry manifest with the viewer bundle deps; F-13 = a
     separate npm manifest for puppeteer. **Resolved:** merged `puppeteer@^23.0.0` into F-12's
     single Yarn-managed manifest (one package manager for both the viewer bundle and Grover's
     Chromium). Regenerated `yarn.lock` to include puppeteer; deleted the now-dead npm
     `package-lock.json`. `yarn install --immutable` confirmed consistent.
   - `Dockerfile`: F-12 = Node/Corepack-Yarn build stage; F-13 = `npm ci --omit=dev` for
     puppeteer. **Resolved:** kept F-12's Node/Yarn stage; dropped F-13's `npm ci` (puppeteer now
     installs via the existing `yarn install --immutable`, whose postinstall downloads Chromium
     into `PUPPETEER_CACHE_DIR`). Verified in the smoke: Chromium baked at
     `/usr/local/puppeteer/chrome/linux-131.0.6778.204/...`.
   - `spec/factories/measurements_factory.rb`: both added distinct traits (`:with_geometry` from
     F-12, `:complete` from F-13). **Resolved:** kept both traits intact, side by side.
3. **F-14 × F-12/F-13** — 3 conflicts:
   - `app/controllers/reports_controller.rb`: F-13 added `download_public_pdf`, F-14 added
     `export_public`. **Resolved:** kept all three public-share actions (`show_public`,
     `download_public_pdf`, `export_public`) + F-14's `render_validated_export` helper;
     `skip_before_action` lists all three.
   - `config/routes.rb`: both added a token-suffixed public route before the extension-less HTML
     viewer. **Resolved:** kept both `/r/:token.pdf` (F-13) and `/r/:token.json` (F-14) declared
     before `/r/:token` (HTML).
   - `docs/adrs/ADR-016`: F-12 and F-14 each amended the eager-Report-creation decision.
     **Resolved:** merged into one authoritative amendment (unique-index race resolution + the
     "cannot reach :ready without its Report" invariant + uniform 4-surface token resolution).
   - `docs/ROADMAP.md` auto-merged cleanly (F-13's headless-render row + F-14's Report-row /
     public-share-identity rows coexist).
4. **F-19 × F-13** — 1 conflict:
   - `sidecar/pyproject.toml`: F-13 added `playwright`, F-19 added `pyyaml`. **Resolved:** kept
     both. `uv.lock` auto-merged; `uv lock --check` confirms consistency. `.gitlab-ci.yml`
     (js_test + validation_harness), `.gitignore`, `ADR-014` (both amendments), and
     `render_images/router.py` auto-merged cleanly.

5. **Cross-feature behaviour conflict surfaced by the assembled suite (NOT a git conflict)** —
   F-12 shipped `report_download_path` / `report_download_routes_available?` as `nil`/`false`
   stubs (with a comment: "When those actions land, swap in the real route helpers") because, on
   F-12's branch alone, the PDF (F-13) and JSON (F-14) routes did not exist. F-13's
   `public_report_spec` asserts the public page links to `/r/:token.pdf`, but F-12's
   `reports/show` template (a) gates the footer behind `@measurement.present?` and (b) had the
   download path stubbed to nil. **Resolved in `a55f3f8`:** wired `report_download_path` to the
   real, context-aware routes (public → `public_report_pdf_path`/`public_report_export_path`;
   contractor → `report_pdf_job_path`/`api_v1_job_export_path`), removed the obsolete
   `report_download_routes_available?` gate, and rendered the footer in both the ready and
   not-ready states (the download controllers degrade gracefully; the share link is meaningful
   when not-ready). This is the integrator's predicted convergence resolution made in place —
   it surfaced 2 spec failures that are now green.

No conflict required human judgment; nothing was force-merged; no feature was stopped.

### Integrated suite result (quoted, run on the assembled branch)
- **Full Rails RSpec** (real sidecar subprocess, PostGIS @ 5433, viewer.js built, `bin/rails
  db:test:prepare` first): `475 examples, 0 failures` (`Finished in 36.2 seconds`). *(The first
  full run reported `475 examples, 2 failures` — the two cross-feature failures described in
  conflict #5; both green after the `a55f3f8` fix and a `yarn build`.)*
- **Sidecar pytest** (`SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest`):
  `299 passed, 9 warnings in 13.72s` (9 warnings are pre-existing `HTTP_422` FastAPI deprecations).
- **JS suite** (`yarn test`): `Test Suites: 4 passed, 4 total / Tests: 19 passed, 19 total`.
- **rubocop** (`bin/rubocop`): `118 files inspected, no offenses detected`.
- **brakeman** (`bin/brakeman`): `Security Warnings: 0 / No warnings found`.

### Smoke evidence (one end-to-end, production docker image)
Built and ran the full stack from the assembled branch via `docker compose` (isolated project
`rt-smoke`, host ports remapped to 3010/55433 to avoid the human's running dev server + `rt-pg`;
dummy `MAPBOX_PUBLIC_TOKEN`/`DEMO_*`/`OPENROUTER_API_KEY` to satisfy the production fail-fast boot
checks; `SKIP_SPACES_CHECK=1`). All three containers came up healthy. **Quoted observations:**

- **Regression / neighbouring existing paths:**
  - `GET /health` → `200`, `{"status":"ok",...,"postgres":{"ok":true,"postgis_version":"3.5 ..."}}`
  - `GET /skeleton` → `200`, full Rails→sidecar IPC round-trip:
    `{"ping_id":...,"sidecar_response":{...,"echo_payload":"hello from sidecar","sidecar_version":"0.1.0"}, "db_row":{...}}`
- **Iteration primary new path — public viewer + derivatives (no auth):**
  - `GET /r/:token` → `200`, `X-Robots-Tag: noindex`; body contains `RoofTrace report`,
    `1600 Pennsylvania`, `2480`, `data-controller="viewer"`, `viewer-footer`, and the wired
    `/r/<token>.pdf` link (**proves the convergence fix in the real image**).
  - `GET /r/:token.json` → `200`, `Access-Control-Allow-Origin: *`, `X-Robots-Tag: noindex`,
    body `{"schema_version":"1.0.0","job":{"id":...,"address":"1600 Pennsylvania Ave NW...","status":"ready"},"measurement":{...,"total_area_sq_ft":2480.5,...}}` (frozen nested shape).
  - `GET /api/v1/jobs/:id.json` (unauth) → `401 Unauthorized`, no CORS header,
    `{"error":"authentication required"}` (401 not 302, as contracted).
  - `GET /jobs/:id/report` (unauth) → `302 Found`, `Location: .../login`.
  - `GET /r/<bad-token>` → `404`; `GET /r/<bad-token>.json` → `404` (no redirect).
  - `GET /r/:token.pdf` → `500` — **expected environmental gap, not a defect:** the PDF path's
    first step (`ArtifactStore#head` against DigitalOcean Spaces) fails at the S3 client because
    this local smoke has **no real Spaces credentials** (`SKIP_SPACES_CHECK` only skips the boot
    probe; the request path still hits Spaces). F-13's deferred findings explicitly mark "full
    docker-compose round-trip to real Spaces" as a human-gated manual pass. Chromium IS present
    in the image, so Grover would render given creds.
- **Dockerfile convergence proof (from inside the prod image):**
  - puppeteer Chromium: `/usr/local/puppeteer/chrome/linux-131.0.6778.204/chrome-linux64/chrome`
  - viewer bundle precompiled: `/rails/public/assets/viewer-0d44077f.js` (1.7 MB) — `assets:precompile`
    ran `yarn build` and emitted the React island (resolves F-12's F-5.0 "prod image with no map").

Stack torn down with `down -v`; the human's `rt-pg` + `rt-sidecar-probe` containers confirmed intact.

---

## ORDERED recipe for the human (build the single linear MR)

All four feature branches share the base `build/wave-3-surfaces` @ `3b7c51d`; each is a short
linear stack. To produce ONE linear MR, rebase the stacks end-to-end in the order they were
integrated (the order in which their convergence resolutions were validated), then apply the one
integration fixup. The throwaway `integration/wave-3-surfaces` branch already contains the exact
resolved tree (`a55f3f8`) — you can diff against it at each step.

```bash
# From the repo root primary worktree, on a fresh branch off the contract base:
git fetch origin
git switch -c wave-3-surfaces build/wave-3-surfaces   # or rebase target = main if base is merged

# 1. F-12 (viewer foundation) — clean, no conflicts.
git cherry-pick 12aed99..6327d76          # feat/f-12 range (6 commits)

# 2. F-13 (PDF). Conflicts: package.json, Dockerfile, spec/factories/measurements_factory.rb.
git cherry-pick 47f34f6..6df5db2          # feat/f-13 range (8 commits)
#    - package.json: merge puppeteer@^23.0.0 into the Yarn manifest; delete package-lock.json;
#      regenerate yarn.lock:  PUPPETEER_SKIP_DOWNLOAD=1 yarn install --mode update-lockfile
#    - Dockerfile: keep the Node/Corepack-Yarn stage; drop the `npm ci` block.
#    - measurements_factory.rb: keep BOTH :with_geometry and :complete traits.

# 3. F-14 (JSON). Conflicts: reports_controller.rb, routes.rb, ADR-016.
git cherry-pick 1352c60..1565f7b          # feat/f-14 range (7 commits)
#    - reports_controller.rb: keep show_public + download_public_pdf + export_public + the
#      render_validated_export private helper; skip_before_action lists all three.
#    - routes.rb: keep /r/:token.pdf AND /r/:token.json before /r/:token (HTML).
#    - ADR-016: keep the single merged eager-Report amendment.

# 4. F-19 (validation). Conflict: sidecar/pyproject.toml.
git cherry-pick 8fd9034..4488b5f          # feat/f-19 range (8 commits)
#    - pyproject.toml: keep both playwright AND pyyaml; uv lock --check to confirm.

# 5. The one integration fixup (footer → real download routes):
git cherry-pick a55f3f8                    # integrate: wire viewer footer to PDF+JSON routes

# Verify the result matches the validated integration tree exactly:
git diff integration/wave-3-surfaces       # should be empty
```

(Commit hashes are stable on the local branches as of this report; `git log --oneline
build/wave-3-surfaces..feat/f-NN` lists each range. The `integration/wave-3-surfaces` branch is the
ground truth — if a cherry-pick range drifts, `git diff integration/wave-3-surfaces` will show it.)

Alternatively, if you prefer a single squashed history, the simplest path is to take the integration
branch's tree wholesale onto your MR branch (`git switch -c wave-3-surfaces build/wave-3-surfaces &&
git checkout integration/wave-3-surfaces -- . && git commit`) and let the MR carry the four
feature commit messages in its description.

---

## Explicit next steps for the human

1. **Land the MR (linear).** Follow the cherry-pick recipe above (or take the integration tree
   wholesale). Do NOT fast-forward `integration/wave-3-surfaces` itself — it's a throwaway; build a
   clean MR branch. After landing, `git worktree remove .claude/worktrees/wave-3-surfaces/integration`
   and delete the four `feat/*` + the `integration/*` branches.
2. **Provision production secrets before deploy** (the boot checks are fatal in production):
   `MAPBOX_PUBLIC_TOKEN` (front-end pk.* tile-read token — the viewer + the PDF Mapbox-Static
   fallback both require it), `DEMO_USERNAME` + `DEMO_PASSWORD_DIGEST`, `OPENROUTER_API_KEY`, and
   **real DigitalOcean Spaces credentials** (the PDF path needs them — it 500s without, as the smoke
   showed). Set these in `/etc/rooftrace/.env` on the droplet.
3. **Run the human-gated manual passes that the smoke could not** (all flagged non-gating but worth
   doing once before/right-after deploy): full docker-compose PDF round-trip against **real Spaces**
   (the only path the smoke couldn't exercise); cross-platform PDF open (Preview/Acrobat); warm
   `<10s` PDF timing; and the validation harness's real 15-address dataset + ground-truth controls
   (currently TODO placeholders — F-19's accuracy numbers are structural-consistency baselines until
   that data is populated).
4. **Two cheap doc-hygiene fixups** (optional, non-gating, can ride this MR or a follow-up):
   (a) add an "Amendment (F-14)" note to **ADR-015** pointing its still-flat *example payload* at the
   frozen nested schema (the spec was reconciled; the example was not); (b) the stale module docstring
   in `sidecar/app/render_images/router.py` still says "emits a deterministic placeholder PNG" though
   F-13 wired in the real renderer — and F-12's dead `app/views/reports/show_public.html.erb` stub can
   be deleted (the controller renders `reports/show`).
5. **Carry the cross-cutting lessons forward** (already propagated to ADRs/ROADMAP on the branch, no
   action needed beyond awareness for the next iteration's reviewers): (a) any JS-bundle feature must
   provision Node/Yarn in the Dockerfile before `assets:precompile` AND gate `yarn install/build/test`
   in CI; (b) headless-render robustness — no runtime-CDN dependence for render libs, and sync-in-request
   render is v1-only (async ActiveJob is the documented upgrade).
