FactoryBot.define do
  factory :measurement do
    job
    source { "lidar" }
    confidence { 0.9 }
    facets { [] }
    features { [] }
    provenance { {} }
    warnings { [] }
    generated_at { Time.current }
  end
end
