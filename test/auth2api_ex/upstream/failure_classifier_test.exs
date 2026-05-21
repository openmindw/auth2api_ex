defmodule Auth2ApiEx.Upstream.FailureClassifierTest do
  use ExUnit.Case, async: true
  alias Auth2ApiEx.Upstream.FailureClassifier

  describe "classify/2 — successful responses" do
    test "returns :ok for 200" do
      assert FailureClassifier.classify(200, nil) == :ok
    end

    test "returns :ok for 201-299" do
      assert FailureClassifier.classify(201, nil) == :ok
      assert FailureClassifier.classify(299, nil) == :ok
    end
  end

  describe "classify/2 — 401 auth errors" do
    test "returns :auth for 401 regardless of body" do
      assert FailureClassifier.classify(401, nil) == :auth
      assert FailureClassifier.classify(401, %{"error" => "invalid"}) == :auth
      assert FailureClassifier.classify(401, "Unauthorized") == :auth
    end
  end

  describe "classify/2 — 403 forbidden/quota" do
    test "returns :quota_exhausted when body contains 'quota'" do
      assert FailureClassifier.classify(403, %{"error" => "quota exceeded"}) == :quota_exhausted
    end

    test "returns :quota_exhausted when body contains 'usage limit'" do
      assert FailureClassifier.classify(403, %{"message" => "usage limit reached"}) ==
               :quota_exhausted
    end

    test "returns :forbidden for 403 without quota keywords" do
      assert FailureClassifier.classify(403, %{"error" => "access denied"}) == :forbidden
      assert FailureClassifier.classify(403, nil) == :forbidden
    end

    test "quota check is case-insensitive" do
      assert FailureClassifier.classify(403, %{"error" => "QUOTA EXCEEDED"}) == :quota_exhausted
    end
  end

  describe "classify/2 — 429 rate_limit/quota" do
    test "returns :quota_exhausted when body contains 'quota'" do
      assert FailureClassifier.classify(429, %{"error" => "quota exceeded"}) == :quota_exhausted
    end

    test "returns :quota_exhausted when body contains 'limit_exceeded'" do
      assert FailureClassifier.classify(429, %{"error" => "limit_exceeded"}) == :quota_exhausted
    end

    test "returns :rate_limit for 429 without quota keywords" do
      assert FailureClassifier.classify(429, %{"error" => "too many requests"}) == :rate_limit
      assert FailureClassifier.classify(429, nil) == :rate_limit
    end
  end

  describe "classify/3 — provider quota headers" do
    test "returns :quota_exhausted for Anthropic surpassed-threshold headers" do
      headers = [{"anthropic-ratelimit-unified-5h-surpassed-threshold", "true"}]

      assert FailureClassifier.classify(429, headers, %{"error" => "too many requests"}) ==
               :quota_exhausted
    end

    test "returns :quota_exhausted for Codex used-percent headers at 100" do
      headers = [{"x-codex-primary-used-percent", "100"}]

      assert FailureClassifier.classify(429, headers, %{"error" => "too many requests"}) ==
               :quota_exhausted
    end
  end

  describe "classify/2 — 408 / server errors" do
    test "returns :server for 408" do
      assert FailureClassifier.classify(408, nil) == :server
    end

    test "returns :server for 500-599" do
      assert FailureClassifier.classify(500, nil) == :server
      assert FailureClassifier.classify(502, nil) == :server
      assert FailureClassifier.classify(503, nil) == :server
      assert FailureClassifier.classify(504, nil) == :server
    end
  end

  describe "classify/2 — client errors (no cooldown)" do
    test "returns :ok for 400" do
      assert FailureClassifier.classify(400, %{"error" => "bad request"}) == :ok
    end

    test "returns :ok for 404" do
      assert FailureClassifier.classify(404, nil) == :ok
    end

    test "returns :ok for 422" do
      assert FailureClassifier.classify(422, nil) == :ok
    end
  end

  describe "classify/2 — binary body" do
    test "works with raw binary body" do
      assert FailureClassifier.classify(429, ~s({"error":"quota exceeded"})) == :quota_exhausted
      assert FailureClassifier.classify(403, "forbidden access") == :forbidden
    end
  end
end
