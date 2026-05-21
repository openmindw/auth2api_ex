defmodule Auth2ApiEx.Upstream.Streaming do
  @moduledoc """
  SSE streaming response handler.
  Reads upstream Anthropic SSE events incrementally (chunk-by-chunk)
  and forwards them to the client, matching Node.js streaming behavior.
  """

  alias Auth2ApiEx.Accounts.Manager
  alias Auth2ApiEx.Upstream.SSEParser

  @type stream_result :: %{
          conn: Plug.Conn.t(),
          completed: boolean(),
          client_disconnected: boolean(),
          usage: Manager.usage_data()
        }

  @receive_timeout 600_000

  @doc """
  Handle a streaming response from the upstream Anthropic API.
  Supports both async (Req into: :self) and complete body responses.

  `write_chunk` is an optional callback invoked for each chunk destined for
  the client; when nil, `Plug.Conn.chunk/2` is used directly.
  """
  @spec handle_streaming_response(Req.Response.t(), Plug.Conn.t(), keyword()) :: stream_result()
  def handle_streaming_response(upstream, conn, opts \\ []) do
    on_event = Keyword.get(opts, :on_event)
    write_chunk = Keyword.get(opts, :write_chunk)

    usage = %{
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_creation_5m_tokens: 0,
      cache_creation_1h_tokens: 0,
      cache_read_input_tokens: 0,
      reasoning_output_tokens: 0
    }

    # Set SSE headers and begin chunked transfer
    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_header("connection", "keep-alive")
      |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
      |> Plug.Conn.send_chunked(200)

    try do
      case upstream.body do
        %{ref: ref} ->
          # Async streaming — process chunks incrementally via receive loop
          require Logger

          Logger.info(
            "[stream] async receive_loop start ref=#{inspect(ref)}"
          )

          receive_loop(
            ref,
            upstream,
            conn,
            on_event,
            write_chunk,
            usage,
            SSEParser.new_state(),
            false
          )

        body when is_binary(body) ->
          # Fallback: complete body already buffered
          process_complete_body(body, conn, on_event, write_chunk, usage)

        _ ->
          require Logger

          Logger.warning(
            "[stream] unexpected upstream body type, returning as completed: #{inspect(upstream.body)}"
          )

          %{conn: conn, completed: true, client_disconnected: false, usage: usage}
      end
    rescue
      e ->
        require Logger
        Logger.error("Stream error: #{Exception.message(e)}")
        %{conn: conn, completed: false, client_disconnected: false, usage: usage}
    end
  end

  # ── Incremental receive loop (matches Node.js chunk-by-chunk reader) ──

  defp receive_loop(ref, upstream, conn, on_event, write_chunk_fn, usage, sse_state, disconnected) do
    receive do
      {^ref, {:data, data}} ->
        if disconnected do
          receive_loop(ref, upstream, conn, on_event, write_chunk_fn, usage, sse_state, true)
        else
          # In passthrough mode (no on_event), forward raw data immediately
          {conn, disconnected} =
            if is_nil(on_event) do
              case do_write_chunk(write_chunk_fn, conn, data) do
                {:ok, next_conn} -> {next_conn, false}
                {:error, _} -> {conn, true}
              end
            else
              {conn, disconnected}
            end

          # Parse SSE events, threading state (current_event, data_lines, tail) across chunks
          {events, new_sse_state} = SSEParser.parse(data, sse_state)

          {conn, new_usage, disconnected} =
            Enum.reduce(events, {conn, usage, disconnected}, fn {event_type, event_data}, {current_conn, u, disc} ->
              u = extract_usage_from_sse(event_type, event_data, u)

              if on_event && !disc do
                chunks = on_event.(event_type, event_data, u)
                {next_conn, disc} = write_chunks(write_chunk_fn, current_conn, chunks, disc)
                {next_conn, u, disc}
              else
                {current_conn, u, disc}
              end
            end)

          if disconnected, do: cancel_async(upstream)

          receive_loop(
            ref,
            upstream,
            conn,
            on_event,
            write_chunk_fn,
            new_usage,
            new_sse_state,
            disconnected
          )
        end

      {^ref, :done} ->
        {final_conn, final_usage, disconnected} =
          flush_buffer(sse_state, conn, on_event, write_chunk_fn, usage, disconnected)

        require Logger

        Logger.info(
          "[stream] upstream done tokens_in=#{final_usage.input_tokens} tokens_out=#{final_usage.output_tokens} client_disconnected=#{disconnected}"
        )

        %{conn: final_conn, completed: true, client_disconnected: disconnected, usage: final_usage}

      {^ref, {:error, reason}} ->
        message = format_error_reason(reason)

        require Logger
        Logger.error("[stream] upstream error: #{message}")

        sse_error =
          "event: error\ndata: #{Jason.encode!(%{message: "upstream error: #{message}"})}\n\n"

        case do_write_chunk(write_chunk_fn, conn, sse_error) do
          {:ok, final_conn} ->
            %{conn: final_conn, completed: false, client_disconnected: disconnected, usage: usage}
          {:error, _} ->
            %{conn: conn, completed: false, client_disconnected: true, usage: usage}
        end
    after
      @receive_timeout ->
        cancel_async(upstream)
        require Logger
        Logger.error("[stream] upstream timeout after #{@receive_timeout}ms")
        # Write SSE error event on timeout
        sse_error = "event: error\ndata: #{Jason.encode!(%{message: "upstream timeout"})}\n\n"
        case do_write_chunk(write_chunk_fn, conn, sse_error) do
          {:ok, final_conn} ->
            %{conn: final_conn, completed: false, client_disconnected: false, usage: usage}
          {:error, _} ->
            %{conn: conn, completed: false, client_disconnected: true, usage: usage}
        end
    end
  end

  defp flush_buffer(%SSEParser.State{tail: ""}, conn, _on_event, _write_chunk, usage, disconnected),
    do: {conn, usage, disconnected}

  defp flush_buffer(sse_state, conn, on_event, write_chunk_fn, usage, disconnected) do
    # Flush any remaining buffered line by appending a terminating newline
    {events, _} = SSEParser.parse("\n\n", sse_state)

    Enum.reduce(events, {conn, usage, disconnected}, fn {event_type, event_data}, {current_conn, u, disc} ->
      u = extract_usage_from_sse(event_type, event_data, u)

      if on_event && !disc do
        {next_conn, disc} = write_chunks(write_chunk_fn, current_conn, on_event.(event_type, event_data, u), disc)
        {next_conn, u, disc}
      else
        {current_conn, u, disc}
      end
    end)
  end

  defp do_write_chunk(nil, conn, chunk), do: Plug.Conn.chunk(conn, chunk)
  defp do_write_chunk(write_fn, conn, chunk) when is_function(write_fn, 1) do
    case write_fn.(chunk) do
      {:error, reason} -> {:error, reason}
      _ -> {:ok, conn}
    end
  end
  defp do_write_chunk(_write_fn, conn, _chunk), do: {:ok, conn}

  defp format_error_reason(reason) when is_binary(reason), do: reason
  defp format_error_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_error_reason(reason), do: inspect(reason)

  defp write_chunks(_write_fn, conn, _chunks, true), do: {conn, true}

  defp write_chunks(write_chunk_fn, conn, chunks, false) do
    Enum.reduce_while(chunks, {conn, false}, fn chunk, {current_conn, _} ->
      case do_write_chunk(write_chunk_fn, current_conn, chunk) do
        {:ok, next_conn} -> {:cont, {next_conn, false}}
        {:error, _} -> {:halt, {current_conn, true}}
      end
    end)
  end

  defp cancel_async(upstream) do
    try do
      Req.cancel_async_response(upstream)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # ── Complete body processing (fallback for non-async responses) ──

  defp process_complete_body(body, conn, on_event, write_chunk_fn, usage) do
    # Parse all complete events, then flush any incomplete trailing event
    # (some bodies omit the final \n\n).
    {events, sse_state} = SSEParser.parse(body, SSEParser.new_state())
    {flush_events, _} = SSEParser.parse("\n\n", sse_state)
    all_events = events ++ flush_events

    {final_conn, usage, disconnected} =
      Enum.reduce(all_events, {conn, usage, false}, fn {event_type, data}, {current_conn, u, disc} ->
        u = extract_usage_from_sse(event_type, data, u)

        if disc do
          {current_conn, u, disc}
        else
          if on_event do
            {next_conn, disc} = write_chunks(write_chunk_fn, current_conn, on_event.(event_type, data, u), disc)
            {next_conn, u, disc}
          else
            chunk = "event: #{event_type}\ndata: #{Jason.encode!(data)}\n\n"

            case do_write_chunk(write_chunk_fn, current_conn, chunk) do
              {:ok, next_conn} -> {next_conn, u, false}
              {:error, _} -> {current_conn, u, true}
            end
          end
        end
      end)

    %{conn: final_conn, completed: true, client_disconnected: disconnected, usage: usage}
  end

  defp extract_usage_from_sse("message_start", data, usage) do
    u = get_in(data, ["message", "usage"]) || %{}
    merge_anthropic_usage(usage, u)
  end

  defp extract_usage_from_sse("message_delta", data, usage) do
    u = data["usage"] || %{}
    merge_anthropic_usage(usage, u)
  end

  defp extract_usage_from_sse(event, data, usage)
       when event in ["response.completed", "response.done"] do
    u = get_in(data, ["response", "usage"]) || %{}

    %{
      usage
      | input_tokens: u["input_tokens"] || usage.input_tokens,
        output_tokens: u["output_tokens"] || usage.output_tokens,
        cache_read_input_tokens:
          get_in(u, ["input_tokens_details", "cached_tokens"]) || usage.cache_read_input_tokens,
        reasoning_output_tokens:
          get_in(u, ["output_tokens_details", "reasoning_tokens"]) ||
            usage.reasoning_output_tokens
    }
  end

  defp extract_usage_from_sse(_, _, usage), do: usage

  defp merge_anthropic_usage(usage, u) do
    cache_creation_5m = get_in(u, ["cache_creation", "ephemeral_5m_input_tokens"])
    cache_creation_1h = get_in(u, ["cache_creation", "ephemeral_1h_input_tokens"])

    cache_creation_total =
      cond do
        positive?(u["cache_creation_input_tokens"]) ->
          u["cache_creation_input_tokens"]

        usage.cache_creation_input_tokens > 0 ->
          usage.cache_creation_input_tokens

        true ->
          ttl_total(cache_creation_5m, cache_creation_1h)
      end

    %{
      usage
      | input_tokens: nonzero_or_existing(u["input_tokens"], usage.input_tokens),
        output_tokens: nonzero_or_existing(u["output_tokens"], usage.output_tokens),
        cache_creation_input_tokens:
          nonzero_or_existing(cache_creation_total, usage.cache_creation_input_tokens),
        cache_creation_5m_tokens:
          nonzero_or_existing(cache_creation_5m, usage.cache_creation_5m_tokens),
        cache_creation_1h_tokens:
          nonzero_or_existing(cache_creation_1h, usage.cache_creation_1h_tokens),
        cache_read_input_tokens:
          nonzero_or_existing(
            u["cache_read_input_tokens"],
            nonzero_or_existing(u["cached_tokens"], usage.cache_read_input_tokens)
          )
    }
  end

  defp ttl_total(v5, v1), do: max(to_int(v5) + to_int(v1), 0)

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_number(value), do: trunc(value)
  defp to_int(_), do: 0

  defp positive?(value) when is_integer(value), do: value > 0
  defp positive?(value) when is_number(value), do: value > 0
  defp positive?(_), do: false

  defp nonzero_or_existing(value, _existing) when is_integer(value) and value > 0, do: value
  defp nonzero_or_existing(value, _existing) when is_number(value) and value > 0, do: value
  defp nonzero_or_existing(_, existing), do: existing
end
