require "aws-sdk-s3"

# Mints a short-lived, signed HTTPS GET URL over a DigitalOcean Spaces object
# under the `artifacts/` key prefix (the rendered report PDF and map PNG).
#
# This is the `artifacts/`-prefix sibling of ImageryUrlMinter (which is
# hard-locked to the `cache/` prefix and RAISES on anything else). The two are
# deliberately separate so neither can mint a URL over the other's partition of
# the one key-prefixed Spaces bucket (ADR-010 as amended): a report surface must
# never be able to sign a `cache/` imagery tile, and the imagery pipeline must
# never be able to sign an `artifacts/` report blob.
#
# Public API is FROZEN: ArtifactUrlMinter.call(object_key:, expires_in:),
# ArtifactUrlMinter::Error, and the ALLOWED_KEY_PREFIX / DEFAULT_EXPIRES_IN
# constants are referenced directly by specs and callers.
class ArtifactUrlMinter
  class Error < StandardError; end

  # Default lifetime of a minted URL. Bounded so a leaked report-download link
  # stops working within a day, while still surviving a normal share/download
  # session.
  DEFAULT_EXPIRES_IN = 24.hours

  # Report artifacts (PDF, map PNG) live under the `artifacts/` key prefix of the
  # one partitioned bucket (ADR-010). Asserting the prefix is defense-in-depth: a
  # future caller bug must not be able to mint a public URL over `uploads/`
  # (user-supplied photos), `cache/`, or `backups/`.
  ALLOWED_KEY_PREFIX = "artifacts/".freeze

  extend SpacesMinter
end
