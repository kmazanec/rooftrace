require "digest"

class DemoCredential
  def self.valid?(username, password)
    new(username, password).valid?
  end

  def initialize(username, password)
    @username = username.to_s
    @password = password.to_s
  end

  def valid?
    return false if expected_username.empty? || digest.empty?

    username_matches? && bcrypt_matches?
  end

  private

  attr_reader :username, :password

  def expected_username
    ENV["DEMO_USERNAME"].to_s
  end

  def digest
    ENV["DEMO_PASSWORD_DIGEST"].to_s
  end

  def username_matches?
    ActiveSupport::SecurityUtils.secure_compare(
      Digest::SHA256.hexdigest(username),
      Digest::SHA256.hexdigest(expected_username)
    )
  end

  def bcrypt_matches?
    BCrypt::Password.new(digest) == password
  rescue BCrypt::Errors::InvalidHash
    false
  end
end
