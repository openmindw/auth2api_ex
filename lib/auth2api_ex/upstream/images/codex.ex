defmodule Auth2ApiEx.Upstream.Images.Codex do
  @moduledoc """
  Codex Images converter — builds Codex Responses payloads for image_generation
  tool invocations, processes SSE events, resolves internal pointer URLs, and
  aggregates final responses.

  ## Responsibilities

    * `build_request/2` — convert %Request{} → Codex Responses body
    * SSE event filter — map Codex events to OpenAI Images shape
    * Pointer resolution — download b64_bytes from file-service:// / sediment://
    * Aggregation — produce `{"created": ..., "data": [{"b64_json": "..."}]}`
  """

  alias Auth2ApiEx.Upstream.Images.Request

  require Logger

  @type account :: map()

  # ── Build Codex Responses payload ──

  @doc """
  Build a Codex Responses API body from a parsed images request.

  Uses `upstream_codex_model` as the chat model and places the image
  tool configuration under `tools[].image_generation`.
  """
  @spec build_request(Request.t(), String.t()) :: map()
  def build_request(req, upstream_codex_model) do
    tool = build_tool(req)
    input = build_input(req)

    base = %{
      "model" => upstream_codex_model,
      "stream" => true,
      "store" => false,
      "instructions" => "",
      "input" => input,
      "tools" => [tool]
    }

    # Optional tool-level knobs (nil values omitted)
    base
    |> maybe_put_tool_field("quality", req.quality)
    |> maybe_put_tool_field("background", req.background)
    |> maybe_put_tool_field("output_format", req.output_format)
    |> maybe_put_tool_field("output_compression", req.output_compression)
    |> maybe_put_tool_field("moderation", req.moderation)
    |> maybe_put_tool_field("style", req.style)
    |> maybe_put_tool_field("partial_images", req.partial_images)
  end

  defp build_tool(req) do
    tool = %{
      "type" => "image_generation",
      "action" => if(req.endpoint == :edits, do: "edit", else: "generate"),
      "model" => req.model,
      "size" => req.size,
      "n" => req.n
    }

    # If edit + has mask_upload → attach mask as input_image_mask
    tool =
      if req.endpoint == :edits && req.mask_upload != nil do
        Map.put(tool, "input_image_mask", build_input_image(req.mask_upload))
      else
        tool
      end

    tool
  end

  defp build_input(req) do
    # Text prompt
    content_parts = []

    content_parts =
      if req.prompt != "" do
        content_parts ++ [%{"type" => "input_text", "text" => req.prompt}]
      else
        content_parts
      end

    # Uploaded images → input_image blocks
    content_parts =
      if length(req.uploads) > 0 do
        content_parts ++ Enum.map(req.uploads, &build_input_image(&1))
      else
        content_parts
      end

    # input_image_urls (JSON edits endpoint)
    content_parts =
      if length(req.input_image_urls) > 0 do
        content_parts ++
          Enum.map(req.input_image_urls, fn url ->
            %{"type" => "input_image", "image_url" => url}
          end)
      else
        content_parts
      end

    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => content_parts
      }
    ]
  end

  defp build_input_image(%{data: data, content_type: mime}) do
    b64 = Base.encode64(data)
    %{"type" => "input_image", "image_url" => "data:#{mime};base64,#{b64}"}
  end

  defp maybe_put_tool_field(body, _key, nil), do: body

  defp maybe_put_tool_field(body, key, value) do
    put_in(body, ["tools", Access.at(0), key], value)
  end

  # ── SSE event -> OpenAIImages event (stream) ──

  @doc """
  Callback for `Streaming.handle_streaming_response/3`.

  Maps Codex Responses SSE events to OpenAI Images API SSE events.
  Returns a list of SSE strings (ready to write to client).

  Events:
    - `response.image_generation.partial_image` → `image_generation.partial_image`
    - `response.image_generation.completed` → `image_generation.completed`
    - `response.completed` → nothing (handled after aggregation)
    - `response.failed` / `response.error` → `event: error`
  """
  @spec on_sse_event(String.t(), map(), stream_state()) :: [String.t()]
  def on_sse_event(event, data, _usage) do
    case event do
      "response.image_generation.partial_image" ->
        partial = %{
          "type" => "image_generation.partial_image",
          "created_at" => Map.get(data, "created_at", System.system_time(:second)),
          "partial_image_index" => Map.get(data, "partial_image_index", 0),
          "b64_json" => Map.get(data, "b64_json", "")
        }

        [format_sse("image_generation.partial_image", partial)]

      "response.image_generation.completed" ->
        completed = %{
          "type" => "image_generation.completed",
          "created_at" => Map.get(data, "created_at", System.system_time(:second)),
          "b64_json" => Map.get(data, "b64_json", ""),
          "revised_prompt" => Map.get(data, "revised_prompt", ""),
          "output_format" => Map.get(data, "output_format"),
          "quality" => Map.get(data, "quality"),
          "size" => Map.get(data, "size")
        }

        [format_sse("image_generation.completed", completed)]

      "response.failed" ->
        [format_sse("error", %{"message" => Map.get(data, "error", %{}) |> Jason.encode!()})]

      "response.error" ->
        msg =
          data["error"] ||
            get_in(data, ["error", "message"]) ||
            "image generation failed"

        [format_sse("error", %{"message" => msg})]

      _ ->
        []
    end
  end

  # ── Non-stream SSE aggregation ──

  @doc """
  Accumulate SSE event data while streaming completes.

  Returns `{:cont | :done, binary_content | nil, acc}`.
  """
  def aggregate_event(event, data, acc) do
    case event do
      "response.image_generation.partial_image" ->
        {:cont, nil, acc}

      "response.image_generation.completed" ->
        b64 = Map.get(data, "b64_json", "")
        url = Map.get(data, "download_url")
        {:cont, nil, Map.update(acc, :images, [], fn list -> list ++ [%{b64: b64, url: url}] end)}

      "response.output_item.done" ->
        # image_generation_call items end up here — extract result
        item = Map.get(data, "item", %{})

        if item["type"] == "image_generation_call" do
          result = item["result"] || ""

          {:cont, nil,
           Map.update(acc, :images, [], fn list ->
             list ++ [%{b64: result}]
           end)}
        else
          {:cont, nil, acc}
        end

      "response.completed" ->
        {:done, nil, acc}

      "response.failed" ->
        {:done, {:error, data}, acc}

      "response.error" ->
        {:done, {:error, data}, acc}

      _ ->
        {:cont, nil, acc}
    end
  end

  # ── Build final OpenAI Images API response ──

  @doc """
  Build the final OpenAI Images API JSON response from an accumulated image list.

  Each image is `%{b64: binary | nil, url: binary | nil}`. If `response_format`
  is `"url"`, emits `"url"` entries; otherwise emits `"b64_json"`.
  """
  @spec build_openai_images_response([map()], String.t()) :: map()
  def build_openai_images_response(images, response_format) do
    data =
      Enum.map(images, fn img ->
        if response_format == "url" && img[:url] do
          %{"url" => img[:url]}
        else
          b64 = img[:b64] || ""
          %{"b64_json" => b64}
        end
      end)

    %{
      "created" => System.system_time(:second),
      "data" => data
    }
  end

  # ── Pointer resolution ──

  @doc """
  Scan JSON text for `file-service://` and `sediment://` pointers,
  extracting both inline `b64_json` / `download_url` / `asset_pointer`
  and the pointer-style references.
  """
  @spec extract_pointers(String.t()) :: [map()]
  def extract_pointers(body) when is_binary(body) do
    {:ok, parsed} = Jason.decode(body)
    extract_pointers(parsed)
  rescue
    _ -> []
  end

  def extract_pointers(data) when is_map(data) do
    # Inline assets
    inline =
      collect_inline_assets(data)
      |> Enum.reject(fn m -> map_size(m) == 0 end)

    # file-service://… and sediment://… URLs
    pointers =
      collect_url_pointers(data)
      |> Enum.reject(fn m -> map_size(m) == 0 end)

    (inline ++ pointers)
    |> Enum.uniq()
  end

  @doc """
  Resolve a single pointer into binary image bytes.

  `account` must provide `token.access_token`.
  `conversation_id` comes from the Codex response context.
  """
  @spec resolve_pointer(account(), map(), String.t() | nil, map()) ::
          {:ok, binary()} | {:error, term()}
  def resolve_pointer(account, pointer, conversation_id, images_config) do
    max_retries = images_config.pointer_retry_count
    delay_ms = images_config.pointer_retry_delay_ms
    access_token = account.token.access_token

    cond do
      # Inline b64
      pointer[:b64] && pointer[:b64] != "" ->
        {:ok, pointer[:b64]}

      # download_url → GET
      pointer[:download_url] && pointer[:download_url] != "" ->
        download_image(pointer[:download_url], access_token, max_retries, delay_ms)

      # file-service://{id}
      String.starts_with?(pointer[:url] || "", "file-service://") ->
        file_id = String.replace_prefix(pointer[:url], "file-service://", "")

        fetch_file_download_url(access_token, file_id, max_retries, delay_ms)
        |> case do
          {:ok, dl_url} -> download_image(dl_url, access_token, max_retries, delay_ms)
          {:error, _} = err -> err
        end

      # sediment://{att_id}
      String.starts_with?(pointer[:url] || "", "sediment://") && conversation_id ->
        att_id = String.replace_prefix(pointer[:url], "sediment://", "")

        fetch_attachment_download_url(
          access_token,
          conversation_id,
          att_id,
          max_retries,
          delay_ms
        )
        |> case do
          {:ok, dl_url} -> download_image(dl_url, access_token, max_retries, delay_ms)
          {:error, _} = err -> err
        end

      true ->
        {:error, :no_resolvable_pointer}
    end
  end

  # ── Private: pointer discovery ──

  defp collect_inline_assets(data) do
    results = []

    results =
      case get_in(data, ["b64_json"]) do
        b64 when is_binary(b64) and b64 != "" -> results ++ [%{b64: b64}]
        _ -> results
      end

    results =
      case get_in(data, ["download_url"]) do
        url when is_binary(url) and url != "" -> results ++ [%{download_url: url}]
        _ -> results
      end

    results =
      case get_in(data, ["asset_pointer"]) do
        url when is_binary(url) and url != "" -> results ++ [%{url: url}]
        _ -> results
      end

    results
  end

  defp collect_url_pointers(data) when is_map(data) do
    str = Jason.encode!(data)

    file_refs =
      Regex.scan(~r/file-service:\/\/[^\s"']+/, str)
      |> Enum.map(fn [url] -> %{url: url} end)

    sed_refs =
      Regex.scan(~r/sediment:\/\/[^\s"']+/, str)
      |> Enum.map(fn [url] -> %{url: url} end)

    file_refs ++ sed_refs
  end

  # ── Private: HTTP downloads ──

  @base_url "https://chatgpt.com/backend-api"

  defp download_image(url, access_token, retries, delay_ms) do
    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Accept", "image/*, */*"}
    ]

    attempt_download(url, headers, retries, delay_ms, 0)
  end

  defp attempt_download(_url, _headers, max_retries, _delay_ms, attempt)
       when attempt >= max_retries do
    {:error, :download_exhausted}
  end

  defp attempt_download(url, headers, max_retries, delay_ms, attempt) do
    case Req.get(url,
           headers: headers,
           decode_body: false,
           receive_timeout: 60_000,
           max_body: 20 * 1024 * 1024
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Image download returned #{status} from #{String.slice(url, 0, 80)}")
        Process.sleep(delay_ms)
        attempt_download(url, headers, max_retries, delay_ms, attempt + 1)

      {:error, reason} ->
        Logger.warning("Image download error: #{inspect(reason)}")
        Process.sleep(delay_ms)
        attempt_download(url, headers, max_retries, delay_ms, attempt + 1)
    end
  end

  defp fetch_file_download_url(access_token, file_id, retries, delay_ms) do
    url = "#{@base_url}/files/#{file_id}/download"
    headers = [{"Authorization", "Bearer #{access_token}"}, {"Accept", "application/json"}]

    attempt_fetch_url(url, headers, retries, delay_ms, 0)
  end

  defp fetch_attachment_download_url(access_token, conv_id, att_id, retries, delay_ms) do
    url = "#{@base_url}/conversation/#{conv_id}/attachment/#{att_id}/download"
    headers = [{"Authorization", "Bearer #{access_token}"}, {"Accept", "application/json"}]

    attempt_fetch_url(url, headers, retries, delay_ms, 0)
  end

  defp attempt_fetch_url(_url, _headers, max_retries, _delay_ms, attempt)
       when attempt >= max_retries do
    {:error, :pointer_exhausted}
  end

  defp attempt_fetch_url(url, headers, max_retries, delay_ms, attempt) do
    case Req.get(url, headers: headers, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        url = get_in(body, ["download_url"]) || body["url"]

        if url && url != "" do
          {:ok, url}
        else
          {:error, :no_download_url}
        end

      {:ok, %Req.Response{status: 404, body: body}} ->
        body_str = Jason.encode!(body)

        # sediment:// pointers can return "conversation_not_found" — retry
        if String.contains?(body_str, "conversation_not_found") do
          Process.sleep(delay_ms)
          attempt_fetch_url(url, headers, max_retries, delay_ms, attempt + 1)
        else
          {:error, :pointer_not_found}
        end

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Pointer fetch returned #{status}: #{String.slice(url, 0, 80)}")
        Process.sleep(delay_ms)
        attempt_fetch_url(url, headers, max_retries, delay_ms, attempt + 1)

      {:error, reason} ->
        Logger.warning("Pointer fetch error: #{inspect(reason)}")
        Process.sleep(delay_ms)
        attempt_fetch_url(url, headers, max_retries, delay_ms, attempt + 1)
    end
  end

  # ── SSE helpers ──

  defp format_sse(event_type, data) do
    "event: #{event_type}\ndata: #{Jason.encode!(data)}\n\n"
  end

  @type stream_state :: map()
end
