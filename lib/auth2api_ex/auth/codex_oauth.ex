defmodule Auth2ApiEx.Auth.CodexOAuth do
  @moduledoc """
  OAuth 2.0 flow for Codex (OpenAI ChatGPT) authentication.
  Matches the codex-rs CLI OAuth implementation.

  Constants verified against codex-rs/login/src/server.rs and
  codex-rs/login/src/auth/manager.rs.
  """

  alias Auth2ApiEx.Auth.TokenData
  alias Auth2ApiEx.Utils.JWT

  @issuer "https://auth.openai.com"
  @auth_url "#{@issuer}/oauth/authorize"
  @token_url "#{@issuer}/oauth/token"
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @redirect_uri "http://localhost:1455/auth/callback"
  @scope "openid profile email offline_access api.connectors.read api.connectors.invoke"
  @originator "codex_cli_rs"

  @doc """
  Generate the authorization URL for Codex OAuth.
  """
  @spec generate_auth_url(String.t(), map()) :: String.t()
  def generate_auth_url(state, pkce) do
    params = %{
      "response_type" => "code",
      "client_id" => @client_id,
      "redirect_uri" => @redirect_uri,
      "scope" => @scope,
      "code_challenge" => pkce.code_challenge,
      "code_challenge_method" => "S256",
      "id_token_add_organizations" => "true",
      "codex_cli_simplified_flow" => "true",
      "state" => state,
      "originator" => @originator
    }

    query = URI.encode_query(params)
    "#{@auth_url}?#{query}"
  end

  @doc """
  Parse a token response into TokenData.
  """
  @spec token_from_response(map()) :: TokenData.t()
  def token_from_response(data) do
    expires_in = Map.get(data, "expires_in", 3600)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(expires_in, :second)
      |> DateTime.to_iso8601()

    identity = extract_identity_from_token(data["id_token"])

    %TokenData{
      access_token: data["access_token"],
      refresh_token: data["refresh_token"],
      email: identity.email,
      expires_at: expires_at,
      account_uuid: identity.chatgpt_account_id || "",
      provider: "codex",
      plan_type: identity.plan_type,
      id_token: data["id_token"],
      chatgpt_account_id: identity.chatgpt_account_id
    }
  end

  @doc """
  Extract identity claims from an id_token JWT.
  Returns %{email, chatgpt_account_id, plan_type}.
  """
  @spec extract_identity(map()) :: %{
          email: String.t(),
          chatgpt_account_id: String.t() | nil,
          plan_type: String.t() | nil
        }
  def extract_identity(claims) when is_map(claims) do
    auth = Map.get(claims, "https://api.openai.com/auth", %{}) || %{}
    email = Map.get(claims, "email", "unknown")

    chatgpt_account_id =
      Map.get(auth, "chatgpt_account_id") || Map.get(claims, "chatgpt_account_id")

    plan_type = Map.get(auth, "chatgpt_plan_type") || Map.get(claims, "chatgpt_plan_type")

    %{email: email, chatgpt_account_id: chatgpt_account_id, plan_type: plan_type}
  end

  @spec extract_identity(String.t()) :: %{
          email: String.t(),
          chatgpt_account_id: String.t() | nil,
          plan_type: String.t() | nil
        }
  def extract_identity(id_token) when is_binary(id_token) do
    id_token
    |> JWT.decode_payload()
    |> extract_identity()
  end

  @doc """
  Exchange authorization code for tokens.
  Validates state for CSRF protection.
  """
  @spec exchange_code(String.t(), String.t(), String.t(), map()) ::
          {:ok, TokenData.t()} | {:error, String.t()}
  def exchange_code(code, returned_state, expected_state, pkce) do
    if returned_state != expected_state do
      {:error, "OAuth state mismatch — possible CSRF attack"}
    else
      do_exchange(code, pkce)
    end
  end

  @doc """
  Refresh tokens with retry logic (3 retries).
  """
  @spec refresh_tokens_with_retry(String.t(), non_neg_integer()) ::
          {:ok, TokenData.t()} | {:error, String.t()}
  def refresh_tokens_with_retry(refresh_token, max_retries \\ 3) do
    do_refresh_with_retry(refresh_token, max_retries, 1)
  end

  # ── Private ──

  defp extract_identity_from_token(nil),
    do: %{email: "unknown", chatgpt_account_id: nil, plan_type: nil}

  defp extract_identity_from_token(id_token) do
    id_token
    |> JWT.decode_payload()
    |> extract_identity()
  end

  defp do_exchange(code, pkce) do
    body =
      URI.encode_query(%{
        grant_type: "authorization_code",
        code: code,
        redirect_uri: @redirect_uri,
        client_id: @client_id,
        code_verifier: pkce.code_verifier
      })

    case Req.post(@token_url,
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           body: body
         ) do
      {:ok, %Req.Response{status: 200, body: data}} ->
        {:ok, token_from_response(data)}

      {:ok, %Req.Response{status: status, body: body}} ->
        text = if is_binary(body), do: body, else: Jason.encode!(body)
        {:error, "Codex token exchange failed (#{status}): #{text}"}

      {:error, exception} ->
        {:error, "Codex token exchange failed: #{Exception.message(exception)}"}
    end
  end

  defp refresh_tokens(refresh_token) do
    body =
      Jason.encode!(%{
        client_id: @client_id,
        grant_type: "refresh_token",
        refresh_token: refresh_token
      })

    case Req.post(@token_url,
           headers: [{"content-type", "application/json"}],
           body: body
         ) do
      {:ok, %Req.Response{status: 200, body: data}} ->
        {:ok, token_from_response(data)}

      {:ok, %Req.Response{status: status, body: body}} ->
        text = if is_binary(body), do: body, else: Jason.encode!(body)

        case Auth2ApiEx.Auth.RefreshErrors.classify(text) do
          reason when reason in [:refresh_token_reused, :expired, :invalidated] ->
            {:error, "Codex refresh token #{reason}"}

          _ ->
            {:error, "Codex token refresh failed (#{status}): #{text}"}
        end

      {:error, exception} ->
        {:error, "Codex token refresh failed: #{Exception.message(exception)}"}
    end
  end

  defp do_refresh_with_retry(_refresh_token, max_retries, attempt) when attempt > max_retries do
    {:error, "Codex token refresh failed after #{max_retries} attempts"}
  end

  defp do_refresh_with_retry(refresh_token, max_retries, attempt) do
    case refresh_tokens(refresh_token) do
      {:ok, token} ->
        {:ok, token}

      {:error, reason} when attempt < max_retries ->
        # Don't retry terminal failures
        if String.starts_with?(reason, "Codex refresh token") do
          {:error, reason}
        else
          Process.sleep(attempt * 1000)
          do_refresh_with_retry(refresh_token, max_retries, attempt + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
