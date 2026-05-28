require "securerandom"

# Generates opaque URL-safe tokens for share links and iOS capture sessions
# (ADR-016). The ADR and feature spec name `SecureRandom.base32`, which does not
# exist in Ruby's stdlib — this provides that 32-char base32 token from
# cryptographically secure random bytes instead. 32 base32 chars encode 160 bits
# of entropy (20 random bytes), matching the ADR's "~160 bits, uncrackable".
module TokenGenerator
  # RFC 4648 base32 alphabet (no padding, no ambiguous-looking exclusions —
  # uppercase A–Z + 2–7).
  ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".freeze
  TOKEN_LENGTH = 32
  # 32 chars * 5 bits/char = 160 bits = 20 bytes.
  RANDOM_BYTES = 20

  module_function

  # A 32-character RFC 4648 base32 string.
  def token
    bytes = SecureRandom.random_bytes(RANDOM_BYTES).bytes
    encode(bytes)
  end

  # Encode a byte array as base32, taking exactly TOKEN_LENGTH chars. With 20
  # bytes (160 bits, a multiple of 5) this consumes the input evenly.
  def encode(bytes)
    bits = 0
    value = 0
    out = +""
    bytes.each do |byte|
      value = (value << 8) | byte
      bits += 8
      while bits >= 5
        out << ALPHABET[(value >> (bits - 5)) & 0x1F]
        bits -= 5
      end
    end
    out << ALPHABET[(value << (5 - bits)) & 0x1F] if bits.positive?
    out[0, TOKEN_LENGTH]
  end
end
