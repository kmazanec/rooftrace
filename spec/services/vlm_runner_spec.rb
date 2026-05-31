require "rails_helper"

RSpec.describe VlmRunner, type: :service do
  let(:logger)           { instance_double(ActiveSupport::Logger, warn: nil, info: nil) }
  let(:url_minter)       { class_double(ImageryUrlMinter) }
  let(:detector_factory) { class_double(FeatureDetector) }
  let(:detector)         { instance_double(FeatureDetector::OpenRouter) }

  subject(:runner) do
    described_class.new(detector_factory: detector_factory, url_minter: url_minter,
                        logger: logger)
  end

  let(:image_tile_ref) { "cache/some-job/tile.png" }
  let(:roof_polygon)   { { "type" => "Polygon", "coordinates" => [] } }
  let(:signed_url)     { "https://spaces.example.com/tile.png?signed=1" }

  before do
    allow(url_minter).to receive(:call).with(object_key: image_tile_ref).and_return(signed_url)
    allow(detector_factory).to receive(:build).and_return(detector)
  end

  # ---------------------------------------------------------------------------
  # add_warning thread safety
  # ---------------------------------------------------------------------------

  describe "#add_warning thread safety" do
    it "accepts concurrent appends from two threads without data loss" do
      appended = []
      latch = Mutex.new
      ready = ConditionVariable.new
      started_count = 0

      # Spawn two threads; each waits for the other to be ready, then appends.
      threads = 2.times.map do |i|
        Thread.new do
          latch.synchronize do
            started_count += 1
            ready.broadcast if started_count == 2
            ready.wait(latch) until started_count == 2
          end
          runner.add_warning("warning_#{i}")
        end
      end

      threads.each(&:join)

      expect(runner.warnings).to include("warning_0", "warning_1")
      expect(runner.warnings.size).to eq(2)
    end
  end

  # ---------------------------------------------------------------------------
  # cleanup
  # ---------------------------------------------------------------------------

  describe "#cleanup" do
    context "when no thread was started (nil thread)" do
      it "is a no-op (does not raise)" do
        expect { runner.cleanup(job_id: "some-id") }.not_to raise_error
      end
    end

    context "when the thread was already joined (happy path)" do
      it "is a no-op after join clears the held thread" do
        allow(detector).to receive(:detect).and_return([])

        runner.start(image_tile_ref: image_tile_ref, roof_polygon: roof_polygon)
        runner.join

        # After join, @thread is nil; cleanup must not raise.
        expect { runner.cleanup(job_id: "some-id") }.not_to raise_error
      end
    end

    context "when the thread is still in flight" do
      it "kills the thread and does not leave it alive" do
        latch = Queue.new

        allow(detector).to receive(:detect) do
          latch.pop  # blocks until the test releases it
          []
        end

        runner.start(image_tile_ref: image_tile_ref, roof_polygon: roof_polygon)

        # Let the thread actually start before cleanup.
        sleep 0.01 until runner.instance_variable_get(:@thread)&.alive?

        runner.cleanup(job_id: "some-id")

        # Unblock the detector after cleanup so the thread can exit cleanly.
        latch << true

        # Allow the thread to finish unwinding.
        sleep 0.1

        thread = runner.instance_variable_get(:@thread)
        expect(thread).to be_nil  # cleanup cleared the reference
      end
    end
  end

  # ---------------------------------------------------------------------------
  # timeout path
  # ---------------------------------------------------------------------------

  describe "#join timeout" do
    it "returns [] and adds a vlm_failed warning when the thread times out" do
      # We stub VLM_JOIN_TIMEOUT_SECONDS to a very small value so the test
      # does not actually wait 60 s. We do this by overriding the constant
      # just for the running thread via a fast-completing stub.
      #
      # Strategy: make detector.detect block so join times out, but use a
      # tiny timeout. We test the timeout behaviour by making the thread never
      # finish and using a real Thread#join with a 0-second timeout (nil result).
      # Rather than sleeping 60 s, we stub the constant on the class.
      stub_const("VlmRunner::VLM_JOIN_TIMEOUT_SECONDS", 0)
      stub_const("VlmRunner::VLM_JOIN_GRACE_SECONDS", 0)

      blocker = Queue.new
      allow(detector).to receive(:detect) { blocker.pop; [] }

      runner.start(image_tile_ref: image_tile_ref, roof_polygon: roof_polygon)
      result = runner.join

      # Let the blocked thread clean up.
      blocker << true

      expect(result).to eq([])
      expect(runner.warnings).to include(a_string_matching(/vlm_failed.*timed out/))
    end
  end

  # ---------------------------------------------------------------------------
  # successful detection
  # ---------------------------------------------------------------------------

  describe "#start + #join (happy path)" do
    let(:features) do
      [ { "label" => "chimney", "bbox_norm" => [ 0.1, 0.2, 0.3, 0.4 ],
          "verified" => true, "source" => "imagery", "confidence" => 0.9 } ]
    end

    before do
      allow(detector).to receive(:detect).with(
        image_tile_url: signed_url, roof_polygon: roof_polygon
      ).and_return(features)
    end

    it "returns the detected features" do
      runner.start(image_tile_ref: image_tile_ref, roof_polygon: roof_polygon)
      result = runner.join
      expect(result).to eq(features)
    end

    it "adds no warnings on success" do
      runner.start(image_tile_ref: image_tile_ref, roof_polygon: roof_polygon)
      runner.join
      expect(runner.warnings).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # detector error captured (not raised to the caller)
  # ---------------------------------------------------------------------------

  describe "#start + #join (detector raises)" do
    before do
      allow(detector).to receive(:detect).and_raise(
        FeatureDetector::OpenRouter::VlmTimeout, "timeout from detector"
      )
    end

    it "returns [] without raising" do
      runner.start(image_tile_ref: image_tile_ref, roof_polygon: roof_polygon)
      result = nil
      expect { result = runner.join }.not_to raise_error
      expect(result).to eq([])
    end

    it "records a vlm_failed warning" do
      runner.start(image_tile_ref: image_tile_ref, roof_polygon: roof_polygon)
      runner.join
      expect(runner.warnings).to include(a_string_matching(/vlm_failed/))
    end
  end

  # ---------------------------------------------------------------------------
  # warnings snapshot
  # ---------------------------------------------------------------------------

  describe "#warnings" do
    it "returns a dup (modifying the return value does not affect the internal buffer)" do
      runner.add_warning("w1")
      snapshot = runner.warnings
      snapshot << "mutation"
      expect(runner.warnings).not_to include("mutation")
    end
  end
end
