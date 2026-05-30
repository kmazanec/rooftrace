require "rails_helper"

RSpec.describe MapboxSuggest do
  # A minimal stand-in for Net::HTTP: records the block's GET and returns a
  # canned response, so no real Mapbox call happens (the suite never hits the
  # network — same convention as the rest of the repo).
  def fake_http(status:, body:, capture: nil)
    response = instance_double("Net::HTTPResponse", code: status.to_s, body: body)
    Class.new do
      define_singleton_method(:start) do |host, _port, **_opts, &blk|
        capture[:host] = host if capture
        conn = Object.new
        conn.define_singleton_method(:get) do |request_uri|
          capture[:request_uri] = request_uri if capture
          response
        end
        blk.call(conn)
      end
    end
  end

  let(:session_token) { "11111111-2222-3333-4444-555555555555" }

  let(:happy_body) do
    {
      "suggestions" => [
        {
          "name" => "123 Main St",
          "mapbox_id" => "dXJuOm1ieadr.abc",
          "place_formatted" => "Springfield, IL 62701, United States"
        },
        {
          "name" => "123 Main Ave",
          "mapbox_id" => "dXJuOm1ieadr.def",
          "place_formatted" => "Springfield, IL 62702, United States"
        }
      ]
    }.to_json
  end

  it "maps Mapbox suggestions to Suggestion structs" do
    http = fake_http(status: 200, body: happy_body)
    results = described_class.new(token: "tok", http: http).suggest("123 Main", session_token: session_token)

    expect(results.size).to eq(2)
    expect(results.first.name).to eq("123 Main St")
    expect(results.first.place_formatted).to eq("Springfield, IL 62701, United States")
    expect(results.first.mapbox_id).to eq("dXJuOm1ieadr.abc")
  end

  it "passes country=us, types=address and the session token to Mapbox" do
    capture = {}
    http = fake_http(status: 200, body: happy_body, capture: capture)
    described_class.new(token: "tok", http: http).suggest("123 Main", session_token: session_token)

    expect(capture[:host]).to eq("api.mapbox.com")
    expect(capture[:request_uri]).to include("country=us")
    expect(capture[:request_uri]).to include("types=address")
    expect(capture[:request_uri]).to include("session_token=#{session_token}")
    expect(capture[:request_uri]).to include("access_token=tok")
    # We must NEVER hit /retrieve — suggest-only keeps us inside the ToS.
    expect(capture[:request_uri]).not_to include("retrieve")
  end

  it "returns [] for queries shorter than the minimum without calling Mapbox" do
    http = fake_http(status: 500, body: "boom") # would raise if called
    expect(described_class.new(token: "tok", http: http).suggest("123", session_token: session_token)).to eq([])
  end

  it "returns [] when no token is configured" do
    http = fake_http(status: 200, body: happy_body)
    expect(described_class.new(token: "", http: http).suggest("123 Main", session_token: session_token)).to eq([])
  end

  it "returns [] (never raises) on a Mapbox error response" do
    http = fake_http(status: 503, body: "unavailable")
    expect(described_class.new(token: "tok", http: http).suggest("123 Main", session_token: session_token)).to eq([])
  end

  it "returns [] (never raises) on malformed JSON" do
    http = fake_http(status: 200, body: "not json")
    expect(described_class.new(token: "tok", http: http).suggest("123 Main", session_token: session_token)).to eq([])
  end

  it "skips suggestions missing a name" do
    body = { "suggestions" => [ { "place_formatted" => "no name here" }, { "name" => "456 Oak St" } ] }.to_json
    http = fake_http(status: 200, body: body)
    results = described_class.new(token: "tok", http: http).suggest("456 Oak", session_token: session_token)
    expect(results.map(&:name)).to eq([ "456 Oak St" ])
  end
end
