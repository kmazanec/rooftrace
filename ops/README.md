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

## Production deploy (on the droplet)

1. **DNS** — ensure `rooftrace.biograph.dev` has an A-record pointing at the
   droplet (same IP as the other biograph.dev subdomains).

2. **Get the code onto the droplet** (e.g. `git clone` the repo or `rsync`).

3. **Secrets** — create `ops/.env.production` from the template and fill it in:
   ```bash
   cp ops/.env.example ops/.env.production
   # edit ops/.env.production:
   #   POSTGRES_PASSWORD       — strong password
   #   SECRET_KEY_BASE         — `bin/rails secret`
   #   SIDECAR_SHARED_SECRET   — `openssl rand -hex 32`
   #   STORAGE_ACCESS_KEY/SECRET_KEY/ENDPOINT/REGION — DO Spaces creds
   #   GIT_SHA                 — `git rev-parse --short HEAD`
   ```
   Provision the four Spaces buckets first: `rooftrace-uploads`,
   `rooftrace-cache`, `rooftrace-artifacts`, `rooftrace-backups`.

4. **Bring up the stack** (joins the existing `openemr_default` network):
   ```bash
   docker compose -f ops/compose.prod.yaml --env-file ops/.env.production up -d --build
   docker compose -f ops/compose.prod.yaml ps    # all three healthy?
   ```

5. **Caddy route** — install the route fragment and reload Caddy:
   ```bash
   sudo cp ops/rooftrace.caddyfile /etc/caddy/conf.d/rooftrace.caddyfile
   docker exec openemr-caddy-1 caddy reload --config /etc/caddy/Caddyfile
   ```

6. **Smoke test**:
   ```bash
   ops/smoke.sh                  # hits https://rooftrace.biograph.dev
   ```

## Restart / persistence

Restarting the Rails container must not lose data (Postgres data lives on the
droplet's local disk at `/opt/rooftrace/postgres`, ADR-009):

```bash
docker compose -f ops/compose.prod.yaml restart rails
ops/smoke.sh                     # still green; previous rows still present
```

## Backups

Per ADR-009, a nightly `pg_dump` → DO Space (`rooftrace-backups/`) is the
offsite backup. Not wired in F-01; tracked for a later ops feature.
