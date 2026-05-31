# frozen_string_literal: true

# The data-source attributions every report must carry (PDF + viewer + export).
# Canonical spellings per LICENSES.md — a single list so the PDF and the web
# viewer can never disagree on a legally-required attribution string.
module RequiredAttributions
  NAMES = [ "Mapbox", "USGS 3DEP", "Microsoft Building Footprints", "Regrid", "Nominatim" ].freeze
end
