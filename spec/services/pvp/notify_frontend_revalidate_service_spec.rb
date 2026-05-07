require "rails_helper"

RSpec.describe Pvp::NotifyFrontendRevalidateService, type: :service do
  subject(:result) { described_class.call }

  context "when FRONTEND_URL or REVALIDATE_SECRET is missing" do
    it "returns success without making an HTTP request" do
      stub_const("ENV", ENV.to_hash.merge("FRONTEND_URL" => nil, "REVALIDATE_SECRET" => nil))
      expect(HTTPX).not_to receive(:post)
      expect(result).to be_success
    end
  end

  context "when env vars are set" do
    before do
      stub_const("ENV", ENV.to_hash.merge(
        "FRONTEND_URL" => "https://www.wowstats.gg",
        "REVALIDATE_SECRET" => "test-secret"
      ))
    end

    it "POSTs to /api/revalidate with the secret header" do
      response = instance_double(HTTPX::Response, status: 200)
      expect(HTTPX).to receive(:post).once.with(
        "https://www.wowstats.gg/api/revalidate",
        headers: { "x-revalidate-secret" => "test-secret" }
      ).and_return(response)
      expect(result).to be_success
    end

    it "returns success even if the HTTP call raises" do
      allow(HTTPX).to receive(:post).and_raise(StandardError, "connection refused")
      expect(result).to be_success
    end
  end
end
