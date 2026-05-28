FactoryBot.define do
  factory :report do
    job
    # share_token is assigned by the model on create.
  end
end
