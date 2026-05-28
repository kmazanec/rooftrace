FactoryBot.define do
  factory :job do
    address { "1600 Pennsylvania Ave NW, Washington, DC 20500" }
    # capture_token + capture_token_expires_at are assigned by the model on create.
  end
end
