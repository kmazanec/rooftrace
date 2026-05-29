FactoryBot.define do
  factory :projected_overlay do
    capture
    sequence(:composite_ref) { |n| "artifacts/job/projected/#{n}.png" }
    sequence(:overlay_svg_ref) { |n| "artifacts/job/projected/#{n}.svg" }
    pose_confidence { 0.87 }
    low_pose_confidence { false }
    occluded_facet_ids { [] }
  end
end
