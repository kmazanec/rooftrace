class AddUniqueIndexToReportsJobId < ActiveRecord::Migration[8.1]
  # One Report per Job. Both create sites (the orchestrator on :ready and the
  # contractor viewer) call Report.find_or_create_by!(job:), which is
  # SELECT-then-INSERT and therefore racy under concurrent requests (double
  # click, two tabs, contractor hitting /report while the orchestrator
  # finalizes). The unique index is the backing safeguard: the losing INSERT
  # raises RecordNotUnique, find_or_create_by! rescues it and re-runs the find,
  # so callers converge on the single row instead of minting two share tokens.
  #
  # job_id is nullable (Report belongs_to :job, optional); Postgres treats
  # multiple NULLs as distinct, so reports with no job are unaffected.
  #
  # PRE-EXISTING DUPLICATES: the prior schema's index was NON-unique and both
  # create sites were SELECT-then-INSERT, so an environment can already hold >1
  # report for the same job_id. Adding the unique index against that state aborts
  # the deploy. So we deduplicate first — deterministically keep the OLDEST
  # report per non-null job_id (lowest created_at, id as a stable tiebreak) and
  # delete the rest. Share tokens are opaque and equivalent per job, so dropping
  # the younger duplicates loses nothing a consumer can depend on. Reversible
  # only in the index direction (the deleted rows are gone), hence up/down.
  def up
    say_with_time "deduplicating reports by job_id (keeping the oldest per job)" do
      execute(<<~SQL)
        DELETE FROM reports r
        USING reports keep
        WHERE r.job_id IS NOT NULL
          AND r.job_id = keep.job_id
          AND (keep.created_at, keep.id) < (r.created_at, r.id);
      SQL
    end
    remove_index :reports, :job_id, name: "index_reports_on_job_id"
    add_index :reports, :job_id, unique: true, name: "index_reports_on_job_id"
  end

  def down
    remove_index :reports, :job_id, name: "index_reports_on_job_id"
    add_index :reports, :job_id, name: "index_reports_on_job_id"
  end
end
