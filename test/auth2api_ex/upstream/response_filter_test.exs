defmodule Auth2ApiEx.Upstream.ResponseFilterTest do
  use ExUnit.Case, async: true
  alias Auth2ApiEx.Upstream.ResponseFilter

  describe "sanitize_headers/1 — strips sensitive headers" do
    test "drops cf-* headers" do
      headers = [
        {"cf-ray", "abc"},
        {"cf-cache-status", "HIT"},
        {"content-type", "application/json"}
      ]

      result = ResponseFilter.sanitize_headers(headers)
      assert result == [{"content-type", "application/json"}]
    end

    test "drops set-cookie and server headers" do
      headers = [
        {"set-cookie", "session=abc"},
        {"server", "cloudflare"},
        {"content-type", "text/html"}
      ]

      result = ResponseFilter.sanitize_headers(headers)
      assert result == [{"content-type", "text/html"}]
    end

    test "drops x-ratelimit-* and anthropic-ratelimit-*" do
      headers = [
        {"x-ratelimit-remaining", "0"},
        {"x-ratelimit-reset", "60"},
        {"anthropic-ratelimit-unified-5h-utilization", "0.5"},
        {"content-length", "100"}
      ]

      result = ResponseFilter.sanitize_headers(headers)
      assert result == [{"content-length", "100"}]
    end

    test "drops openai-* headers" do
      headers = [
        {"openai-organization", "org-123"},
        {"openai-version", "v1"},
        {"content-encoding", "gzip"}
      ]

      result = ResponseFilter.sanitize_headers(headers)
      assert result == [{"content-encoding", "gzip"}]
    end

    test "case-insensitive matching" do
      headers = [
        {"CF-RAY", "abc"},
        {"Set-Cookie", "x=1"},
        {"Content-Type", "application/json"}
      ]

      result = ResponseFilter.sanitize_headers(headers)
      assert result == [{"Content-Type", "application/json"}]
    end
  end

  describe "sanitize_headers/1 — preserves safe headers" do
    test "preserves content-type, content-length, content-encoding" do
      headers = [
        {"content-type", "application/json"},
        {"content-length", "42"},
        {"content-encoding", "gzip"},
        {"transfer-encoding", "chunked"},
        {"cache-control", "no-cache"}
      ]

      result = ResponseFilter.sanitize_headers(headers)
      assert length(result) == 5
    end

    test "preserves auth2api_ex-* custom headers" do
      headers = [
        {"auth2api_ex-request-id", "req-123"},
        {"auth2api_ex-session", "sess-abc"},
        {"content-type", "application/json"}
      ]

      result = ResponseFilter.sanitize_headers(headers)
      assert {"auth2api_ex-request-id", "req-123"} in result
      assert {"auth2api_ex-session", "sess-abc"} in result
    end
  end

  describe "sanitize_headers/1 — edge cases" do
    test "returns empty list for empty input" do
      assert ResponseFilter.sanitize_headers([]) == []
    end

    test "handles nil/non-list input" do
      assert ResponseFilter.sanitize_headers(nil) == []
    end
  end
end
