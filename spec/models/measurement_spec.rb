require "rails_helper"

RSpec.describe Measurement do
  it "belongs to a job" do
    job = create(:job)
    measurement = create(:measurement, job: job)
    expect(measurement.job).to eq(job)
  end

  it "requires a job" do
    measurement = build(:measurement, job: nil)
    expect(measurement).not_to be_valid
  end

  it "is valid from the factory" do
    expect(build(:measurement)).to be_valid
  end

  describe "NOT NULL columns with defaults" do
    it "defaults the jsonb collection columns at the database level" do
      job = create(:job)
      # Insert with only the NOT NULL non-defaulted columns set; the DB supplies
      # the [] / {} defaults for facets/features/provenance/warnings.
      measurement = described_class.create!(job: job, source: "imagery", confidence: 0.5)
      measurement.reload
      expect(measurement.facets).to eq([])
      expect(measurement.features).to eq([])
      expect(measurement.provenance).to eq({})
      expect(measurement.warnings).to eq([])
    end

    it "rejects a null source at the database level" do
      job = create(:job)
      measurement = build(:measurement, job: job, source: nil)
      expect { measurement.save!(validate: false) }
        .to raise_error(ActiveRecord::NotNullViolation)
    end

    it "rejects a null confidence at the database level" do
      job = create(:job)
      measurement = build(:measurement, job: job, confidence: nil)
      expect { measurement.save!(validate: false) }
        .to raise_error(ActiveRecord::NotNullViolation)
    end
  end
end
