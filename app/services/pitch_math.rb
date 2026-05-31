# frozen_string_literal: true

# Degrees from a rise-per-12 roof pitch ratio. The DB stores only the ratio
# (rise per 12 inches run); degrees is atan(ratio / 12).
module PitchMath
  module_function

  # Returns the pitch in degrees, rounded to `precision`, or nil when the ratio
  # is nil or non-positive (a 0 or negative pitch has no meaningful angle).
  def degrees(ratio, precision: 1)
    r = ratio.to_f
    return nil unless r.positive?
    (Math.atan(r / 12.0) * (180.0 / Math::PI)).round(precision)
  end
end
