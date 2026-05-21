defmodule Auth2ApiEx.Utils.Common do
  @moduledoc """
  Common utility functions: API key extraction, hashing, device ID, timeout.
  """

  @doc """
  Extract API key from request headers.
  Prefers Authorization: Bearer over x-api-key.
  """
  @spec extract_api_key(Plug.Conn.t()) :: String.t()
  def extract_api_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key | _] ->
        key

      ["bearer " <> key | _] ->
        key

      _ ->
        case get_req_header(conn, "x-api-key") do
          [key | _] when is_binary(key) -> key
          _ -> ""
        end
    end
  end

  defp get_req_header(conn, header) do
    Plug.Conn.get_req_header(conn, String.downcase(header))
  end

  @doc """
  Hash an API key using SHA-256.
  """
  @spec hash_api_key(String.t()) :: String.t()
  def hash_api_key(api_key) do
    :crypto.hash(:sha256, api_key)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Get or create a persistent device ID for an account.
  Stored in ~/.auth2api_ex/.device_id_{sha256(email)[:12]}.
  """
  @spec get_device_id(String.t(), String.t()) :: String.t()
  def get_device_id(auth_dir, email) do
    suffix =
      :crypto.hash(:sha256, email)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)

    file_path = Path.join(auth_dir, ".device_id_#{suffix}")

    case File.read(file_path) do
      {:ok, stored} ->
        stored = String.trim(stored)

        if Regex.match?(~r/^[a-f0-9]{64}$/, stored) do
          stored
        else
          generate_and_save_device_id(auth_dir, file_path)
        end

      _ ->
        generate_and_save_device_id(auth_dir, file_path)
    end
  end

  defp generate_and_save_device_id(auth_dir, file_path) do
    id = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    File.mkdir_p!(auth_dir)
    File.write!(file_path, id)
    :file.change_mode(String.to_charlist(file_path), 0o600)
    id
  end
end
