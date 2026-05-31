require "rails_helper"

RSpec.describe PitchMath, type: :service do
  describe ".degrees" do
    context "with a standard 6/12 pitch" do
      it "returns approximately 26.6 at the default precision of 1" do
        result = described_class.degrees(6)
        expect(result).to be_within(0.05).of(26.6)
        expect(result).to eq(26.6)
      end

      it "returns approximately 26.57 at precision 2" do
        result = described_class.degrees(6, precision: 2)
        expect(result).to be_within(0.005).of(26.57)
        expect(result).to eq(26.57)
      end
    end

    context "with a 4/12 pitch" do
      it "returns approximately 18.4 at precision 1" do
        # atan(4/12) * (180/PI) ≈ 18.435
        result = described_class.degrees(4, precision: 1)
        expect(result).to be_within(0.05).of(18.4)
      end
    end

    context "with a 12/12 pitch (45 degrees)" do
      it "returns 45.0" do
        result = described_class.degrees(12, precision: 1)
        expect(result).to eq(45.0)
      end
    end

    context "precision argument" do
      it "rounds to 0 decimal places when precision is 0" do
        result = described_class.degrees(6, precision: 0)
        expect(result).to eq(27)
      end

      it "rounds to 3 decimal places when precision is 3" do
        result = described_class.degrees(6, precision: 3)
        # atan(6/12) * (180/PI) = 26.565…
        expect(result).to be_within(0.0005).of(26.565)
      end
    end

    context "nil input" do
      it "returns nil for a nil ratio" do
        expect(described_class.degrees(nil)).to be_nil
      end
    end

    context "zero input" do
      it "returns nil for a zero ratio (no meaningful angle)" do
        expect(described_class.degrees(0)).to be_nil
      end
    end

    context "negative input" do
      it "returns nil for a negative ratio" do
        expect(described_class.degrees(-3)).to be_nil
      end
    end

    context "return type" do
      it "returns a Float for a positive ratio" do
        expect(described_class.degrees(6)).to be_a(Float)
      end
    end
  end
end
