# Grover (HTML -> PDF via Puppeteer/headless Chromium) configuration for the
# roof measurement report (ADR-014).
#
# - print media type so the report's `@media print` CSS is authoritative,
# - prefer_css_page_size so the stylesheet's @page size wins,
# - zero default margins (the print CSS owns the page chrome),
# - --no-sandbox / --disable-dev-shm-usage so headless Chromium runs inside the
#   containerized Rails image (no user namespaces, small /dev/shm).
Grover.configure do |config|
  config.options = {
    format: "Letter",
    print_background: true,
    prefer_css_page_size: true,
    emulate_media: "print",
    margin: { top: "0", bottom: "0", left: "0", right: "0" },
    launch_args: [ "--no-sandbox", "--disable-dev-shm-usage" ]
  }
end
