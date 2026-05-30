# Fail fast at boot if the Mapbox public token (the report viewer's satellite
# basemap, ADR-002) is missing in production, rather than silently shipping a
# blank-basemap viewer to contractors. In dev/test we only warn — the viewer
# degrades to a neutral fallback basemap with an on-screen notice, so local work
# and the suite are not blocked.
#
# This token is FRONT-END only: it is embedded in the report page so the
# browser's MapLibre can fetch raster tiles. (The sidecar's measurement-imagery
# fetch also uses Mapbox per ADR-002, but via its own server-side token, not this
# front-end one.) Treat the public token accordingly (it is a pk.* token scoped
# to tile reads, not a secret).
Rails.application.config.after_initialize do
  next if ENV["SECRET_KEY_BASE_DUMMY"].present? # assets:precompile build-time boot

  next if ENV["MAPBOX_PUBLIC_TOKEN"].to_s.strip.present?

  message = "[mapbox] MAPBOX_PUBLIC_TOKEN unset — the report viewer will render " \
            "a neutral fallback basemap instead of Mapbox Satellite (ADR-002)."
  if Rails.env.production?
    raise message
  else
    Rails.logger&.warn(message)
  end
end
