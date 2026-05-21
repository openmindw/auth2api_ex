defmodule Auth2ApiEx.Auth.TokenStorage do
  @moduledoc """
  Token file read/write operations.
  Stores OAuth tokens as JSON files in the auth directory.
  """

  require Logger

  alias Auth2ApiEx.Auth.TokenData

  @doc """
  Convert TokenData to storage format (snake_case JSON keys).
  """
  @spec token_to_storage(TokenData.t()) :: map()
  def token_to_storage(%TokenData{} = data) do
    storage = %{
      "access_token" => data.access_token,
      "refresh_token" => data.refresh_token,
      "last_refresh" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "email" => data.email,
      "type" => data.provider,
      "expired" => data.expires_at,
      "account_uuid" => data.account_uuid,
      "provider" => data.provider
    }

    if data.plan_type, do: Map.put(storage, "plan_type", data.plan_type), else: storage
    if data.id_token, do: Map.put(storage, "id_token", data.id_token), else: storage

    if data.chatgpt_account_id,
      do: Map.put(storage, "chatgpt_account_id", data.chatgpt_account_id),
      else: storage
  end

  @doc """
  Convert storage format to TokenData.
  """
  @spec storage_to_token(map()) :: TokenData.t()
  def storage_to_token(storage) do
    %TokenData{
      access_token: storage["access_token"],
      refresh_token: storage["refresh_token"],
      email: storage["email"],
      expires_at: storage["expired"],
      account_uuid: storage["account_uuid"] || "",
      provider: storage["provider"] || "anthropic",
      plan_type: storage["plan_type"],
      id_token: storage["id_token"],
      chatgpt_account_id: storage["chatgpt_account_id"]
    }
  end

  @doc """
  Save token data to a JSON file in the auth directory.
  File permissions: 0600, directory permissions: 0700.
  """
  @spec save_token(String.t(), TokenData.t()) :: :ok | {:error, any()}
  def save_token(auth_dir, %TokenData{} = data) do
    # Ensure directory exists with 0700 permissions
    File.mkdir_p!(auth_dir)
    :file.change_mode(String.to_charlist(auth_dir), 0o700)

    file_path = token_file_path(auth_dir, data)
    json = Jason.encode!(token_to_storage(data), pretty: true)

    File.write!(file_path, json)
    # Set file permissions to 0600 (owner read/write only)
    :file.change_mode(String.to_charlist(file_path), 0o600)
    :ok
  rescue
    e -> {:error, e}
  end

  @doc """
  Delete a token file by account email and optional provider.
  """
  @spec delete_token(String.t(), String.t(), String.t()) :: :ok | {:error, :not_found | any()}
  def delete_token(auth_dir, email, provider \\ "anthropic") do
    file_path = token_file_path(auth_dir, email, provider)

    case File.rm(file_path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Load all token files from the auth directory, optionally filtered by provider.
  Provider values: "anthropic" (matches claude-*.json), "codex" (matches codex-*.json),
  or any custom string for custom prefix matching.
  """
  @spec load_all_tokens(String.t(), String.t() | nil) :: [TokenData.t()]
  def load_all_tokens(auth_dir, provider \\ nil) do
    prefix = if provider, do: provider_prefix(provider), else: nil

    matcher =
      if prefix do
        fn f -> String.starts_with?(f, prefix) and String.ends_with?(f, ".json") end
      else
        fn f ->
          String.ends_with?(f, ".json") and
            (String.starts_with?(f, "claude-") or String.starts_with?(f, "codex-"))
        end
      end

    if File.dir?(auth_dir) do
      auth_dir
      |> File.ls!()
      |> Enum.filter(matcher)
      |> Enum.map(fn file ->
        file_path = Path.join(auth_dir, file)

        try do
          raw = File.read!(file_path)
          storage = Jason.decode!(raw)
          storage_to_token(storage)
        rescue
          _ ->
            Logger.error("Failed to load token file: #{file}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  @doc """
  Determine token file path based on email and optional provider.
  anthropic → claude-{sanitized_email}.json
  codex     → codex-{sanitized_email}.json
  """
  @spec token_file_path(String.t(), TokenData.t() | String.t(), String.t()) :: String.t()
  def token_file_path(auth_dir, %TokenData{} = data) do
    token_file_path(auth_dir, data.email, data.provider)
  end

  def token_file_path(auth_dir, email, provider \\ "anthropic") do
    sanitized =
      email
      |> String.replace(~r/[^a-zA-Z0-9@._-]/, "_")
      |> String.replace("..", "_")

    prefix = provider_prefix(provider)
    Path.join(auth_dir, "#{prefix}#{sanitized}.json")
  end

  defp provider_prefix("anthropic"), do: "claude-"
  defp provider_prefix("codex"), do: "codex-"
  defp provider_prefix(other), do: "#{other}-"

  defp provider_prefix(nil), do: "claude-"
end
