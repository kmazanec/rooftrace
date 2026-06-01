require "rails_helper"

RSpec.describe DemoCredential do
  let(:username) { "demo" }
  let(:password) { "correct-horse" }

  around do |example|
    ENV["DEMO_USERNAME"] = username
    ENV["DEMO_PASSWORD_DIGEST"] = BCrypt::Password.create(password)
    example.run
  end

  describe ".valid?" do
    it "accepts the configured username and password" do
      expect(described_class.valid?(username, password)).to be(true)
    end

    it "rejects a wrong username or password" do
      expect(described_class.valid?("intruder", password)).to be(false)
      expect(described_class.valid?(username, "wrong")).to be(false)
    end

    it "rejects empty credential configuration" do
      ENV["DEMO_USERNAME"] = ""
      expect(described_class.valid?(username, password)).to be(false)

      ENV["DEMO_USERNAME"] = username
      ENV["DEMO_PASSWORD_DIGEST"] = ""
      expect(described_class.valid?(username, password)).to be(false)
    end

    it "rejects malformed bcrypt digests" do
      ENV["DEMO_PASSWORD_DIGEST"] = "not-a-bcrypt-hash"

      expect(described_class.valid?(username, password)).to be(false)
    end
  end
end
