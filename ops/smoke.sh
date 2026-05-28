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

green "== SMOKE PASSED =="
