# Pin npm packages by running ./bin/importmap
#
# The importmap is the loader for the Hotwire (Turbo + Stimulus) pages — the
# address form and the in-progress job status page, whose live updates ride
# Turbo Streams over ActionCable (ADR-013). The heavy React report-viewer island
# is a SEPARATE esbuild bundle loaded only on the report page (ADR-013, not here).
#
# Turbo/Stimulus are pinned to the JS that turbo-rails / stimulus-rails ship as
# Propshaft assets, so there is nothing to vendor or download.

pin "application"

pin "@hotwired/turbo-rails", to: "turbo.min.js", preload: true
pin "@hotwired/stimulus", to: "stimulus.min.js", preload: true
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js", preload: true
pin_all_from "app/javascript/controllers", under: "controllers"
