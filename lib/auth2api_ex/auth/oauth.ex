defmodule Auth2ApiEx.Auth.OAuth do
  @moduledoc """
  OAuth URL generation and token exchange for Claude OAuth.
  """

  alias Auth2ApiEx.Auth.TokenData
  alias Auth2ApiEx.Auth.Types

  # OAuth token端点有多个域名均可用：platform.claude.com / api.anthropic.com / claude.ai
  # console.anthropic.com 有Cloudflare拦截不推荐。此处用 platform.claude.com，与Claude Code官方CLI一致
  @auth_url "https://claude.ai/oauth/authorize"
  @token_url "https://platform.claude.com/v1/oauth/token"
  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @redirect_uri "https://platform.claude.com/oauth/code/callback"
  # 浏览器OAuth含 org:create_api_key；CookieAuth(API调用)不含，见 scope_api
  @scope "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
  @scope_api "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

  @spec token_url() :: String.t()
  def token_url, do: @token_url

  @spec client_id() :: String.t()
  def client_id, do: @client_id

  @spec redirect_uri() :: String.t()
  def redirect_uri, do: @redirect_uri

  @spec scope() :: String.t()
  def scope, do: @scope

  @spec scope_api() :: String.t()
  def scope_api, do: @scope_api

  @doc """
  Generate the authorization URL for Claude OAuth.
  """
  @spec generate_auth_url(String.t(), Types.pkce_codes()) :: String.t()
  def generate_auth_url(state, pkce) do
    params = %{
      "code" => "true",
      "client_id" => @client_id,
      "response_type" => "code",
      "redirect_uri" => @redirect_uri,
      "code_challenge" => pkce.code_challenge,
      "code_challenge_method" => "S256",
      "state" => state
    }

    # Anthropic's OAuth server expects unencoded colons in scope values
    scope_encoded =
      @scope
      |> String.split(" ")
      |> Enum.map(fn s ->
        URI.encode_www_form(s) |> String.replace("%3A", ":")
      end)
      |> Enum.join("+")

    query = URI.encode_query(params) <> "&scope=" <> scope_encoded
    "#{@auth_url}?#{query}"
  end

  @doc """
  Exchange authorization code for tokens.
  Validates state for CSRF protection.
  """
  @spec exchange_code_for_tokens(String.t(), String.t(), String.t(), Types.pkce_codes()) ::
          {:ok, TokenData.t()} | {:error, String.t()}
  def exchange_code_for_tokens(code, returned_state, expected_state, pkce) do
    if returned_state != expected_state do
      {:error, "OAuth state mismatch — possible CSRF attack"}
    else
      do_exchange(code, pkce, expected_state)
    end
  end

  @doc """
  Refresh OAuth tokens using a refresh token.
  """
  @spec refresh_tokens(String.t()) :: {:ok, TokenData.t()} | {:error, String.t()}
  def refresh_tokens(refresh_token) do
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
        {:ok, parse_token_response(data)}

      {:ok, %Req.Response{status: status, body: body}} ->
        text = if is_binary(body), do: body, else: Jason.encode!(body)
        {:error, "Token refresh failed (#{status}): #{text}"}

      {:error, exception} ->
        {:error, "Token refresh failed: #{Exception.message(exception)}"}
    end
  end

  @doc """
  Refresh tokens with retry logic.
  """
  @spec refresh_tokens_with_retry(String.t(), non_neg_integer()) ::
          {:ok, TokenData.t()} | {:error, String.t()}
  def refresh_tokens_with_retry(refresh_token, max_retries \\ 3) do
    do_refresh_with_retry(refresh_token, max_retries, 1)
  end

  defp do_refresh_with_retry(_refresh_token, max_retries, attempt) when attempt > max_retries do
    {:error, "Token refresh failed after #{max_retries} attempts"}
  end

  defp do_refresh_with_retry(refresh_token, max_retries, attempt) do
    case refresh_tokens(refresh_token) do
      {:ok, token} ->
        {:ok, token}

      {:error, _reason} when attempt < max_retries ->
        Process.sleep(attempt * 1000)
        do_refresh_with_retry(refresh_token, max_retries, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_exchange(code, pkce, state) do
    body =
      Jason.encode!(%{
        code: code,
        grant_type: "authorization_code",
        client_id: @client_id,
        redirect_uri: @redirect_uri,
        code_verifier: pkce.code_verifier,
        state: state
      })

    case Req.post(@token_url,
           headers: [{"content-type", "application/json"}],
           body: body
         ) do
      {:ok, %Req.Response{status: 200, body: data}} ->
        {:ok, parse_token_response(data)}

      {:ok, %Req.Response{status: status, body: body}} ->
        text = if is_binary(body), do: body, else: Jason.encode!(body)
        {:error, "Token exchange failed (#{status}): #{text}"}

      {:error, exception} ->
        {:error, "Token exchange failed: #{Exception.message(exception)}"}
    end
  end

  defp parse_token_response(data) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(data["expires_in"], :second)
      |> DateTime.to_iso8601()

    %TokenData{
      access_token: data["access_token"],
      refresh_token: data["refresh_token"],
      email: get_in(data, ["account", "email_address"]) || "unknown",
      expires_at: expires_at,
      account_uuid: get_in(data, ["account", "uuid"]) || ""
    }
  end
end
