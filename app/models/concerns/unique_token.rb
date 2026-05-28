# Assigns an opaque base32 token to a column on create and retries on the
# astronomically-rare unique-index collision (regenerating the token) instead of
# surfacing a RecordNotUnique 500. 160-bit tokens (TokenGenerator) make a
# collision effectively impossible; this is belt-and-suspenders so a broken RNG
# degrades to a retry, not a crash.
module UniqueToken
  extend ActiveSupport::Concern

  MAX_TOKEN_RETRIES = 3

  class_methods do
    # Declare a token column: `has_unique_token :share_token`.
    def has_unique_token(column)
      before_validation(on: :create) { self[column] ||= TokenGenerator.token }
      (token_columns << column).uniq!
    end

    def token_columns
      @token_columns ||= []
    end
  end

  # Override create-time persistence to regenerate any token column and retry
  # if the unique index rejects the insert. Each attempt runs in its own
  # savepoint (requires_new: true) so a collision rolls back only that insert —
  # without it, the failed INSERT aborts the surrounding transaction and the
  # retry can't run.
  def create_or_update(*args, **kwargs)
    return super unless new_record? && self.class.token_columns.any?

    attempts = 0
    begin
      self.class.transaction(requires_new: true) { super }
    rescue ActiveRecord::RecordNotUnique
      raise if (attempts += 1) > MAX_TOKEN_RETRIES

      self.class.token_columns.each { |c| self[c] = TokenGenerator.token }
      retry
    end
  end
end
