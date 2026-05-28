# A shareable roof report. F-03 models only the public-share token (ADR-016);
# the rendered report content + viewer land in F-12/F-13.
class Report < ApplicationRecord
  belongs_to :job, optional: true

  # Unguessable public share token (ADR-016) for /r/:token. has_secure_token
  # (SecureRandom.base58, 32 chars) + the DB unique index is the convention.
  has_secure_token :share_token, length: 32, on: :create

  def to_param
    share_token
  end
end
