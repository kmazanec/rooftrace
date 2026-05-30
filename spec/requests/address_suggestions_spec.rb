require "rails_helper"

# Request specs for the address-entry typeahead proxy (ADR-004 amended). The
# MapboxSuggest service is stubbed here so no real Mapbox call happens — the
# service's own HTTP boundary is covered in spec/services/mapbox_suggest_spec.rb.
RSpec.describe "AddressSuggestions", type: :request do
  let(:username) { "demo" }
  let(:password) { "correct-horse" }
  let(:digest)   { BCrypt::Password.create(password) }

  around do |example|
    ENV["DEMO_USERNAME"] = username
    ENV["DEMO_PASSWORD_DIGEST"] = digest
    example.run
  end

  describe "GET /address_suggestions" do
    it "redirects unauthenticated requests to /login" do
      get address_suggestions_path, params: { q: "123 Main" }
      expect(response).to redirect_to(login_path)
    end

    context "when logged in" do
      before { post login_path, params: { username: username, password: password } }

      it "returns the trimmed suggestions for a query" do
        allow(MapboxSuggest).to receive(:new).and_return(
          instance_double(
            MapboxSuggest,
            suggest: [
              MapboxSuggest::Suggestion.new(
                name: "123 Main St",
                mapbox_id: "id-1",
                place_formatted: "Springfield, IL 62701, United States"
              )
            ]
          )
        )

        get address_suggestions_path, params: { q: "123 Main", session_token: "sess-1" }

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["suggestions"].size).to eq(1)
        expect(body["suggestions"].first).to eq(
          "name" => "123 Main St",
          "mapbox_id" => "id-1",
          "place_formatted" => "Springfield, IL 62701, United States"
        )
      end

      it "forwards q and session_token to the service" do
        service = instance_double(MapboxSuggest, suggest: [])
        allow(MapboxSuggest).to receive(:new).and_return(service)

        get address_suggestions_path, params: { q: "456 Oak", session_token: "sess-2" }

        expect(service).to have_received(:suggest).with("456 Oak", session_token: "sess-2")
      end

      it "returns an empty list (200) when the service finds nothing" do
        allow(MapboxSuggest).to receive(:new).and_return(instance_double(MapboxSuggest, suggest: []))

        get address_suggestions_path, params: { q: "zzzz" }

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq("suggestions" => [])
      end
    end
  end
end
