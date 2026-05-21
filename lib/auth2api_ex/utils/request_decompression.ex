defmodule Auth2ApiEx.Utils.RequestDecompression do
  @moduledoc """
  Plug that decompresses incoming request bodies based on `Content-Encoding`.

  Supported encodings: zstd, gzip, x-gzip.
  Decompressed body is limited to 64 MB to prevent decompression-bomb attacks.

  Skips multipart/form-data requests — Plug.Parsers.MULTIPART needs the raw
  undecoded body for boundary parsing.
  """

  @behaviour Plug

  @max_decompressed_size 64 * 1024 * 1024

  @doc """
  Plug callback. If `Content-Encoding` is set and the body is compressed,
  decompresses it and replaces `conn.private[:raw_body]` so downstream
  `Plug.Parsers` reads the decompressed data.

  On unsupported encoding or decompression error, halts with 400.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    content_type = get_content_type(conn)

    if content_type && String.starts_with?(content_type, "multipart/form-data") do
      conn
    else
      encoding = get_content_encoding(conn)

      case encoding do
        nil ->
          conn

        "" ->
          conn

        "zstd" ->
          decompress(conn, fn data ->
            case :ezstd.decompress(data) do
              {:error, reason} -> {:error, reason}
              result when is_binary(result) -> {:ok, result}
            end
          end)

        "gzip" ->
          decompress(conn, fn data ->
            try do
              {:ok, :zlib.gunzip(data)}
            rescue
              _ -> {:error, :invalid_gzip}
            end
          end)

        "x-gzip" ->
          decompress(conn, fn data ->
            try do
              {:ok, :zlib.gunzip(data)}
            rescue
              _ -> {:error, :invalid_gzip}
            end
          end)

        _ ->
          conn
          |> Plug.Conn.send_resp(
            400,
            Jason.encode!(%{error: %{message: "Unsupported Content-Encoding: #{encoding}"}})
          )
          |> Plug.Conn.halt()
      end
    end
  end

  def init(opts), do: opts

  defp get_content_type(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [val | _] -> String.trim(String.downcase(val))
      _ -> nil
    end
  end

  defp get_content_encoding(conn) do
    case Plug.Conn.get_req_header(conn, "content-encoding") do
      [val | _] -> String.trim(String.downcase(val))
      _ -> nil
    end
  end

  defp decompress(conn, decompress_fn) do
    case Plug.Conn.read_body(conn) do
      {:ok, "", _conn} ->
        conn

      {:ok, compressed, conn} ->
        case decompress_fn.(compressed) do
          {:ok, decompressed} when byte_size(decompressed) <= @max_decompressed_size ->
            conn
            |> Plug.Conn.assign(:decompressed_body, decompressed)
            |> Plug.Conn.put_private(:raw_body, decompressed)

          {:ok, _too_large} ->
            conn
            |> Plug.Conn.send_resp(
              400,
              Jason.encode!(%{error: %{message: "Decompressed body too large"}})
            )
            |> Plug.Conn.halt()

          {:error, _reason} ->
            conn
            |> Plug.Conn.send_resp(
              400,
              Jason.encode!(%{error: %{message: "Failed to decompress request body"}})
            )
            |> Plug.Conn.halt()
        end

      {:error, _reason} ->
        conn
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{error: %{message: "Failed to read request body"}})
        )
        |> Plug.Conn.halt()
    end
  end
end
