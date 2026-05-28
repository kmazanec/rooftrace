// esbuild build for the React report-viewer island (ADR-013).
//
// This bundles ONLY app/javascript/viewer (React + MapLibre + deck.gl) into a
// single minified file under app/assets/builds, served on the report page via a
// per-page javascript_include_tag. The Hotwire/Stimulus pages keep using
// importmap-rails — this does NOT touch them.
import * as esbuild from "esbuild";

const watch = process.argv.includes("--watch");

const config = {
  entryPoints: ["app/javascript/viewer/bootstrap.ts"],
  bundle: true,
  outfile: "app/assets/builds/viewer.js",
  format: "esm",
  target: "es2020",
  minify: true,
  sourcemap: false,
  loader: { ".png": "dataurl", ".svg": "text" },
  logLevel: "info",
};

if (watch) {
  const ctx = await esbuild.context(config);
  await ctx.watch();
  console.log("[esbuild] watching viewer bundle...");
} else {
  await esbuild.build(config);
}
