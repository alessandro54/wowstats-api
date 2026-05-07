require "rails_helper"

RSpec.describe BatchOutcome do
  subject(:outcome) { described_class.new }

  describe "#record_success" do
    it "adds to the successes list" do
      outcome.record_success(id: 1, status: :applied_fresh_snapshot)

      expect(outcome.successes).to eq([ { id: 1, status: :applied_fresh_snapshot } ])
    end
  end

  describe "#record_failure" do
    it "adds to the failures list" do
      outcome.record_failure(id: 2, status: :api_error, error: "timeout")

      expect(outcome.failures).to eq([ { id: 2, status: :api_error, error: "timeout" } ])
    end
  end

  describe "#total" do
    it "returns the sum of successes and failures" do
      outcome.record_success(id: 1, status: :processed)
      outcome.record_success(id: 2, status: :processed)
      outcome.record_failure(id: 3, status: :failed, error: "err")

      expect(outcome.total).to eq(3)
    end

    it "returns 0 when empty" do
      expect(outcome.total).to eq(0)
    end
  end

  describe "#total_failure?" do
    it "returns true when all items failed" do
      outcome.record_failure(id: 1, status: :api_error, error: "timeout")
      outcome.record_failure(id: 2, status: :rate_limited, error: "429")

      expect(outcome.total_failure?).to be(true)
    end

    it "returns false when some items succeeded" do
      outcome.record_success(id: 1, status: :processed)
      outcome.record_failure(id: 2, status: :api_error, error: "timeout")

      expect(outcome.total_failure?).to be(false)
    end

    it "returns false when all items succeeded" do
      outcome.record_success(id: 1, status: :processed)

      expect(outcome.total_failure?).to be(false)
    end

    it "returns false when empty (no items processed)" do
      expect(outcome.total_failure?).to be(false)
    end
  end

  describe "#counts_by_status" do
    it "returns a hash of status counts across successes and failures" do
      outcome.record_success(id: 1, status: :applied_fresh_snapshot)
      outcome.record_success(id: 2, status: :applied_fresh_snapshot)
      outcome.record_success(id: 3, status: :reused_snapshot)
      outcome.record_failure(id: 4, status: :api_error, error: "timeout")
      outcome.record_failure(id: 5, status: :rate_limited, error: "429")
      outcome.record_failure(id: 6, status: :api_error, error: "500")

      expect(outcome.counts_by_status).to eq(
        applied_fresh_snapshot: 2,
        reused_snapshot:        1,
        api_error:              2,
        rate_limited:           1
      )
    end

    it "returns empty hash when no items recorded" do
      expect(outcome.counts_by_status).to eq({})
    end
  end

  describe "#summary_message" do
    it "returns a formatted summary string" do
      outcome.record_success(id: 1, status: :applied_fresh_snapshot)
      outcome.record_success(id: 2, status: :reused_snapshot)
      outcome.record_failure(id: 3, status: :api_error, error: "timeout")

      message = outcome.summary_message(job_label: "TestJob")

      expect(message).to include("[TestJob]")
      expect(message).to include("2/3 ok")
      expect(message).to include("failed=1")
      expect(message).to include("applied_fresh_snapshot=1")
      expect(message).to include("reused_snapshot=1")
      expect(message).to include("api_error=1")
    end

    it "includes cycle and region context when provided" do
      outcome.record_success(id: 1, status: :synced)

      message = outcome.summary_message(job_label: "TestJob", cycle_id: 42, region: "us")

      expect(message).to include("[cycle=42 region=us]")
    end

    it "includes failure details when failures exist" do
      outcome.record_success(id: 1, status: :processed)
      outcome.record_failure(id: 42, status: :api_error, error: "timeout")

      message = outcome.summary_message(job_label: "TestJob")

      expect(message).to include("char=42 err=timeout")
    end

    it "omits failure details when all items succeeded" do
      outcome.record_success(id: 1, status: :processed)

      message = outcome.summary_message(job_label: "TestJob")

      expect(message).not_to include("char=")
    end

    it "shows at most 5 failure samples and appends overflow count" do
      6.times { |i| outcome.record_failure(id: i, status: :api_error, error: "err#{i}") }

      message = outcome.summary_message(job_label: "TestJob")

      expect(message).to include("char=0 err=err0")
      expect(message).to include("char=4 err=err4")
      expect(message).not_to include("char=5")
      expect(message).to include("(+1 more)")
    end
  end

  describe "#raise_if_total_failure!" do
    it "raises TotalBatchFailureError when all items failed" do
      outcome.record_failure(id: 123, status: :rate_limited, error: "429")
      outcome.record_failure(id: 456, status: :api_error, error: "timeout")

      expect { outcome.raise_if_total_failure!(job_label: "TestJob") }
        .to raise_error(BatchOutcome::TotalBatchFailureError) do |error|
          expect(error.message).to include("[TestJob]")
          expect(error.message).to include("All 2 items failed")
          expect(error.message).to include("rate_limited: 1")
          expect(error.message).to include("api_error: 1")
          expect(error.message).to include("123: 429")
          expect(error.message).to include("456: timeout")
        end
    end

    it "does not raise when some items succeeded" do
      outcome.record_success(id: 1, status: :processed)
      outcome.record_failure(id: 2, status: :api_error, error: "timeout")

      expect { outcome.raise_if_total_failure!(job_label: "TestJob") }
        .not_to raise_error
    end

    it "does not raise when empty" do
      expect { outcome.raise_if_total_failure!(job_label: "TestJob") }
        .not_to raise_error
    end

    it "includes at most 3 samples in the error message" do
      4.times { |i| outcome.record_failure(id: i, status: :api_error, error: "err#{i}") }

      expect { outcome.raise_if_total_failure!(job_label: "TestJob") }
        .to raise_error(BatchOutcome::TotalBatchFailureError) do |error|
          expect(error.message).to include("0: err0")
          expect(error.message).to include("1: err1")
          expect(error.message).to include("2: err2")
          expect(error.message).not_to include("3: err3")
        end
    end
  end
end
