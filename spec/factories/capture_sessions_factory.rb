FactoryBot.define do
  factory :capture_session do
    job
    sequence(:session_id) { |n| "5e551011-0000-4000-8000-#{n.to_s.rjust(12, '0')}" }
    manifest_version { "1.0.0" }
    started_at { Time.current - 2.minutes }
    ended_at { Time.current }
    world_mesh_ref { "uploads/#{job.id}/arkit_mesh.obj" }
    world_mesh_vertex_count { 8 }
    gps_seed do
      {
        "latitude" => 40.808,
        "longitude" => -96.706,
        "altitude_m" => 360.0,
        "horizontal_accuracy_m" => 3.5,
        "vertical_accuracy_m" => 5.0
      }
    end
    device_info { { "model" => "iPhone 15 Pro" } }
  end
end
