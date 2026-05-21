defmodule Auth2ApiEx.Upstream.CodexModels do
  @moduledoc """
  Codex model listing — mirrors Node.js `codex-provider-ref/upstream/codex-models.ts`.

  Behavior:
    - GET https://chatgpt.com/backend-api/codex/models?client_version=auth2api_ex/1.0.0
    - Sends Authorization, ChatGPT-Account-ID, Accept, User-Agent, and
      conditional If-None-Match (when an ETag is cached).
    - Caches the response with TTL (default 5 min) and ETag.
    - On 304 Not Modified: returns cached models.
    - On upstream failure: returns previously cached list (stale-while-error)
      or, if no cache yet, the static `@fallback_models`.
  """

  alias Auth2ApiEx.Accounts.Manager

  require Logger

  @base_url "https://chatgpt.com/backend-api"
  @models_path "/codex/models"
  @default_ttl_ms 5 * 60 * 1000
  @client_version "auth2api_ex/1.0.0"
  @cache_table :auth2api_ex_codex_models_cache
  @cache_key :__codex_models__

  @fallback_models [
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.3-codex",
    "gpt-5.2",
    "gpt-image-1",
    "gpt-image-2"
  ]

  @doc """
  Returns the static fallback model list (used when no upstream call is possible).
  """
  @spec get_fallback_models() :: [String.t()]
  def get_fallback_models, do: @fallback_models

  @doc """
  Reset the in-memory cache. Test hook.
  """
  def reset_cache do
    ensure_cache_table()
    :ets.delete(@cache_table, @cache_key)
    :ok
  end

  @doc """
  List Codex models. Pulls from upstream, with TTL + ETag caching and
  stale-while-error fallback.

  Options:
    - `:plug` — Req `:plug` test option (overrides the real HTTP client).
    - `:ttl_ms` — cache TTL in milliseconds. Default 5 minutes; set to `0`
      to bypass the freshness short-circuit (useful in tests).
  """
  @spec list_models(atom() | pid(), keyword()) ::
          {:ok, [%{id: String.t(), owned_by: String.t()}]}
  def list_models(manager \\ :codex_manager, opts \\ []) do
    ensure_cache_table()
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    now = System.system_time(:millisecond)

    cached = lookup_cache()

    cond do
      (ttl_ms > 0 and cached) && now - cached.fetched_at < ttl_ms ->
        {:ok, format_models(cached.models)}

      true ->
        case fetch_upstream(manager, cached, opts) do
          {:ok, %{models: models, etag: etag}} ->
            put_cache(%{fetched_at: now, etag: etag, models: models})
            {:ok, format_models(models)}

          :not_modified when not is_nil(cached) ->
            put_cache(%{cached | fetched_at: now})
            {:ok, format_models(cached.models)}

          :not_modified ->
            {:ok, fallback()}

          :no_account ->
            {:ok, fallback()}

          {:error, _reason} when not is_nil(cached) ->
            # stale-while-error: prefer slightly-stale cache over fallback.
            {:ok, format_models(cached.models)}

          {:error, _reason} ->
            {:ok, fallback()}
        end
    end
  end

  # ── Private ──

  defp ensure_cache_table do
    case :ets.info(@cache_table) do
      :undefined -> :ets.new(@cache_table, [:set, :public, :named_table])
      _ -> :ok
    end
  end

  defp lookup_cache do
    case :ets.lookup(@cache_table, @cache_key) do
      [{_, entry}] -> entry
      [] -> nil
    end
  end

  defp put_cache(entry) do
    :ets.insert(@cache_table, {@cache_key, entry})
    :ok
  end

  defp fallback do
    Enum.map(@fallback_models, fn id -> %{id: id, owned_by: "openai"} end)
  end

  defp format_models(models) do
    Enum.map(models, fn m ->
      slug = m["slug"] || m[:slug]
      %{id: slug, owned_by: "openai"}
    end)
  end

  defp fetch_upstream(manager, cached, opts) do
    case Manager.get_next_account(manager) do
      %{account: nil} ->
        :no_account

      %{account: account} ->
        url =
          "#{@base_url}#{@models_path}?client_version=" <>
            URI.encode_www_form(@client_version)

        headers =
          base_headers(account) ++
            etag_headers(cached)

        req_opts =
          [
            headers: headers,
            receive_timeout: 10_000,
            decode_body: false,
            # Disable Req's built-in retry — caching/fallback handles failures.
            retry: false
          ]
          |> maybe_put_plug(opts)

        case Req.get(url, req_opts) do
          {:ok, %Req.Response{status: 200, body: body, headers: resp_headers}} ->
            decode_models(body, find_header(resp_headers, "etag"))

          {:ok, %Req.Response{status: 304}} ->
            :not_modified

          {:ok, %Req.Response{status: status, body: body}} ->
            Logger.error(
              "[codex] /codex/models returned #{status}: #{body |> to_string() |> String.slice(0, 200)}"
            )

            {:error, {:http, status}}

          {:error, exception} ->
            Logger.error("[codex] /codex/models fetch failed: #{format_cause(exception)}")

            {:error, exception}
        end
    end
  end

  defp base_headers(account) do
    headers = [
      {"Authorization", "Bearer #{account.token.access_token}"},
      {"Accept", "application/json"},
      {"User-Agent", "auth2api_ex/1.0.0"}
    ]

    case account.chatgpt_account_id do
      nil -> headers
      "" -> headers
      id -> headers ++ [{"ChatGPT-Account-ID", id}]
    end
  end

  defp etag_headers(nil), do: []
  defp etag_headers(%{etag: nil}), do: []
  defp etag_headers(%{etag: etag}), do: [{"If-None-Match", normalize_etag(etag)}]

  @doc """
  Normalize an ETag value for If-None-Match.
  Strips the W/ prefix from weak ETags (W/"..." → "...") to avoid
  backend-specific weak-tag matching issues where 304 may never be returned.
  """
  def normalize_etag(etag) when is_binary(etag) do
    if String.starts_with?(etag, "W/"), do: String.slice(etag, 2..-1//1), else: etag
  end

  defp maybe_put_plug(req_opts, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end

  defp decode_models(body, etag) do
    body_str = body |> to_string()

    case Jason.decode(body_str) do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok, %{models: models, etag: etag}}

      {:ok, _} ->
        Logger.error("[codex] /codex/models response missing 'models' array")
        {:error, :missing_models}

      {:error, e} ->
        Logger.error("[codex] /codex/models JSON parse failed: #{Exception.message(e)}")
        {:error, e}
    end
  end

  defp find_header(headers, name) do
    needle = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} when is_binary(v) ->
        if String.downcase(k) == needle, do: v, else: nil

      {k, [v | _]} when is_binary(v) ->
        if String.downcase(k) == needle, do: v, else: nil

      _ ->
        nil
    end)
  end

  defp format_cause(%{__exception__: true} = exc) do
    base = Exception.message(exc) || inspect(exc)

    case Map.get(exc, :reason) do
      nil -> base
      reason -> "#{base} (#{inspect(reason)})"
    end
  end

  defp format_cause(other), do: inspect(other)
end
