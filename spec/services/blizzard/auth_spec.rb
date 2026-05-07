# spec/services/blizzard/auth_spec.rb
require "rails_helper"

RSpec.describe Blizzard::Auth do
  include ActiveSupport::Testing::TimeHelpers

  # Reset the in-process token cache between examples so one test's cached
  # token doesn't bleed into the next (the cache is a class-level variable).
  before { described_class.reset_in_process_cache! }

  let(:client_id) { "test_client_id" }
  let(:client_secret) { "test_client_secret" }

  subject(:auth) do
    described_class.new(client_id:, client_secret:)
  end

  describe "#initialize" do
    context "when client_id or client_secret is missing" do
      it "raises an ArgumentError" do
        expect {
          described_class.new(client_id: nil, client_secret: nil)
        }.to raise_error(
               ArgumentError,
               "Blizzard client_id and client_secret must be provided. " \
                 "Set Rails credentials (blizzard.client_id / blizzard.client_secret) " \
                 "or ENV BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET. " \
                 "If using credentials in a worker process, ensure RAILS_MASTER_KEY is present."
             )

        expect {
          described_class.new(client_id: "", client_secret: client_secret)
        }.to raise_error(
               ArgumentError,
               "Blizzard client_id and client_secret must be provided. " \
                 "Set Rails credentials (blizzard.client_id / blizzard.client_secret) " \
                 "or ENV BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET. " \
                 "If using credentials in a worker process, ensure RAILS_MASTER_KEY is present."
             )

        expect {
          described_class.new(client_id: client_id, client_secret: nil)
        }.to raise_error(
               ArgumentError,
               "Blizzard client_id and client_secret must be provided. " \
                 "Set Rails credentials (blizzard.client_id / blizzard.client_secret) " \
                 "or ENV BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET. " \
                 "If using credentials in a worker process, ensure RAILS_MASTER_KEY is present."
             )
      end
    end
  end

  describe "#access_token" do
    let(:cache_key) { Blizzard::Auth.cache_key_for(client_id) }

    context "when there is a valid cached token" do
      let(:cached_token) { "cached-token" }
      let(:future_time)  { 10.minutes.from_now }

      before do
        allow(Rails.cache).to receive(:read).with(cache_key).and_return(
          {
            token:      cached_token,
            expires_at: future_time
          }
        )
      end

      it "returns the cached token and does not call HTTPX" do
        expect(HTTPX).not_to receive(:post)

        token = auth.access_token

        expect(token).to eq(cached_token)
      end
    end

    context "when there is no cached token" do
      let(:new_token)      { "new-access-token" }
      let(:expires_in_sec) { 3600 }

      let(:http_response) do
        instance_double(
          HTTPX::Response,
          status:  200,
          body:    {
            access_token: new_token,
            expires_in:   expires_in_sec
          }.to_json,
          headers: {},
          version: "1.1"
        )
      end

      let(:httpx_client) { instance_double(HTTPX::Session) }

      before do
        allow(Rails.cache).to receive(:read).with(cache_key).and_return(nil)

        # Stub HTTPX.with(...).post in a loose way; we'll assert args later
        allow(HTTPX).to receive(:with).and_return(httpx_client)
        allow(httpx_client).to receive(:post).and_return(http_response)

        allow(Rails.cache).to receive(:write)
      end

      it "performs the OAuth request and caches the token" do
        freeze_time do
          token = auth.access_token

          expect(token).to eq(new_token)

          expect(httpx_client).to have_received(:post).with(
            Blizzard::Auth::OAUTH_URL,
            hash_including(
              form:    { grant_type: "client_credentials" },
              headers: hash_including(Authorization: a_kind_of(String))
            )
          )

          expected_expires_at =
            Time.current + expires_in_sec - Blizzard::Auth::EXPIRY_SKEW_SECONDS

          expect(Rails.cache).to have_received(:write).with(
            cache_key,
            hash_including(
              token:      new_token,
              expires_at: expected_expires_at
            ),
            expires_in: expires_in_sec
          )
        end
      end
    end

    context "when cached token is expired" do
      let(:expired_token) { "expired-token" }
      let(:new_token)     { "fresh-token" }

      let(:http_response) do
        instance_double(
          HTTPX::Response,
          status:  200,
          body:    {
            access_token: new_token,
            expires_in:   1800
          }.to_json,
          headers: {},
          version: "1.1"
        )
      end

      before do
        allow(Rails.cache).to receive(:read).with(cache_key).and_return(
          {
            token:      expired_token,
            expires_at: 5.minutes.ago
          }
        )

        allow(HTTPX).to receive(:with).and_return(instance_double(HTTPX::Session, post: http_response))
        allow(Rails.cache).to receive(:write)
      end

      it "ignores expired token and fetches a new one" do
        token = auth.access_token

        expect(token).to eq(new_token)
      end
    end

    context "when the HTTP response is not success" do
      let(:http_response) do
        instance_double(
          HTTPX::Response,
          status:  401,
          body:    '{"error":"invalid_client"}',
          headers: {},
          version: "1.1"
        )
      end

      before do
        allow(Rails.cache).to receive(:read).with(cache_key).and_return(nil)
        allow(HTTPX).to receive(:with).and_return(instance_double(HTTPX::Session, post: http_response))
      end

      it "raises Blizzard::Auth::Error" do
        expect {
          auth.access_token
        }.to raise_error(Blizzard::Auth::Error, /Blizzard OAuth error/)
      end
    end

    context "when the response does not contain access_token" do
      let(:http_response) do
        instance_double(
          HTTPX::Response,
          status:  200,
          body:    { "expires_in" => 3600 }.to_json,
          headers: {},
          version: "1.1"
        )
      end

      before do
        allow(Rails.cache).to receive(:read).with(cache_key).and_return(nil)
        allow(HTTPX).to receive(:with).and_return(instance_double(HTTPX::Session, post: http_response))
      end

      it "raises Blizzard::Auth::Error" do
        expect {
          auth.access_token
        }.to raise_error(Blizzard::Auth::Error, /access_token/)
      end
    end
  end

  describe "#invalidate!" do
    let(:cache_key) { Blizzard::Auth.cache_key_for(client_id) }

    before do
      described_class.store_in_process(client_id, "some-token", 1.hour.from_now)
      allow(Rails.cache).to receive(:delete)
    end

    it "removes the in-process token" do
      auth.invalidate!
      expect(described_class.in_process_token(client_id)).to be_nil
    end

    it "deletes the Rails cache entry" do
      auth.invalidate!
      expect(Rails.cache).to have_received(:delete).with(cache_key)
    end
  end
end
