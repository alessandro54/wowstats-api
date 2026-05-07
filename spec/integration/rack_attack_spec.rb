# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Rack::Attack", type: :request do
  describe "throttled_responder" do
    it "returns 429 without raising NoMethodError" do
      # Simulate what Rack::Attack passes to throttled_responder in v5+:
      # a Rack::Attack::Request object, not a plain env hash.
      env = Rack::MockRequest.env_for("/some/path", "REMOTE_ADDR" => "1.2.3.4")
      env["rack.attack.match_data"] = { period: 60, limit: 120, count: 121 }

      request = Rack::Attack::Request.new(env)

      expect {
        status, headers, _body = Rack::Attack.throttled_responder.call(request)
        expect(status).to eq(429)
        expect(headers["retry-after"]).to eq("60")
      }.not_to raise_error
    end

    it "handles missing match_data gracefully" do
      env = Rack::MockRequest.env_for("/some/path", "REMOTE_ADDR" => "1.2.3.4")
      request = Rack::Attack::Request.new(env)

      expect {
        status, _headers, _body = Rack::Attack.throttled_responder.call(request)
        expect(status).to eq(429)
      }.not_to raise_error
    end
  end
end
