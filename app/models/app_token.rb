class AppToken < ApplicationRecord
  TTL = 30.days

  has_secure_token :token, length: 32, on: :create

  before_create :assign_expiry

  def self.authenticate(raw_token)
    return nil if raw_token.blank?

    app_token = find_by(token: raw_token)
    return nil if app_token.nil? || app_token.expired?

    app_token
  end

  def expired?
    expires_at.nil? || expires_at <= Time.current
  end

  private

  def assign_expiry
    self.expires_at ||= TTL.from_now
  end
end
