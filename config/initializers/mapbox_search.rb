# Address-entry typeahead token (ADR-004 amended). MAPBOX_SEARCH_TOKEN is the
# server-side token for the Mapbox Search Box /suggest endpoint, used by
# MapboxSuggest behind the /address_suggestions proxy.
#
# Unlike MAPBOX_PUBLIC_TOKEN (imagery — load-bearing, raises in prod), autocomplete
# is a PROGRESSIVE ENHANCEMENT: with no token the address field is a plain text
# input and the form works exactly as before. So this NEVER raises — it only warns,
# in every environment — so a missing autocomplete token can never take down boot
# or /health. (Fail-fast is reserved for config whose absence breaks a request;
# this one doesn't.)
Rails.application.config.after_initialize do
  next if ENV["SECRET_KEY_BASE_DUMMY"].present? # assets:precompile build-time boot
  next if ENV["MAPBOX_SEARCH_TOKEN"].to_s.strip.present?

  Rails.logger&.warn(
    "[mapbox_search] MAPBOX_SEARCH_TOKEN unset — the address-entry typeahead is " \
    "disabled; the address field falls back to a plain text input (ADR-004 amended)."
  )
end
