defmodule Auth2ApiEx.Auth.CookieAuth do
  @moduledoc """
  Creates Claude OAuth tokens from a claude.ai sessionKey cookie.
  """

  alias Auth2ApiEx.Auth.{OAuth, PKCE, TokenData}

  @organizations_url "https://claude.ai/api/organizations"
  @claude_base_url "https://claude.ai"

  @spec authorize(String.t(), keyword()) :: {:ok, TokenData.t()} | {:error, String.t()}
  def authorize(session_key, opts \\ []) when is_binary(session_key) do
    http_client =
      Keyword.get(
        opts,
        :http_client,
        Application.get_env(:auth2api_ex, :http_client, Auth2ApiEx.Auth.ReqHttpClient)
      )

    pkce = PKCE.generate_pkce_codes()
    state = UUID.uuid4()

    with {:ok, org_uuid} <- get_organization_uuid(session_key, http_client),
         {:ok, code} <- get_authorization_code(session_key, org_uuid, state, pkce, http_client),
         {:ok, token} <- exchange_code(code, state, pkce, http_client) do
      {:ok, token}
    end
  end

  defp get_organization_uuid(session_key, http_client) do
    case http_client.get(@organizations_url, headers: session_headers(session_key)) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        case select_org_uuid(body) do
          nil -> {:error, "organizations request returned no organizations"}
          org_uuid -> {:ok, org_uuid}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, "organizations request failed (#{status}): #{format_body(body)}"}

      {:error, error} ->
        {:error, "organizations request failed: #{Exception.message(error)}"}
    end
  end

  defp get_authorization_code(session_key, org_uuid, state, pkce, http_client) do
    url = "#{@claude_base_url}/v1/oauth/#{org_uuid}/authorize"

    body =
      Jason.encode!(%{
        response_type: "code",
        client_id: OAuth.client_id(),
        organization_uuid: org_uuid,
        redirect_uri: OAuth.redirect_uri(),
        scope: OAuth.scope_api(),
        state: state,
        code_challenge: pkce.code_challenge,
        code_challenge_method: "S256"
      })

    headers = [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"origin", "https://claude.ai"},
      {"referer", "https://claude.ai/new"}
      | session_headers(session_key)
    ]

    case http_client.post(url, headers: headers, body: body) do
      {:ok, %{status: 302, headers: headers}} ->
        extract_code_from_headers(headers)

      {:ok, %{status: 200, body: %{"redirect_uri" => redirect_uri}}} ->
        extract_code_from_uri(redirect_uri)

      {:ok, %{status: status, body: body}} ->
        {:error, "authorization request failed (#{status}): #{format_body(body)}"}

      {:error, error} ->
        {:error, "authorization request failed: #{Exception.message(error)}"}
    end
  end

  defp exchange_code(code, state, pkce, http_client) do
    body =
      Jason.encode!(%{
        code: code,
        grant_type: "authorization_code",
        client_id: OAuth.client_id(),
        redirect_uri: OAuth.redirect_uri(),
        code_verifier: pkce.code_verifier,
        state: state
      })

    case http_client.post(OAuth.token_url(),
           headers: [{"content-type", "application/json"}],
           body: body
         ) do
      {:ok, %{status: 200, body: data}} when is_map(data) ->
        {:ok, parse_token_response(data)}

      {:ok, %{status: status, body: body}} ->
        {:error, "token exchange failed (#{status}): #{format_body(body)}"}

      {:error, error} ->
        {:error, "token exchange failed: #{Exception.message(error)}"}
    end
  end

  defp select_org_uuid(orgs) do
    case Enum.find(
           orgs,
           &(Map.get(&1, "raven_type") == "team" or
               Enum.member?(Map.get(&1, "capabilities", []), "team"))
         ) do
      nil -> orgs |> List.first() |> then(&(&1 && Map.get(&1, "uuid")))
      org -> Map.get(org, "uuid")
    end
  end

  defp extract_code_from_headers(headers) do
    headers
    |> Enum.find_value(fn
      {"location", value} -> value
      {"Location", value} -> value
      _ -> nil
    end)
    |> case do
      nil -> {:error, "authorization request returned no redirect location"}
      uri -> extract_code_from_uri(uri)
    end
  end

  defp extract_code_from_uri(uri) do
    params = uri |> URI.parse() |> Map.get(:query, "") |> URI.decode_query()

    case params["code"] do
      nil -> {:error, "authorization response contained no code"}
      code -> {:ok, code}
    end
  end

  defp parse_token_response(data) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(data["expires_in"] || 0, :second)
      |> DateTime.to_iso8601()

    %TokenData{
      access_token: data["access_token"] || "",
      refresh_token: data["refresh_token"] || "",
      email: get_in(data, ["account", "email_address"]) || "unknown",
      expires_at: expires_at,
      account_uuid: get_in(data, ["account", "uuid"]) || ""
    }
  end

  defp session_headers(session_key), do: [{"cookie", "sessionKey=#{session_key}"}]

  defp format_body(body) when is_binary(body), do: body
  defp format_body(body), do: Jason.encode!(body)
end
