#!/usr/bin/env bash
# Post-deploy smoke test for RoofTrace. Curls /health and /skeleton against
# the live URL and asserts both succeed with the expected JSON shape, then
# confirms a row was persisted. Run after a deploy:
#
#   ops/smoke.sh                              # hits https://rooftrace.biograph.dev
#   BASE_URL=http://localhost:3000 ops/smoke.sh   # hit a local compose stack
#
# Exits non-zero on any failure so it can gate a deploy.
set -euo pipefail

BASE_URL="${BASE_URL:-https://rooftrace.biograph.dev}"

red() { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

fail() { red "FAIL: $1"; exit 1; }

echo "== Smoke testing ${BASE_URL} =="

# --- /health ---
echo "-> GET /health"
health_status=$(curl -sS -o /tmp/rt_health.json -w '%{http_code}' "${BASE_URL}/health")
[ "$health_status" = "200" ] || fail "/health returned HTTP ${health_status} (expected 200): $(cat /tmp/rt_health.json)"
grep -q '"status":"ok"' /tmp/rt_health.json || fail "/health body missing status:ok: $(cat /tmp/rt_health.json)"
grep -q 'postgis_version' /tmp/rt_health.json || fail "/health body missing postgis_version"
green "   /health OK ($(cat /tmp/rt_health.json))"

# --- /skeleton ---
echo "-> GET /skeleton"
skeleton_status=$(curl -sS -o /tmp/rt_skeleton.json -w '%{http_code}' "${BASE_URL}/skeleton")
[ "$skeleton_status" = "200" ] || fail "/skeleton returned HTTP ${skeleton_status} (expected 200): $(cat /tmp/rt_skeleton.json)"
grep -q 'hello from sidecar' /tmp/rt_skeleton.json || fail "/skeleton body missing sidecar echo: $(cat /tmp/rt_skeleton.json)"
grep -q '"ping_id"' /tmp/rt_skeleton.json || fail "/skeleton body missing ping_id (no persisted row?)"
green "   /skeleton OK (persisted a SkeletonPing row)"

# --- DB persistence across a Rails container restart ---
# Run with --restart-test ON THE DROPLET (needs docker access to the stack).
# Catches volume-mount misconfiguration the architecture explicitly worries
# about (ADR-009): a restart must NOT lose persisted rows.
if [ "${1:-}" = "--restart-test" ]; then
  echo "-> DB persistence across restart (--restart-test)"
  command -v docker >/dev/null || fail "--restart-test needs docker on this host"

  pg_count() {
    docker exec rooftrace-postgres psql -U rooftrace -d rooftrace_production -t -A \
      -c "SELECT count(*) FROM skeleton_pings;" 2>/dev/null | tr -d '[:space:]'
  }
  before=$(pg_count)
  [ -n "$before" ] || fail "couldn't read skeleton_pings count before restart"
  echo "   rows before restart: ${before}"

  docker restart rooftrace-web >/dev/null || fail "couldn't restart rooftrace-web"
  # Wait for the app to come back.
  for _ in $(seq 1 30); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' "${BASE_URL}/health" || true)
    [ "$code" = "200" ] && break
    sleep 1
  done
  [ "$code" = "200" ] || fail "/health did not return 200 within 30s after restart"

  after=$(pg_count)
  echo "   rows after restart: ${after}"
  [ "$after" -ge "$before" ] || fail "row count dropped after restart (${before} -> ${after}) — VOLUME LOSS"
  green "   persistence OK (rows survived restart: ${before} -> ${after})"
fi

green "== SMOKE PASSED =="
