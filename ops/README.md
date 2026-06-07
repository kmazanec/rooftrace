# Ops — RoofTrace deploy runbook

RoofTrace runs as three Docker containers on the shared `gauntlet`
DigitalOcean droplet (`gauntlet-1`, `ssh gauntlet`), alongside the other
biograph.dev projects. The host's **containerized Caddy** (`openemr-caddy-1`)
terminates TLS and reverse-proxies `rooftrace.biograph.dev` to the Rails
container over the shared `openemr_default` Docker network.

## Why docker-compose, not Kamal

ADR-011 originally specified Kamal. The droplet's actual topology made compose
the right v1 choice (see ADR-011's amendment):

- The host Caddy is a **container** on `openemr_default`; siblings join that
  network and Caddy routes to them by container name. There's no host-port hop.
- Kamal 2 requires a registry even for on-host builds, and its default proxy
  collides with the existing Caddy on ports 80/443.
- The sibling apps (cats, context-shield) already deploy via plain compose on
  `openemr_default`. We match that convention.

`deploy.yml` (Kamal) is kept here as documentation of the intended multi-host
future; it is **not** the active deploy path.

## Local development

```bash
docker compose -f ops/compose.yaml up --build
curl http://localhost:3000/health
curl http://localhost:3000/skeleton
docker compose -f ops/compose.yaml down       # add -v to wipe the DB volume
```

(`ops/compose.yaml` is the dev stack — relative build contexts, weak local
secrets. The *production* compose `ops/compose.prod.yaml` references the prebuilt
images by SHA tag (`image: rooftrace-{rails,sidecar}:${GIT_SHA}`, not `build:`)
and is driven by `infra/deploy.sh`, not run by hand.)

## Production deploy — GitLab CI + release-symlink (the convention)

RoofTrace deploys the same way the sibling apps do (see workspace
`.infra/NEW_APP.md`): a GitLab CI `deploy` job on `main` runs
**`infra/deploy.sh`**, which uses the **release-symlink pattern** — rsync the
tested checkout into `/srv/rooftrace/releases/<sha>/`, atomically swap
`/srv/rooftrace/current`, recreate the stack, health-check the public URL, roll
back on failure, prune old releases.

**Build once, test the image, deploy that image** (ADR-011 amended). The CI
`build` stage builds the production images ONCE, tagged by full commit SHA; the
`verify` jobs run the suites INSIDE those images; and `deploy.sh` recreates the
stack from the **same SHA-tagged images** (compose `image:`, not `build:`) — the
exact bytes CI verified, no rebuild. No registry: the runner and the droplet are
the same host, so the local SHA tag is the shared artifact. `deploy.sh`
pre-flight-checks the images exist before the swap and fails loud if not; it
prunes each retired release's images alongside its release dir, keeping
`KEEP_RELEASES` image pairs so a rollback always has its images.

### One-time droplet setup (per `.infra/NEW_APP.md` §1, as root)

```bash
ssh gauntlet
sudo mkdir -p /srv/rooftrace/releases /etc/rooftrace /opt/rooftrace/postgres
sudo chown -R gitlab-runner:gitlab-runner /srv/rooftrace /etc/rooftrace
# Operator-placed secret file (640 root:gitlab-runner). Fill from ops/.env.example.
sudo install -m 640 -o root -g gitlab-runner /dev/stdin /etc/rooftrace/.env <<'EOF'
# ...contents of ops/.env.example with real values...
EOF
sudo /usr/local/sbin/audit-secrets.sh    # verify perms (exits 0 = ok)

# Real LiDAR is the default (RoofTrace runs REAL data — no fixtures in prod), and
# the sidecar's boot check requires the real WESM GeoPackage. Download it ONCE
# (~3.5 GB) onto the droplet's root disk under /opt/rooftrace/ (a host bind-mount
# outside the release tree, like the postgres data dir); the prod compose
# bind-mounts it read-only at /data/WESM.gpkg from this exact path
# (ops/compose.prod.yaml, the sidecar volume).
sudo mkdir -p /opt/rooftrace/wesm
sudo curl -fL --retry 3 -o /opt/rooftrace/wesm/WESM.gpkg \
  https://rockyweb.usgs.gov/vdelivery/Datasets/Staged/Elevation/metadata/WESM.gpkg
```

Also ensure the DNS A-record for `rooftrace.biograph.dev` points at the droplet
(no wildcard; each subdomain is explicit), and provision the single DO Spaces
bucket (`rooftrace`, partitioned by `uploads/` `cache/` `artifacts/` `backups/`
prefixes — ADR-010 as amended).

### One-time: deploy the SAM2 Modal function (required for outline refinement)

The roof-outline refinement stage (ADR-005, ADR-012) runs **SAM2 on Modal**
(serverless GPU). The Modal *app* must be deployed once to the Modal account
whose tokens are in the env (`MODAL_TOKEN_ID` / `MODAL_TOKEN_SECRET`); the sidecar
calls it by name (`modal.Function.from_name("rooftrace-sam2", "segment_roof")`).
**Until it is deployed, the sidecar cannot reach SAM2** — `from_name(...).remote()`
raises `NotFoundError: App 'rooftrace-sam2' not found`, which the sidecar surfaces
as a 502; the pipeline then **degrades to the unrefined MS-footprint outline**
(with an `outline_unrefined` warning on the report) rather than failing. So a
RoofTrace deploy *works* without Modal, but produces a coarser outline (and, with
no SAM2 trimming, a larger area and more facets) until this is done.

Run from a machine with the `modal` CLI and the Modal account credentials (NOT on
the droplet — this is a one-time developer/operator step). The CLI must be the
same major as the sidecar's `modal` (currently **1.4.x**), else the deployed
function may not resolve.

```bash
# 1. Install the Modal CLI as an isolated tool. (Use uv, not `pip install modal`
#    into system Python — Homebrew's python3 may be too new for modal's wheels;
#    uv pins its own interpreter and puts the CLI on PATH at ~/.local/bin/modal.)
uv tool install modal        # `uv tool upgrade modal` to bump later

# 2. Authenticate. The tokens already live in the repo `.env`
#    (MODAL_TOKEN_ID / MODAL_TOKEN_SECRET), so just export them for this shell —
#    no interactive `modal token new` needed:
set -a; . .env; set +a        # loads .env into the environment
#    (or run `modal token new` to auth interactively instead.)

# 3. Deploy the SAM2 app. The function file lives in the sidecar tree; it is a
#    standalone Modal app (NOT imported by the sidecar at runtime). The Modal
#    image build downloads the SAM2.1 checkpoint and installs torch + sam2
#    (first deploy takes a few minutes).
modal deploy sidecar/app/outline/sam2_modal.py

# 4. Verify it is reachable (app + function resolve, GPU cold-start ~30s):
modal app list | grep rooftrace-sam2
```

After it deploys, the sidecar's `refine-outline` stage uses real GPU SAM2 with no
code change or restart (it resolves the function by name on each call). Re-run a
job and confirm the report no longer carries the `outline_unrefined` warning and
the facet/area counts tighten.

> The function file is `sidecar/app/outline/sam2_modal.py` (GPU `A10G`, 60s
> timeout, checkpoint `sam2.1_hiera_large.pt`). Redeploy after any change to it.

### Every deploy (automatic)

Push to `main` → CI `build` (build the prod images SHA-tagged) → CI `verify`
(pytest + RSpec + JS, run inside those images) → CI `deploy` runs
`infra/deploy.sh`, reusing the images `build` produced. Nothing manual.

To deploy a checkout by hand on the droplet:

```bash
cd /path/to/checkout && bash ./infra/deploy.sh   # uses HEAD; or DEPLOY_SHA=<sha>
```

A by-hand run has no prior CI build, so `deploy.sh` **builds the images inline**
first (it detects the absence of `DEPLOY_SHA`). A CI deploy sets `DEPLOY_SHA` and
skips the inline build, reusing the `build_images` job's artifacts on the same
host. Either way the deploy reuses SHA-tagged images and never rebuilds during the
compose recreate.

`infra/deploy.sh` syncs `ops/compose.prod.yaml` → `/etc/rooftrace/docker-compose.yml`
and `ops/rooftrace.caddyfile` → `/etc/caddy/conf.d/`, then runs compose from
`/etc/rooftrace/` and reloads Caddy.

### Smoke test (post-deploy gate, run by deploy.sh; also runnable by hand)

```bash
ops/smoke.sh                          # hits https://rooftrace.biograph.dev
BASE_URL=http://localhost:3000 ops/smoke.sh --restart-test   # local + persistence
```

## Restart / persistence

Restarting the Rails container must not lose data (Postgres data lives on the
droplet's local disk at `/opt/rooftrace/postgres`, ADR-009 — outside the
release tree, so release swaps never touch it):

```bash
cd /etc/rooftrace && docker compose -p rooftrace restart rails
ops/smoke.sh                     # still green; previous rows still present
```

## Backups

Per ADR-009, a nightly `pg_dump` → DO Space (`rooftrace-backups/`) is the
offsite backup. Not wired up yet; tracked for a later ops feature.
