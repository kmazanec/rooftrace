FactoryBot.define do
  factory :skeleton_ping do
    job_id { SecureRandom.uuid }
    rails_sent_at { Time.current }
    sidecar_received_at { Time.current }
    rails_received_at { Time.current }
    rtt_ms { 5 }
    sidecar_payload { { echo_payload: "hello from sidecar", sidecar_version: "0.1.0" } }
  end
end
