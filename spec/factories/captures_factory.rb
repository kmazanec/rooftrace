FactoryBot.define do
  factory :capture do
    capture_session
    sequence(:sequence_index) { |n| n }
    prompt_label { "front_facade" }
    captured_at { Time.current }
    photo_ref { "uploads/x/photo_00.jpg" }
    depth_ref { "uploads/x/depth_00.png" }
    gps { { "latitude" => 40.808, "longitude" => -96.706 } }
    attitude { { "quaternion_w" => 1.0, "quaternion_x" => 0.0, "quaternion_y" => 0.0, "quaternion_z" => 0.0 } }
    camera_intrinsics { [ 80.0, 0.0, 50.0, 0.0, 80.0, 50.0, 0.0, 0.0, 1.0 ] }
    camera_extrinsics { Array.new(16, 0.0) }
  end
end
