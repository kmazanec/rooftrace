class CreateProjectedOverlays < ActiveRecord::Migration[8.1]
  def change
    create_table :projected_overlays, id: :uuid do |t|
      # One overlay per capture (the photo it was projected onto): the unique
      # index makes the projection job's per-photo upsert idempotent.
      t.references :capture, type: :uuid, null: false,
                   foreign_key: true, index: { unique: true }

      # Spaces artifacts/<job_id>/projected/ object keys for the rendered
      # composite (photo + overlay) and the vector (SVG) overlay.
      t.string :composite_ref
      t.string :overlay_svg_ref

      # Confidence in the camera pose used to project this overlay (surfaced
      # verbatim per the honest-uncertainty rule) and a derived flag the surfaces
      # use to dim a low-confidence overlay.
      t.float :pose_confidence
      t.boolean :low_pose_confidence, null: false, default: false

      # facet_ids fully behind a nearer surface in the z-buffer (not visible).
      t.jsonb :occluded_facet_ids, null: false, default: []

      t.timestamps
    end
  end
end
