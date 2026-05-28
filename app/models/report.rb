# A shareable roof report. F-03 models only the public-share token (ADR-016);
# the rendered report content + viewer land in F-12/F-13.
class Report < ApplicationRecord
  belongs_to :job, optional: true

  before_validation :assign_share_token, on: :create

  def to_param
    share_token
  end

  private

  def assign_share_token
    self.share_token ||= TokenGenerator.token
  end
end
