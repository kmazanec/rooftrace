require "rails_helper"

RSpec.describe Report do
  it "assigns an unguessable base58 share token on create (has_secure_token, 32 chars)" do
    expect(create(:report).share_token).to match(%r{\A[1-9A-HJ-NP-Za-km-z]{32}\z})
  end

  it "gives each report a distinct share token" do
    expect(create(:report).share_token).not_to eq(create(:report).share_token)
  end

  it "uses the share token as its URL param" do
    report = create(:report)
    expect(report.to_param).to eq(report.share_token)
  end

  describe "one report per job" do
    it "rejects a second report for the same job (validation)" do
      job = create(:job)
      create(:report, job: job)
      dup = build(:report, job: job)
      expect(dup).not_to be_valid
      expect(dup.errors[:job_id]).to be_present
    end

    it "enforces uniqueness at the DB level too (unique index)" do
      job = create(:job)
      create(:report, job: job)
      # Skip the model validation to prove the index itself is the safeguard
      # (the validation can race; the index cannot).
      dup = build(:report, job: job)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows multiple reports with no job (nil job_ids are distinct)" do
      create(:report, job: nil)
      expect { create(:report, job: nil) }.not_to raise_error
    end

    it "find_or_create_by!(job:) is idempotent" do
      job = create(:job)
      first = Report.find_or_create_by!(job: job)
      expect(Report.find_or_create_by!(job: job)).to eq(first)
      expect(Report.where(job: job).count).to eq(1)
    end
  end
end
