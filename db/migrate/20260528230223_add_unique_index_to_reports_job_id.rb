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
  def change
    remove_index :reports, :job_id, name: "index_reports_on_job_id"
    add_index :reports, :job_id, unique: true, name: "index_reports_on_job_id"
  end
end
