class AddUniqueIndexToCapturesSequenceIndex < ActiveRecord::Migration[8.0]
  def change
    # A capture's sequence_index is the guided-walk-around prompt position; it
    # must be unique within its session. Two captures at the same index would
    # collide on the same upload key (photo_NN.jpg) and corrupt the session.
    add_index :captures, [ :capture_session_id, :sequence_index ],
              unique: true, name: "index_captures_on_session_and_sequence"
  end
end
