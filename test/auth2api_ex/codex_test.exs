defmodule Auth2ApiEx.CodexTest do
  use ExUnit.Case, async: true

  alias Auth2ApiEx.Auth.CodexOAuth
  alias Auth2ApiEx.Utils.JWT

  # ══════════════════════════════════════════════════
  # Codex OAuth — URL generation
  # ══════════════════════════════════════════════════

  describe "generate_auth_url/2" do
    test "returns a valid codex authorization URL" do
      url =
        CodexOAuth.generate_auth_url("test-state", %{
          code_challenge: "challenge123",
          code_verifier: "verifier123"
        })

      assert String.starts_with?(url, "https://auth.openai.com/oauth/authorize")
      assert String.contains?(url, "client_id=")
      assert String.contains?(url, "code_challenge=challenge123")
      assert String.contains?(url, "code_challenge_method=S256")
      assert String.contains?(url, "state=test-state")
      assert String.contains?(url, "originator=codex_cli_rs")
      assert String.contains?(url, "codex_cli_simplified_flow=true")
    end
  end

  # ══════════════════════════════════════════════════
  # JWT — payload decoding
  # ══════════════════════════════════════════════════

  describe "JWT.decode_payload/1" do
    test "decodes a standard JWT payload" do
      # Valid JWT with known payload
      header =
        Base.encode64("{\"alg\":\"RS256\",\"typ\":\"JWT\"}", padding: false)
        |> String.replace("=", "")

      payload =
        Base.encode64("{\"sub\":\"user123\",\"email\":\"test@openai.com\"}", padding: false)
        |> String.replace("=", "")

      signature = "fake_signature"

      jwt = "#{header}.#{payload}.#{signature}"
      decoded = JWT.decode_payload(jwt)

      assert decoded["sub"] == "user123"
      assert decoded["email"] == "test@openai.com"
    end

    test "extracts chatgpt_account_id and plan_type from nested claims" do
      claims = %{
        "https://api.openai.com/auth" => %{
          "chatgpt_account_id" => "acct_abc123",
          "chatgpt_plan_type" => "plus"
        }
      }

      payload = Base.encode64(Jason.encode!(claims), padding: false) |> String.replace("=", "")
      header = Base.encode64("{}", padding: false) |> String.replace("=", "")
      jwt = "#{header}.#{payload}.sig"

      decoded = JWT.decode_payload(jwt)

      assert get_in(decoded, ["https://api.openai.com/auth", "chatgpt_account_id"]) ==
               "acct_abc123"

      assert get_in(decoded, ["https://api.openai.com/auth", "chatgpt_plan_type"]) == "plus"
    end

    test "handles JWT with padding correctly" do
      # Payload that would need padding when base64url decoded
      payload_base64url =
        Base.encode64("{\"a\":\"b\"}", padding: false) |> String.replace("=", "")

      header = Base.encode64("{}", padding: false) |> String.replace("=", "")
      jwt = "#{header}.#{payload_base64url}.sig"

      decoded = JWT.decode_payload(jwt)
      assert decoded["a"] == "b"
    end
  end

  # ══════════════════════════════════════════════════
  # Codex OAuth — identity extraction
  # ══════════════════════════════════════════════════

  describe "extract_identity/1" do
    test "extracts email, chatgpt_account_id, and plan_type from id_token claims" do
      claims = %{
        "email" => "user@gmail.com",
        "https://api.openai.com/auth" => %{
          "chatgpt_account_id" => "acct_xyz789",
          "chatgpt_plan_type" => "pro"
        }
      }

      identity = CodexOAuth.extract_identity(claims)

      assert identity.email == "user@gmail.com"
      assert identity.chatgpt_account_id == "acct_xyz789"
      assert identity.plan_type == "pro"
    end

    test "falls back to top-level claims when nested claims missing" do
      claims = %{
        "email" => "user@gmail.com",
        "chatgpt_account_id" => "acct_top",
        "chatgpt_plan_type" => "free"
      }

      identity = CodexOAuth.extract_identity(claims)

      assert identity.email == "user@gmail.com"
      assert identity.chatgpt_account_id == "acct_top"
      assert identity.plan_type == "free"
    end

    test "prefers nested claims over top-level" do
      claims = %{
        "email" => "user@gmail.com",
        "chatgpt_account_id" => "acct_wrong",
        "chatgpt_plan_type" => "free",
        "https://api.openai.com/auth" => %{
          "chatgpt_account_id" => "acct_correct",
          "chatgpt_plan_type" => "plus"
        }
      }

      identity = CodexOAuth.extract_identity(claims)

      assert identity.chatgpt_account_id == "acct_correct"
      assert identity.plan_type == "plus"
    end

    test "returns nil for missing fields" do
      claims = %{"email" => "user@gmail.com"}

      identity = CodexOAuth.extract_identity(claims)

      assert identity.email == "user@gmail.com"
      assert identity.chatgpt_account_id == nil
      assert identity.plan_type == nil
    end
  end

  # ══════════════════════════════════════════════════
  # Codex OAuth — token_from_response
  # ══════════════════════════════════════════════════

  describe "token_from_response/1" do
    test "parses a valid token response with id_token" do
      claims = %{
        "email" => "user@gmail.com",
        "https://api.openai.com/auth" => %{
          "chatgpt_account_id" => "acct_123",
          "chatgpt_plan_type" => "plus"
        }
      }

      id_token = build_id_token(claims)

      response = %{
        "access_token" => "codex_access_123",
        "refresh_token" => "codex_refresh_456",
        "expires_in" => 3600,
        "id_token" => id_token
      }

      token = CodexOAuth.token_from_response(response)

      assert token.access_token == "codex_access_123"
      assert token.refresh_token == "codex_refresh_456"
      assert token.provider == "codex"
      assert token.email == "user@gmail.com"
      assert token.chatgpt_account_id == "acct_123"
      assert token.plan_type == "plus"
      assert token.account_uuid == "acct_123"
      assert token.id_token == id_token
    end

    test "computes expires_at from expires_in" do
      id_token = build_id_token(%{"email" => "test@openai.com"})

      response = %{
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_in" => 7200,
        "id_token" => id_token
      }

      token = CodexOAuth.token_from_response(response)

      # expires_at should be in the future
      {:ok, dt, _} = DateTime.from_iso8601(token.expires_at)
      now = DateTime.utc_now()
      diff = DateTime.diff(dt, now)
      assert diff > 0 and diff <= 7200
    end
  end

  # ══════════════════════════════════════════════════
  # Codex Models — fallback list
  # ══════════════════════════════════════════════════

  describe "CodexModels" do
    test "get_fallback_models returns the static fallback list" do
      models = Auth2ApiEx.Upstream.CodexModels.get_fallback_models()

      assert is_list(models)
      assert length(models) >= 4
      assert "gpt-5.4" in models
      assert "gpt-5.2" in models

      Enum.each(models, fn model ->
        assert is_binary(model)
      end)
    end
  end

  # ── Helpers ──

  defp build_id_token(claims) do
    header =
      Base.encode64("{\"alg\":\"RS256\",\"typ\":\"JWT\"}", padding: false)
      |> String.replace("=", "")

    payload =
      claims |> Jason.encode!() |> Base.encode64(padding: false) |> String.replace("=", "")

    "#{header}.#{payload}.sig"
  end
end
