#!/usr/bin/env bash
#
# RoofTrace production deploy — release-symlink pattern, matching the droplet
# convention in `.infra/NEW_APP.md` (canonical reference: yourai/context-shield/
# infra/deploy.sh). Invoked by the GitLab CI `deploy` job from the runner's OWN
# checkout of the tested commit (`bash ./infra/deploy.sh`), NOT from the deployed
# release tree — so the runner always runs THIS commit's deploy logic.
#
# Differences from the single-service context-shield reference (RoofTrace is a
# Rails app + a Python sidecar + Postgres, all in one compose stack):
#   * The release tree is the WHOLE repo (Rails at root, sidecar/ as a subdir).
#     compose.prod.yaml builds the rails image from /srv/rooftrace/current and
#     the sidecar image from /srv/rooftrace/current/sidecar.
#   * Health-check hits the PUBLIC URL (https://rooftrace.biograph.dev/up — the
#     cheap liveness endpoint), since Caddy already fronts it; falls back to an
#     in-network exec check if the public URL isn't reachable from the runner.
#   * The Postgres data volume lives at /opt/rooftrace/postgres (created by the
#     F-01 deploy with live data); it is NOT under the release tree and survives
#     every release swap.
#
# Layout this script CREATES (idempotently) and assumes:
#   /srv/rooftrace/releases/<sha>/   immutable per-release trees (rsynced from checkout)
#   /srv/rooftrace/current           symlink -> releases/<sha>/ (atomic swap)
#   /etc/rooftrace/.env              operator-placed secrets (640 root:gitlab-runner)
#   /etc/rooftrace/docker-compose.yml + rooftrace.caddyfile  synced from ops/ each run
#   /opt/rooftrace/postgres          Postgres data volume (persistent, outside releases)

set -euo pipefail

RELEASES_DIR=${RELEASES_DIR:-/srv/rooftrace/releases}
CURRENT_LINK=${CURRENT_LINK:-/srv/rooftrace/current}
CONFIG_DIR=${CONFIG_DIR:-/etc/rooftrace}
CADDY_CONFD=${CADDY_CONFD:-/etc/caddy/conf.d}
COMPOSE_PROJECT=${COMPOSE_PROJECT:-rooftrace}
PUBLIC_URL=${PUBLIC_URL:-https://rooftrace.biograph.dev}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-300}
KEEP_RELEASES=${KEEP_RELEASES:-2}
SHARED_NETWORK=${SHARED_NETWORK:-openemr_default}

log() { echo "[deploy] $*"; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECKOUT_DIR=${CI_PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}

# Deploy EXACTLY the commit CI tested (DEPLOY_SHA=$CI_COMMIT_SHA), defending the
# `needs: [test]` gate. Fall back to the checkout HEAD for a manual invocation.
if [[ -n "${DEPLOY_SHA:-}" ]]; then
    NEW_SHA="${DEPLOY_SHA}"
else
    NEW_SHA=$(git -C "${CHECKOUT_DIR}" rev-parse HEAD)
    log "no DEPLOY_SHA set (manual invocation); deploying checkout HEAD ${NEW_SHA}"
fi
SHORT_SHA=$(printf '%s' "${NEW_SHA}" | cut -c1-7)

log "starting at $(date -Iseconds)"

# ---------------------------------------------------------------------
# 1. Provision the on-host layout (idempotent). /srv is root-owned, so the
#    unprivileged runner cannot create /srv/rooftrace itself — that one-time
#    privileged setup must already be done (see .infra/NEW_APP.md §1).
# ---------------------------------------------------------------------
if ! mkdir -p "${RELEASES_DIR}" "${CONFIG_DIR}" 2>/dev/null; then
    log "FATAL: cannot create ${RELEASES_DIR} / ${CONFIG_DIR} as $(whoami)."
    log "       One-time setup is missing — on the droplet, as root:"
    log "         sudo mkdir -p ${RELEASES_DIR} ${CONFIG_DIR} /opt/rooftrace/postgres"
    log "         sudo chown -R gitlab-runner:gitlab-runner $(dirname "${RELEASES_DIR}") ${CONFIG_DIR}"
    log "       and place ${CONFIG_DIR}/.env (640 root:gitlab-runner). See .infra/NEW_APP.md."
    exit 1
fi

if [[ -L "${CURRENT_LINK}" ]]; then
    OLD_SHA=$(basename "$(readlink -f "${CURRENT_LINK}")")
else
    OLD_SHA=""
fi
log "deploying ${OLD_SHA:-<none>} -> ${NEW_SHA}"

# ---------------------------------------------------------------------
# 2. Materialize this SHA as a release by rsyncing the whole checkout.
# ---------------------------------------------------------------------
NEW_RELEASE="${RELEASES_DIR}/${NEW_SHA}"
log "materializing release ${NEW_SHA} from checkout ${CHECKOUT_DIR}"
mkdir -p "${NEW_RELEASE}"
rsync --archive --delete \
    --exclude='.git/' \
    --exclude='tmp/' --exclude='log/' \
    --exclude='node_modules/' \
    --exclude='.bundle/' \
    --exclude='sidecar/.venv/' --exclude='sidecar/.pytest_cache/' \
    --exclude='**/__pycache__/' \
    --exclude='worktrees/' \
    "${CHECKOUT_DIR}/" "${NEW_RELEASE}/"

# ---------------------------------------------------------------------
# 3. Copy managed config into CONFIG_DIR. CONFIG_DIR is SHARED (also holds the
#    root-written .env), so do NOT use --archive/--delete (would chgrp the dir
#    or delete the .env). Copy only the files we own, no owner/group, no delete.
# ---------------------------------------------------------------------
log "syncing compose + caddyfile to ${CONFIG_DIR}"
rsync --recursive --links --perms --times --no-owner --no-group \
    "${NEW_RELEASE}/ops/compose.prod.yaml" \
    "${CONFIG_DIR}/docker-compose.yml"
rsync --recursive --links --perms --times --no-owner --no-group \
    "${NEW_RELEASE}/ops/rooftrace.caddyfile" \
    "${CONFIG_DIR}/rooftrace.caddyfile"

ENV_FILE="${CONFIG_DIR}/.env"
if [[ ! -r "${ENV_FILE}" ]]; then
    log "FATAL: cannot read ${ENV_FILE} as $(whoami) — provision it once (see .infra/NEW_APP.md §4.1)"
    ls -la "${ENV_FILE}" 2>/dev/null || true
    exit 1
fi

# Stamp the deployed SHA into /health. GIT_SHA is passed to compose via a tiny
# --env-file (compose interpolation), since the compose `environment:` block
# (which references ${GIT_SHA}) takes precedence over the root-owned .env.
#
# rm -f first: a previous *manual* deploy run as root (e.g. the initial
# cutover via `ssh gauntlet`) leaves this file owned by root, and then the CI
# runner can't truncate it with `>` (EPERM). The runner owns CONFIG_DIR, so it
# CAN unlink the file regardless of the file's owner (unlink is governed by
# directory write permission), then recreate it runner-owned.
GIT_SHA_ENV="${CONFIG_DIR}/git-sha.env"
rm -f "${GIT_SHA_ENV}" 2>/dev/null || true
cat > "${GIT_SHA_ENV}" <<EOF
GIT_SHA=${SHORT_SHA}
EOF

# ---------------------------------------------------------------------
# 4. Install the Caddy route snippet (idempotent).
# ---------------------------------------------------------------------
log "installing Caddy route snippet into ${CADDY_CONFD}"
mkdir -p "${CADDY_CONFD}"
# rm -f before cp: a prior manual deploy (sudo) can leave this snippet
# root-owned, and `cp` opening it for write would then EPERM even though the
# runner owns CADDY_CONFD. Unlinking (governed by directory write perm) lets
# the runner replace it with a runner-owned copy. Same defense as git-sha.env.
CADDY_SNIPPET="${CADDY_CONFD}/rooftrace.caddyfile"
rm -f "${CADDY_SNIPPET}" 2>/dev/null || true
cp "${NEW_RELEASE}/ops/rooftrace.caddyfile" "${CADDY_SNIPPET}"

# ---------------------------------------------------------------------
# 5. Atomic symlink swap.
#
# Everything from here on can leave `current` pointing at the NEW (possibly
# broken) release. roll_back() undoes the swap completely — symlink, the synced
# compose file, the stamped GIT_SHA — and recreates the OLD stack, so a failed
# deploy never leaves `current` lying about what's actually running. It is
# invoked from BOTH failure paths below: a build/recreate failure (step 6, which
# `set -e` would otherwise abort on before any rollback) and a health-check
# failure (step 7). Safe to define before the swap; only called after it.
# ---------------------------------------------------------------------
roll_back() {
    local reason="$1"
    log "FAILURE: ${reason}"
    docker compose --project-name "${COMPOSE_PROJECT}" logs --tail=60 2>/dev/null || true
    if [[ -z "${OLD_SHA}" || ! -d "${RELEASES_DIR}/${OLD_SHA}" ]]; then
        log "no previous release to roll back to — leaving current at ${NEW_SHA}"
        return 1
    fi
    local old_release="${RELEASES_DIR}/${OLD_SHA}"
    log "rolling back ${CURRENT_LINK} ${NEW_SHA} -> ${OLD_SHA}"
    local tmp_link="${CURRENT_LINK}.rollback.$$"
    ln -sfn "${old_release}" "${tmp_link}"
    mv -T "${tmp_link}" "${CURRENT_LINK}"
    # Restore the OLD release's compose file and re-stamp the OLD short SHA, so
    # the rolled-back stack is rebuilt from the old sources AND reports the old
    # SHA in /health (not the new one we were trying to deploy).
    rsync --recursive --links --perms --times --no-owner --no-group \
        "${old_release}/ops/compose.prod.yaml" "${CONFIG_DIR}/docker-compose.yml"
    rm -f "${GIT_SHA_ENV}" 2>/dev/null || true
    printf 'GIT_SHA=%s\n' "$(printf '%s' "${OLD_SHA}" | cut -c1-7)" > "${GIT_SHA_ENV}"
    ( cd "${CONFIG_DIR}" && docker compose --project-name "${COMPOSE_PROJECT}" \
        --env-file "${GIT_SHA_ENV}" up --detach --build --force-recreate ) || true
    log "rolled back to ${OLD_SHA}"
    return 0
}

log "swapping ${CURRENT_LINK} ${OLD_SHA:-<none>} -> ${NEW_SHA}"
TMP_LINK="${CURRENT_LINK}.new.$$"
ln -sfn "${NEW_RELEASE}" "${TMP_LINK}"
mv -T "${TMP_LINK}" "${CURRENT_LINK}"

# ---------------------------------------------------------------------
# 6. Verify the shared network, then build + recreate. Build contexts in the
#    compose file are absolute (/srv/rooftrace/current[/sidecar]), so the images
#    match the just-swapped SHA. Fail closed if openemr_default is missing.
# ---------------------------------------------------------------------
if ! docker network inspect "${SHARED_NETWORK}" >/dev/null 2>&1; then
    log "FATAL: shared network ${SHARED_NETWORK} not found — is the openemr stack up?"
    log "       Caddy lives on it and must reach rooftrace-web over it."
    exit 1
fi

cd "${CONFIG_DIR}"
log "building and recreating the stack"
# Don't let `set -e` abort here: a build error (bad Dockerfile) or a recreate
# error (a container that won't pass its compose healthcheck — e.g. the sidecar
# failing its boot check) must roll the symlink back, not exit with `current`
# still pointing at the broken release. `|| roll_back ...` catches both.
if ! docker compose --project-name "${COMPOSE_PROJECT}" \
        --env-file "${CONFIG_DIR}/git-sha.env" \
        up --detach --build --force-recreate; then
    roll_back "docker compose build/recreate failed for ${NEW_SHA}"
    exit 1
fi

# Best-effort Caddy reload (the openemr compose owns the caddy container).
CADDY_CONTAINER=$(docker ps --format '{{.Names}}' | grep -m1 caddy || true)
if [[ -n "${CADDY_CONTAINER}" ]]; then
    log "reloading Caddy (${CADDY_CONTAINER})"
    docker exec "${CADDY_CONTAINER}" caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
        || log "caddy reload failed (snippet is in place for next restart); continuing"
fi

# ---------------------------------------------------------------------
# 7. Health-check loop. Prefer the public URL (proves the whole path incl.
#    Caddy); fall back to an in-network exec against /up if the runner can't
#    reach the public URL. Roll the symlink back on failure.
# ---------------------------------------------------------------------
log "waiting for health (timeout ${HEALTH_TIMEOUT}s)"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
healthy=0
while (( $(date +%s) < deadline )); do
    if curl -fsS -o /dev/null --max-time 10 "${PUBLIC_URL}/up" 2>/dev/null; then
        log "healthy (public ${PUBLIC_URL}/up)"
        healthy=1
        break
    fi
    if timeout 10 docker compose --project-name "${COMPOSE_PROJECT}" exec -T rails \
            curl -fsS -o /dev/null http://127.0.0.1:80/up 2>/dev/null; then
        log "healthy (in-network /up; public URL not reachable from runner)"
        healthy=1
        break
    fi
    sleep 5
done

if (( healthy == 0 )); then
    roll_back "health check did not pass within ${HEALTH_TIMEOUT}s"
    exit 1
fi

# ---------------------------------------------------------------------
# 8. Prune old releases (keep KEEP_RELEASES + whatever current points at).
# ---------------------------------------------------------------------
KEEP_TARGET=$(readlink -f "${CURRENT_LINK}")
log "pruning ${RELEASES_DIR} (keeping ${KEEP_RELEASES} + current)"
# shellcheck disable=SC2012
mapfile -t all_releases < <(ls -1dt "${RELEASES_DIR}"/*/ 2>/dev/null | sed 's:/$::')
kept=0
for r in "${all_releases[@]}"; do
    if [[ "${r}" == "${KEEP_TARGET}" ]]; then
        log "keep ${r} (current)"
        continue
    fi
    if (( kept < KEEP_RELEASES - 1 )); then
        log "keep ${r}"
        kept=$(( kept + 1 ))
    else
        log "prune ${r}"
        rm -rf "${r}" || log "rm -rf ${r} failed; leaving it"
    fi
done

log "complete at $(date -Iseconds)"
