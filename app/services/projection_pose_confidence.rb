# Rails-authoritative per-photo pose confidence for the photo-overlay stage
# (ADR-019). Rails — not the sidecar — owns this score: it knows the
# session-level ICP residual (icp_rmse_m) and the per-photo camera extrinsics.
# The sidecar may only NARROW the returned value (e.g. if it detects a degenerate
# projection), never raise it.
#
# The score in [0, 1] combines:
#   1. an ICP-residual term, monotonic-decreasing in icp_rmse_m (a looser global
#      alignment means every photo's world->camera pose is less trustworthy), and
#   2. a per-photo extrinsics sanity GATE: the 4x4 must be finite, have an
#      orthonormal-ish rotation block, and a plausible translation. A pose that
#      fails the gate scores 0.0 (a broken overlay is worse than none).
#
# Below ProjectionPoseConfidence.threshold (default 0.7, configurable via the
# PROJECTION_POSE_CONFIDENCE_MIN env var) the projection job generates NO
# composite and instead persists a low_pose_confidence overlay so the viewer/PDF
# surface a warning rather than a misregistered drawing.
class ProjectionPoseConfidence
  DEFAULT_THRESHOLD = 0.7

  # ICP residual (m) at/above which the residual term contributes nothing. A
  # tighter fit (smaller rmse) yields a higher score; 0 m -> 1.0.
  RMSE_FLOOR_M = 0.0
  RMSE_CEILING_M = 0.5

  # A capture session's photos are taken within a short walk-around; a camera
  # translation beyond this (m) from the session origin is implausible and gates
  # the pose out (a corrupt/garbage extrinsic).
  MAX_TRANSLATION_M = 1_000.0

  # Tolerance for the rotation block being orthonormal (R^T R ~ I).
  ORTHONORMAL_TOLERANCE = 0.05

  def self.threshold
    raw = ENV["PROJECTION_POSE_CONFIDENCE_MIN"]
    return DEFAULT_THRESHOLD if raw.nil? || raw.strip.empty?

    Float(raw)
  rescue ArgumentError
    DEFAULT_THRESHOLD
  end

  def self.acceptable?(score)
    return false if score.nil?

    score >= threshold
  end

  def self.score(icp_rmse_m:, extrinsics:)
    new(icp_rmse_m: icp_rmse_m, extrinsics: extrinsics).score
  end

  def initialize(icp_rmse_m:, extrinsics:)
    @icp_rmse_m = icp_rmse_m
    @extrinsics = extrinsics
  end

  def score
    # No converged fusion residual -> no trustworthy global alignment -> 0.
    return 0.0 if @icp_rmse_m.nil?
    return 0.0 unless extrinsics_sane?

    residual_term.clamp(0.0, 1.0).round(4)
  end

  private

  # 1.0 at rmse=0, falling linearly to a small floor at RMSE_CEILING_M, so the
  # score is monotonic-decreasing in icp_rmse_m.
  def residual_term
    rmse = @icp_rmse_m.to_f
    span = RMSE_CEILING_M - RMSE_FLOOR_M
    t = ((rmse - RMSE_FLOOR_M) / span).clamp(0.0, 1.0)
    # Map t=0 -> 1.0, t=1 -> 0.4 (a converged-but-loose fit still earns some
    # confidence; the threshold gate decides usability).
    1.0 - 0.6 * t
  end

  def extrinsics_sane?
    m = @extrinsics
    return false unless m.is_a?(Array) && m.length == 16
    return false unless m.all? { |v| v.is_a?(Numeric) && v.to_f.finite? }

    rotation_orthonormal?(m) && translation_plausible?(m)
  end

  # The 3x3 rotation block (row-major rows 0..2, cols 0..2) should satisfy
  # R^T R ~ I. Checks column norms ~1 and pairwise column dot products ~0.
  def rotation_orthonormal?(m)
    cols = [
      [ m[0], m[4], m[8] ],
      [ m[1], m[5], m[9] ],
      [ m[2], m[6], m[10] ]
    ]
    cols.each do |c|
      norm = Math.sqrt(c.sum { |x| x * x })
      return false if (norm - 1.0).abs > ORTHONORMAL_TOLERANCE
    end
    [ [ 0, 1 ], [ 0, 2 ], [ 1, 2 ] ].each do |i, j|
      dot = cols[i].zip(cols[j]).sum { |a, b| a * b }
      return false if dot.abs > ORTHONORMAL_TOLERANCE
    end
    true
  end

  # Translation is the row-major 4th column of rows 0..2: m[3], m[7], m[11].
  def translation_plausible?(m)
    t = [ m[3], m[7], m[11] ]
    Math.sqrt(t.sum { |x| x * x }) <= MAX_TRANSLATION_M
  end
end
