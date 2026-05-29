# ActionCable broadcast-sequence tests for the job status stream.
#
# The broadcast contract (C0.2):
#   Job#advance_to! and #fail_with! call broadcast_replace_to([job, :status], ...)
#   which emits to the stream identified by "#{job.to_gid_param}:status".
#   (turbo-rails 2.0.23 does NOT prefix with a channel name — verified by the
#   contract agent. Use the raw stream string, not .from_channel(...))
#
# The view subscribes via `turbo_stream_from(job, :status)`, which
# resolves to the same stream name.

require "rails_helper"

RSpec.describe "Job status broadcasts", type: :model do
  let(:job) { create(:job) }

  # Helper: the raw turbo stream name that advance_to!/fail_with! broadcasts to.
  def status_stream(job)
    "#{job.to_gid_param}:status"
  end

  describe "advance_to!" do
    it "broadcasts a Turbo Stream replace to the job's status stream" do
      expect {
        job.advance_to!(:resolving_address)
      }.to have_broadcasted_to(status_stream(job))
    end

    it "broadcasts through the expected sequence of statuses" do
      statuses = %i[resolving_address fetching_imagery fetching_lidar
                    refining_outline detecting_features fitting_planes ready]

      statuses.each do |status|
        expect {
          job.advance_to!(status)
        }.to have_broadcasted_to(status_stream(job))
      end
    end

    it "broadcasts HTML containing the status partial target id" do
      # Turbo broadcasts as a raw Turbo Stream HTML string; we check it
      # contains the correct target id rather than parsing the JSON wrapper.
      expect {
        job.advance_to!(:resolving_address)
      }.to have_broadcasted_to(status_stream(job))
        .with(including(ActionView::RecordIdentifier.dom_id(job, :status)))
    end
  end

  describe "fail_with!" do
    it "broadcasts a replace to the job's status stream when failed" do
      expect {
        job.fail_with!("Address could not be geocoded.")
      }.to have_broadcasted_to(status_stream(job))
    end

    it "broadcasts HTML containing the status partial target id" do
      expect {
        job.fail_with!("Something went wrong.")
      }.to have_broadcasted_to(status_stream(job))
        .with(including(ActionView::RecordIdentifier.dom_id(job, :status)))
    end
  end
end
