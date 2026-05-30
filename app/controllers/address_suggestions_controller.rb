# Same-origin proxy for the address-entry typeahead. The browser never holds the
# Mapbox token; this endpoint injects it server-side, calls Mapbox Search Box
# /suggest (suggest-only — see MapboxSuggest / ADR-005 amended), and returns a
# trimmed JSON list. Gated by require_demo_login like the rest of the contractor
# surface (inherited from ApplicationController).
#
# Always returns 200 with a (possibly empty) suggestions array — autocomplete is
# a progressive enhancement and must never surface an error that blocks typing.
class AddressSuggestionsController < ApplicationController
  def index
    suggestions = MapboxSuggest.new.suggest(
      params[:q],
      session_token: params[:session_token]
    )

    render json: {
      suggestions: suggestions.map do |s|
        { name: s.name, mapbox_id: s.mapbox_id, place_formatted: s.place_formatted }
      end
    }
  rescue StandardError => e
    Rails.logger.warn("[address_suggestions] suggest failed: #{e.class}: #{e.message}")
    render json: { suggestions: [] }
  end
end
