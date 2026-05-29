# Ops — RoofTrace deploy runbook

RoofTrace runs as three Docker containers on the shared `gauntlet`
DigitalOcean droplet (`gauntlet-1`, `ssh gauntlet`), alongside the other
biograph.dev projects. The host's **containerized Caddy** (`openemr-caddy-1`)
terminates TLS and reverse-proxies `rooftrace.biograph.dev` to the Rails
container over the shared `openemr_default` Docker network.

## Why docker-compose, not Kamal

ADR-011 originally specified Kamal. During F-01 the droplet's actual topology
made compose the right v1 choice (see the F-01 feature file "Deviations" and
ADR-011's amendment):

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
secrets. The *production* compose `ops/compose.prod.yaml` uses absolute build
contexts anchored at `/srv/rooftrace/current` and is driven by
`infra/deploy.sh`, not run by hand.)

## Production deploy — GitLab CI + release-symlink (the convention)

RoofTrace deploys the same way the sibling apps do (see workspace
`.infra/NEW_APP.md`): a GitLab CI `deploy` job on `main` runs
**`infra/deploy.sh`**, which uses the **release-symlink pattern** — rsync the
tested checkout into `/srv/rooftrace/releases/<sha>/`, atomically swap
`/srv/rooftrace/current`, build+recreate the stack, health-check the public
URL, roll back on failure, prune old releases.

### One-time droplet setup (per `.infra/NEW_APP.md` §1, as root)

```bash
ssh gauntlet
sudo mkdir -p /srv/rooftrace/releases /etc/rooftrace /opt/rooftrace/postgres /opt/rooftrace/wesm
sudo chown -R gitlab-runner:gitlab-runner /srv/rooftrace /etc/rooftrace
# Operator-placed secret file (640 root:gitlab-runner). Fill from ops/.env.example.
sudo install -m 640 -o root -g gitlab-runner /dev/stdin /etc/rooftrace/.env <<'EOF'
# ...contents of ops/.env.example with real values...
EOF
sudo /usr/local/sbin/audit-secrets.sh    # verify perms (exits 0 = ok)

# Real LiDAR is the default (RoofTrace runs REAL data — no fixtures in prod), and
# the sidecar's boot check requires the real WESM GeoPackage. Download it ONCE
# (~3.5 GB); the prod compose mounts it read-only at /data/WESM.gpkg.
sudo curl -fL --retry 3 -o /opt/rooftrace/wesm/WESM.gpkg \
  https://rockyweb.usgs.gov/vdelivery/Datasets/Staged/Elevation/metadata/WESM.gpkg
```

Also ensure the DNS A-record for `rooftrace.biograph.dev` points at the droplet
(no wildcard; each subdomain is explicit), and provision the single DO Spaces
bucket (`rooftrace`, partitioned by `uploads/` `cache/` `artifacts/` `backups/`
prefixes — ADR-010 as amended).

### Every deploy (automatic)

Push to `main` → CI `verify` (pytest + RSpec) → CI `deploy` runs
`infra/deploy.sh`. Nothing manual. To deploy a checkout by hand on the droplet:

```bash
cd /path/to/checkout && bash ./infra/deploy.sh   # uses HEAD; or DEPLOY_SHA=<sha>
```

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
offsite backup. Not wired in F-01; tracked for a later ops feature.
