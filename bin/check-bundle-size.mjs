#!/usr/bin/env node
// Bundle-size guard (ADR-013): the report viewer bundle must stay under 1 MB
// gzipped or the report page violates its performance budget. Run AFTER
// `yarn build`. Exits non-zero (fails CI) when the budget is breached so a
// bloated import (e.g. @deck.gl/all instead of the scoped modules) is caught.
import { readFileSync, existsSync } from "node:fs";
import { gzipSync } from "node:zlib";

const BUNDLE = "app/assets/builds/viewer.js";
const LIMIT_BYTES = 1_000_000;

if (!existsSync(BUNDLE)) {
  console.error(`[bundle-size] ${BUNDLE} not found — run \`yarn build\` first.`);
  process.exit(1);
}

const gzipped = gzipSync(readFileSync(BUNDLE)).length;
const kb = (gzipped / 1024).toFixed(1);

if (gzipped > LIMIT_BYTES) {
  console.error(
    `[bundle-size] FAIL: ${BUNDLE} is ${kb} KB gzipped (> ${LIMIT_BYTES / 1024} KB budget).`
  );
  process.exit(1);
}

console.log(`[bundle-size] OK: ${BUNDLE} is ${kb} KB gzipped (budget ${LIMIT_BYTES / 1024} KB).`);
