# Grover (HTML -> PDF via Puppeteer/headless Chromium) configuration for the
# roof measurement report (ADR-014).
#
# - print media type so the report's `@media print` CSS is authoritative,
# - prefer_css_page_size so the stylesheet's @page size wins,
# - zero default margins (the print CSS owns the page chrome),
# - --no-sandbox / --disable-dev-shm-usage so headless Chromium runs inside the
#   containerized Rails image (no user namespaces, small /dev/shm).
#
# node_env_vars: the production image sets a global LD_PRELOAD=libjemalloc (to
# cut the Rails process's memory/latency). jemalloc is right for the Ruby server
# but FATAL for Chromium: preloaded into Chrome's multi-process/zygote fork it
# SIGSEGVs the render child at launch — `chrome --version` succeeds, but every
# real render dies with exit 139, surfacing only as Grover's opaque
# "Failed to launch the browser process!" (+ harmless dbus-socket noise). Grover
# shells out to node (-> Puppeteer -> Chromium) via Open3.popen3 with this env
# hash; mapping LD_PRELOAD => nil DELETES it from that child's environment
# (popen3 treats a nil value as an unset), so Chromium launches clean while the
# Rails server keeps jemalloc. Scoped to the PDF subprocess — not an image-wide
# jemalloc regression. This, not a missing system lib or a glibc version, is the
# real cause of the report-PDF launch failure (verified on native amd64: the same
# Chrome 131 binary renders DOM with LD_PRELOAD unset and segfaults with it set,
# on both Debian 12/glibc-2.36 and Debian 13/glibc-2.41).
Grover.configure do |config|
  config.options = {
    format: "Letter",
    print_background: true,
    prefer_css_page_size: true,
    emulate_media: "print",
    margin: { top: "0", bottom: "0", left: "0", right: "0" },
    launch_args: [ "--no-sandbox", "--disable-dev-shm-usage" ]
  }
  config.node_env_vars = { "LD_PRELOAD" => nil }
end
