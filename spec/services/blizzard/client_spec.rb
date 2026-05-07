# spec/services/blizzard/client_spec.rb
require "rails_helper"

RSpec.describe Blizzard::Client do
  let(:auth_double) { instance_double("Blizzard::Auth", access_token: "fake-token", client_id: "test_client_id", invalidate!: nil) }

  describe "#initialize" do
    it "sets region, locale and auth for valid values" do
      client = described_class.new(region: "us", locale: "en_US", auth: auth_double)

      expect(client.region).to eq("us")
      expect(client.locale).to eq("en_US")
      expect(client.auth).to eq(auth_double)
    end

    it "raises an error for unsupported region" do
      expect {
        described_class.new(region: "cn", locale: "en_US", auth: auth_double)
      }.to raise_error(ArgumentError, "Unsupported Blizzard API region: cn")
    end

    it "raises an error for invalid locale for a given region" do
      expect {
        described_class.new(region: "us", locale: "es_ES", auth: auth_double)
      }.to raise_error(ArgumentError, "Invalid locale 'es_ES' for region 'us'")
    end
  end

  describe "#get" do
    let(:region) { "us" }
    let(:locale) { "en_US" }
    let(:client) { described_class.new(region: region, locale: locale, auth: auth_double) }

    let(:path) { "/data/wow/pvp-season/37/pvp-leaderboard/3v3" }
    let(:namespace) { "dynamic-us" }
    let(:extra_params) { { "page" => 2 } }

    it "builds the correct URL, query params and headers, and parses a successful JSON response" do
      response_body = { "ok" => true, "data" => [ 1, 2, 3 ] }.to_json
      response_double = instance_double(
        "HTTPX::Response",
        status: 200,
        body:   double("body", to_s: response_body)
      )

      expected_url = "https://us.api.blizzard.com#{path}"
      expected_query = {
        namespace: namespace,
        locale:    locale
      }.merge(extra_params)

      # Stub the shared HTTP_CLIENT constant
      allow(Blizzard::Client::HTTP_CLIENT).to receive(:get).with(
        expected_url,
        params:  expected_query,
        headers: { Authorization: "Bearer fake-token" }
      ).and_return(response_double)

      result = client.get(path, namespace: namespace, params: extra_params)

      expect(result).to eq(JSON.parse(response_body))
    end

    it "raises Blizzard::Client::Error when status is not 200" do
      response_double = instance_double(
        "HTTPX::Response",
        status: 404,
        body:   double("body", to_s: "Not Found")
      )

      allow(Blizzard::Client::HTTP_CLIENT).to receive(:get).and_return(response_double)

      expect {
        client.get(path, namespace: namespace)
      }.to raise_error(
             Blizzard::Client::Error,
             /Blizzard API error: HTTP 404, body=Not Found/
           )
    end

    it "raises Blizzard::Client::Error when response body is invalid JSON" do
      response_double = instance_double(
        "HTTPX::Response",
        status: 200,
        body:   double("body", to_s: "this is not json")
      )

      allow(Blizzard::Client::HTTP_CLIENT).to receive(:get).and_return(response_double)

      expect {
        client.get(path, namespace: namespace)
      }.to raise_error(
             Blizzard::Client::Error,
             /Blizzard API error: invalid JSON:/
           )
    end
  end

  describe "401 token rotation" do
    let(:region)  { "us" }
    let(:locale)  { "en_US" }
    let(:client)  { described_class.new(region: region, locale: locale, auth: auth_double) }
    let(:path)    { "/data/wow/pvp-season/37/pvp-leaderboard/3v3" }
    let(:namespace) { "dynamic-us" }

    let(:unauthorized_response) do
      instance_double("HTTPX::Response", status: 401, body: double("body", to_s: "Unauthorized"))
    end
    let(:ok_response) do
      instance_double("HTTPX::Response", status: 200, body: double("body", to_s: '{"ok":true}'))
    end

    it "invalidates the token and retries once on 401, succeeding on the second attempt" do
      allow(Blizzard::Client::HTTP_CLIENT).to receive(:get)
        .and_return(unauthorized_response, ok_response)

      result = client.get(path, namespace: namespace)

      expect(auth_double).to have_received(:invalidate!).once
      expect(result).to eq({ "ok" => true })
    end

    it "raises UnauthorizedError if the retry also returns 401" do
      allow(Blizzard::Client::HTTP_CLIENT).to receive(:get).and_return(unauthorized_response)

      expect {
        client.get(path, namespace: namespace)
      }.to raise_error(Blizzard::Client::UnauthorizedError)

      expect(auth_double).to have_received(:invalidate!).once
    end
  end

  describe "rate limiter scoping" do
    after { Blizzard::RateLimiter.reset! }

    it "uses separate buckets per region for the same credential" do
      us_client = described_class.new(region: "us", locale: "en_US", auth: auth_double)
      eu_client = described_class.new(region: "eu", locale: "en_GB", auth: auth_double)

      us_limiter = us_client.send(:rate_limiter)
      eu_limiter = eu_client.send(:rate_limiter)

      expect(us_limiter).not_to be(eu_limiter)
    end

    it "shares a bucket for the same credential and region" do
      client_a = described_class.new(region: "us", locale: "en_US", auth: auth_double)
      client_b = described_class.new(region: "us", locale: "en_US", auth: auth_double)

      expect(client_a.send(:rate_limiter)).to be(client_b.send(:rate_limiter))
    end
  end

  describe "namespace helpers" do
    let(:client) { described_class.new(region: "eu", locale: "en_GB", auth: auth_double) }

    it "returns correct profile namespace" do
      expect(client.profile_namespace).to eq("profile-eu")
    end

    it "returns correct dynamic namespace" do
      expect(client.dynamic_namespace).to eq("dynamic-eu")
    end

    it "returns correct static namespace" do
      expect(client.static_namespace).to eq("static-eu")
    end
  end
end
