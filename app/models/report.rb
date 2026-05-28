# A shareable roof report. F-03 models only the public-share token (ADR-016);
# the rendered report content + viewer land in F-12/F-13.
class Report < ApplicationRecord
  include UniqueToken

  belongs_to :job, optional: true

  has_unique_token :share_token

  def to_param
    share_token
  end
end
