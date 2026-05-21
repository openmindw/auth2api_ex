defmodule Auth2ApiEx.StreamingTest do
  use ExUnit.Case, async: true

  alias Auth2ApiEx.Upstream.{Translator, Streaming}

  # ══════════════════════════════════════════════════
  # Chat Completions SSE: anthropic_sse_to_chat/4
  # ══════════════════════════════════════════════════

  describe "anthropic_sse_to_chat/4" do
    setup do
      {:ok, state: Translator.create_stream_state("claude-sonnet-4-6", true)}
    end

    test "message_start emits role chunk", %{state: state} do
      {chunks, _state} = Translator.anthropic_sse_to_chat("message_start", %{}, state)
      assert length(chunks) == 1
      parsed = Jason.decode!(hd(chunks))
      assert parsed["object"] == "chat.completion.chunk"
      [choice] = parsed["choices"]
      assert choice["delta"]["role"] == "assistant"
      assert choice["delta"]["content"] == ""
    end

    test "content_block_start with tool_use emits tool call header", %{state: state} do
      data = %{
        "index" => 0,
        "content_block" => %{"type" => "tool_use", "id" => "toolu_123", "name" => "get_weather"}
      }

      {chunks, new_state} = Translator.anthropic_sse_to_chat("content_block_start", data, state)
      assert length(chunks) == 1
      parsed = Jason.decode!(hd(chunks))
      [choice] = parsed["choices"]
      [tc] = choice["delta"]["tool_calls"]
      assert tc["id"] == "toolu_123"
      assert tc["function"]["name"] == "get_weather"
      assert tc["index"] == 0
      assert new_state.next_tool_index == 1
    end

    test "content_block_start with text emits nothing", %{state: state} do
      data = %{"index" => 0, "content_block" => %{"type" => "text"}}
      {chunks, _state} = Translator.anthropic_sse_to_chat("content_block_start", data, state)
      assert chunks == []
    end

    test "content_block_delta text_delta emits content chunk", %{state: state} do
      data = %{"index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hello"}}
      {chunks, _state} = Translator.anthropic_sse_to_chat("content_block_delta", data, state)
      assert length(chunks) == 1
      parsed = Jason.decode!(hd(chunks))
      [choice] = parsed["choices"]
      assert choice["delta"]["content"] == "Hello"
    end

    test "content_block_delta thinking_delta emits reasoning_content", %{state: state} do
      data = %{
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "Let me think..."}
      }

      {chunks, _state} = Translator.anthropic_sse_to_chat("content_block_delta", data, state)
      assert length(chunks) == 1
      parsed = Jason.decode!(hd(chunks))
      [choice] = parsed["choices"]
      assert choice["delta"]["reasoning_content"] == "Let me think..."
    end

    test "content_block_delta input_json_delta emits tool call args", %{state: state} do
      # First register a tool call
      block_data = %{
        "index" => 0,
        "content_block" => %{"type" => "tool_use", "id" => "toolu_1", "name" => "fn"}
      }

      {_, state} = Translator.anthropic_sse_to_chat("content_block_start", block_data, state)

      # Now send partial JSON
      delta_data = %{
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"k\":"}
      }

      {chunks, _state} =
        Translator.anthropic_sse_to_chat("content_block_delta", delta_data, state)

      assert length(chunks) == 1
      parsed = Jason.decode!(hd(chunks))
      [choice] = parsed["choices"]
      [tc] = choice["delta"]["tool_calls"]
      assert tc["function"]["arguments"] == "{\"k\":"
    end

    test "message_delta emits finish_reason", %{state: state} do
      data = %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{}}
      {chunks, _state} = Translator.anthropic_sse_to_chat("message_delta", data, state)
      assert length(chunks) == 1
      parsed = Jason.decode!(hd(chunks))
      [choice] = parsed["choices"]
      assert choice["finish_reason"] == "stop"
    end

    test "message_stop emits usage and [DONE]", %{state: state} do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        cache_read_input_tokens: 10,
        cache_creation_input_tokens: 0
      }

      {chunks, _state} = Translator.anthropic_sse_to_chat("message_stop", %{}, state, usage)
      assert length(chunks) == 2
      [usage_chunk, done] = chunks
      assert done == "[DONE]"
      parsed = Jason.decode!(usage_chunk)
      assert parsed["usage"]["prompt_tokens"] == 100
      assert parsed["usage"]["completion_tokens"] == 50
    end

    test "message_stop without usage (include_usage=false) emits only [DONE]" do
      state = Translator.create_stream_state("claude-sonnet-4-6", false)
      {chunks, _state} = Translator.anthropic_sse_to_chat("message_stop", %{}, state, nil)
      assert chunks == ["[DONE]"]
    end

    test "tool call state threads across multiple blocks", %{state: state} do
      # First tool
      {_, state} =
        Translator.anthropic_sse_to_chat(
          "content_block_start",
          %{
            "index" => 0,
            "content_block" => %{"type" => "tool_use", "id" => "t1", "name" => "fn_a"}
          },
          state
        )

      # Second tool
      {chunks, state} =
        Translator.anthropic_sse_to_chat(
          "content_block_start",
          %{
            "index" => 1,
            "content_block" => %{"type" => "tool_use", "id" => "t2", "name" => "fn_b"}
          },
          state
        )

      parsed = Jason.decode!(hd(chunks))
      [choice] = parsed["choices"]
      [tc] = choice["delta"]["tool_calls"]
      assert tc["index"] == 1
      assert tc["id"] == "t2"
      assert state.next_tool_index == 2
    end

    test "full streaming sequence produces valid chat completion stream", %{state: state} do
      events = [
        {"message_start", %{}},
        {"content_block_start", %{"index" => 0, "content_block" => %{"type" => "text"}}},
        {"content_block_delta",
         %{"index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hello"}}},
        {"content_block_delta",
         %{"index" => 0, "delta" => %{"type" => "text_delta", "text" => " world"}}},
        {"content_block_stop", %{"index" => 0}},
        {"message_delta",
         %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{"output_tokens" => 10}}},
        {"message_stop", %{}}
      ]

      usage = %{
        input_tokens: 50,
        output_tokens: 10,
        cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0
      }

      {all_chunks, _final_state} =
        Enum.reduce(events, {[], state}, fn {event, data}, {acc, st} ->
          u = if event == "message_stop", do: usage, else: nil
          {chunks, new_st} = Translator.anthropic_sse_to_chat(event, data, st, u)
          {acc ++ chunks, new_st}
        end)

      # Should have: role chunk, 2 text deltas, finish_reason, usage, [DONE]
      assert length(all_chunks) >= 4
      assert List.last(all_chunks) == "[DONE]"

      # All non-[DONE] chunks should be valid JSON
      all_chunks
      |> Enum.reject(&(&1 == "[DONE]"))
      |> Enum.each(fn chunk ->
        {:ok, parsed} = Jason.decode(chunk)
        assert parsed["object"] == "chat.completion.chunk"
      end)
    end
  end

  # ══════════════════════════════════════════════════
  # Responses API SSE: anthropic_sse_to_responses/5
  # ══════════════════════════════════════════════════

  describe "anthropic_sse_to_responses/5" do
    @default_usage %{
      input_tokens: 0,
      output_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0
    }

    setup do
      {:ok, state: Translator.make_responses_state()}
    end

    test "message_start emits response.created and response.in_progress", %{state: state} do
      {events, _state} =
        Translator.anthropic_sse_to_responses(
          "message_start",
          %{},
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      assert length(events) == 2

      [created_sse, in_progress_sse] = events
      assert String.contains?(created_sse, "response.created")
      assert String.contains?(in_progress_sse, "response.in_progress")
    end

    test "content_block_start text emits output_item.added and content_part.added", %{
      state: state
    } do
      data = %{"index" => 0, "content_block" => %{"type" => "text"}}

      {events, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_start",
          data,
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      assert length(events) == 2
      assert state.in_text_block == true

      sse_types = Enum.map(events, fn e -> extract_sse_type(e) end)
      assert "response.output_item.added" in sse_types
      assert "response.content_part.added" in sse_types
    end

    test "content_block_start thinking emits reasoning events", %{state: state} do
      data = %{"index" => 0, "content_block" => %{"type" => "thinking"}}

      {events, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_start",
          data,
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      assert length(events) == 2
      assert state.in_thinking_block == true

      sse_types = Enum.map(events, fn e -> extract_sse_type(e) end)
      assert "response.output_item.added" in sse_types
      assert "response.reasoning_summary_part.added" in sse_types
    end

    test "content_block_start tool_use emits function_call output_item", %{state: state} do
      data = %{
        "index" => 0,
        "content_block" => %{"type" => "tool_use", "id" => "toolu_1", "name" => "get_weather"}
      }

      {events, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_start",
          data,
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      assert length(events) == 1
      assert state.in_tool_block == true
      assert state.current_tool_id == "toolu_1"
      assert state.current_tool_name == "get_weather"
    end

    test "content_block_delta text_delta emits output_text.delta", %{state: state} do
      # Enter text block first
      {_, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_start",
          %{"index" => 0, "content_block" => %{"type" => "text"}},
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      data = %{"index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hello"}}

      {events, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_delta",
          data,
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      assert length(events) == 1
      assert extract_sse_type(hd(events)) == "response.output_text.delta"
      assert state.current_text == "Hello"
    end

    test "content_block_delta thinking_delta emits reasoning_summary_text.delta", %{state: state} do
      {_, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_start",
          %{"index" => 0, "content_block" => %{"type" => "thinking"}},
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      data = %{"index" => 0, "delta" => %{"type" => "thinking_delta", "thinking" => "Hmm..."}}

      {events, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_delta",
          data,
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      assert length(events) == 1
      assert extract_sse_type(hd(events)) == "response.reasoning_summary_text.delta"
      assert state.current_thinking_text == "Hmm..."
    end

    test "content_block_delta input_json_delta emits function_call_arguments.delta", %{
      state: state
    } do
      {_, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_start",
          %{
            "index" => 0,
            "content_block" => %{"type" => "tool_use", "id" => "t1", "name" => "fn"}
          },
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      data = %{
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"a\":"}
      }

      {events, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_delta",
          data,
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      assert length(events) == 1
      assert extract_sse_type(hd(events)) == "response.function_call_arguments.delta"
      assert state.current_tool_args == "{\"a\":"
    end

    test "content_block_stop text emits done events", %{state: state} do
      {_, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_start",
          %{"index" => 0, "content_block" => %{"type" => "text"}},
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      {_, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_delta",
          %{"index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hi"}},
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      {events, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_stop",
          %{"index" => 0},
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      assert length(events) == 3
      assert state.in_text_block == false

      sse_types = Enum.map(events, fn e -> extract_sse_type(e) end)
      assert "response.output_text.done" in sse_types
      assert "response.content_part.done" in sse_types
      assert "response.output_item.done" in sse_types
    end

    test "content_block_stop tool emits function_call done events", %{state: state} do
      {_, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_start",
          %{
            "index" => 0,
            "content_block" => %{"type" => "tool_use", "id" => "t1", "name" => "fn"}
          },
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      {_, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_delta",
          %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"a\":1}"}
          },
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      {events, state} =
        Translator.anthropic_sse_to_responses(
          "content_block_stop",
          %{"index" => 0},
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      assert length(events) == 2
      assert state.in_tool_block == false

      sse_types = Enum.map(events, fn e -> extract_sse_type(e) end)
      assert "response.function_call_arguments.done" in sse_types
      assert "response.output_item.done" in sse_types
    end

    test "message_stop emits response.completed and response.done", %{state: state} do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        cache_read_input_tokens: 10,
        cache_creation_input_tokens: 0
      }

      {events, _state} =
        Translator.anthropic_sse_to_responses(
          "message_stop",
          %{},
          state,
          "claude-sonnet-4-6",
          usage
        )

      assert length(events) == 2

      sse_types = Enum.map(events, fn e -> extract_sse_type(e) end)
      assert "response.completed" in sse_types
      assert "response.done" in sse_types

      # Check usage in completed event
      completed_sse = Enum.find(events, fn e -> String.contains?(e, "response.completed") end)
      {:ok, parsed} = parse_sse_data(completed_sse)
      assert parsed["response"]["usage"]["input_tokens"] == 100
      assert parsed["response"]["usage"]["output_tokens"] == 50
    end

    test "sequence numbers increment across events", %{state: state} do
      {events1, state} =
        Translator.anthropic_sse_to_responses(
          "message_start",
          %{},
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      {events2, _state} =
        Translator.anthropic_sse_to_responses(
          "content_block_start",
          %{"index" => 0, "content_block" => %{"type" => "text"}},
          state,
          "claude-sonnet-4-6",
          @default_usage
        )

      all_seqs =
        (events1 ++ events2)
        |> Enum.map(fn e ->
          {:ok, parsed} = parse_sse_data(e)
          parsed["sequence_number"]
        end)

      # Sequence numbers should be non-decreasing (some events may share a seq)
      assert all_seqs == Enum.sort(all_seqs)
    end

    test "full text streaming sequence", %{state: state} do
      model = "claude-sonnet-4-6"

      usage = %{
        input_tokens: 50,
        output_tokens: 10,
        cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0
      }

      events_seq = [
        {"message_start", %{}},
        {"content_block_start", %{"index" => 0, "content_block" => %{"type" => "text"}}},
        {"content_block_delta",
         %{"index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hello"}}},
        {"content_block_delta",
         %{"index" => 0, "delta" => %{"type" => "text_delta", "text" => " world"}}},
        {"content_block_stop", %{"index" => 0}},
        {"message_stop", %{}}
      ]

      {all_events, _final_state} =
        Enum.reduce(events_seq, {[], state}, fn {event, data}, {acc, st} ->
          {evts, new_st} = Translator.anthropic_sse_to_responses(event, data, st, model, usage)
          {acc ++ evts, new_st}
        end)

      # Verify we got events
      assert length(all_events) > 0

      # All events should be valid SSE format
      Enum.each(all_events, fn e ->
        assert String.starts_with?(e, "event: ")
        assert String.contains?(e, "\ndata: ")
      end)

      # Last events should be response.completed and response.done
      sse_types = Enum.map(all_events, fn e -> extract_sse_type(e) end)
      assert List.last(sse_types) == "response.done"
      assert "response.completed" in sse_types
    end
  end

  # ══════════════════════════════════════════════════
  # Streaming error fallback
  # ══════════════════════════════════════════════════

  describe "handle_streaming_response/3 — error fallback" do
    test "complete body fallback processes final SSE event without trailing blank line" do
      body =
        "event: message_delta\n" <>
          ~s(data: {"usage":{"input_tokens":11,"output_tokens":7}})

      upstream = %Req.Response{status: 200, body: body}
      conn = Plug.Test.conn(:post, "/")
      agent = start_supervised!({Agent, fn -> [] end})

      result =
        Streaming.handle_streaming_response(upstream, conn,
          write_chunk: fn chunk ->
            Agent.update(agent, &(&1 ++ [chunk]))
            {:ok, nil}
          end
        )

      assert result.completed
      assert result.usage.input_tokens == 11
      assert result.usage.output_tokens == 7
      assert Enum.any?(Agent.get(agent, & &1), &String.contains?(&1, "message_delta"))
    end

    test "complete body fallback extracts message_start cache creation TTL usage" do
      body =
        "event: message_start\n" <>
          ~s(data: {"message":{"usage":{"input_tokens":101,"cache_creation_input_tokens":30,"cache_read_input_tokens":7,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}) <>
          "\n\n" <>
          "event: message_delta\n" <>
          ~s(data: {"usage":{"output_tokens":9,"cache_creation":{"ephemeral_5m_input_tokens":11,"ephemeral_1h_input_tokens":21}}})

      upstream = %Req.Response{status: 200, body: body}
      conn = Plug.Test.conn(:post, "/")

      result =
        Streaming.handle_streaming_response(upstream, conn,
          write_chunk: fn _chunk -> {:ok, nil} end
        )

      assert result.completed
      assert result.usage.input_tokens == 101
      assert result.usage.output_tokens == 9
      assert result.usage.cache_creation_input_tokens == 30
      assert result.usage.cache_read_input_tokens == 7
      assert result.usage.cache_creation_5m_tokens == 11
      assert result.usage.cache_creation_1h_tokens == 21
    end

    test "complete body fallback supports legacy cached_tokens and TTL total fallback" do
      body =
        "event: message_start\n" <>
          ~s(data: {"message":{"usage":{"input_tokens":12,"cached_tokens":9,"cache_creation":{"ephemeral_5m_input_tokens":3,"ephemeral_1h_input_tokens":4}}}}) <>
          "\n\n" <>
          "event: message_delta\n" <>
          ~s(data: {"usage":{"output_tokens":5}})

      upstream = %Req.Response{status: 200, body: body}
      conn = Plug.Test.conn(:post, "/")

      result =
        Streaming.handle_streaming_response(upstream, conn,
          write_chunk: fn _chunk -> {:ok, nil} end
        )

      assert result.completed
      assert result.usage.input_tokens == 12
      assert result.usage.output_tokens == 5
      assert result.usage.cache_read_input_tokens == 9
      assert result.usage.cache_creation_input_tokens == 7
      assert result.usage.cache_creation_5m_tokens == 3
      assert result.usage.cache_creation_1h_tokens == 4
    end

    test "complete body fallback extracts OpenAI Responses terminal usage" do
      body =
        "event: response.completed\n" <>
          ~s(data: {"response":{"usage":{"input_tokens":13,"output_tokens":6,"input_tokens_details":{"cached_tokens":2},"output_tokens_details":{"reasoning_tokens":1}}}})

      upstream = %Req.Response{status: 200, body: body}
      conn = Plug.Test.conn(:post, "/")

      result =
        Streaming.handle_streaming_response(upstream, conn,
          write_chunk: fn _chunk -> {:ok, nil} end
        )

      assert result.completed
      assert result.usage.input_tokens == 13
      assert result.usage.output_tokens == 6
      assert result.usage.cache_read_input_tokens == 2
      assert result.usage.reasoning_output_tokens == 1
    end

    test "writes SSE error event on upstream error and returns completed=false" do
      ref = make_ref()
      upstream = %{ref: ref, body: %{ref: ref}}
      conn = Plug.Test.conn(:post, "/")

      agent = start_supervised!({Agent, fn -> [] end})

      send(self(), {ref, {:error, "upstream connection reset"}})

      Streaming.handle_streaming_response(upstream, conn,
        write_chunk: fn chunk -> Agent.update(agent, &(&1 ++ [chunk])) end
      )

      written = Agent.get(agent, & &1)
      assert Enum.any?(written, fn chunk -> String.contains?(chunk, "event: error") end)
    end

    test "formats Mint.HTTPError upstream errors instead of raising String.Chars" do
      ref = make_ref()
      upstream = %{ref: ref, body: %{ref: ref}}
      conn = Plug.Test.conn(:post, "/")
      agent = start_supervised!({Agent, fn -> [] end})

      send(
        self(),
        {ref, {:error, %Mint.HTTPError{reason: {:server_closed_request, :internal_error}}}}
      )

      result =
        Streaming.handle_streaming_response(upstream, conn,
          write_chunk: fn chunk ->
            Agent.update(agent, &(&1 ++ [chunk]))
            {:ok, nil}
          end
        )

      written = Agent.get(agent, & &1) |> Enum.join("")
      assert result.completed == false
      assert written =~ "event: error"
      assert written =~ "server_closed_request"
      assert written =~ "internal_error"
    end

    test "returns chunked conn when stream transform raises after headers were sent" do
      upstream = %Req.Response{
        status: 200,
        body: "event: response.output_text.delta\n" <> ~s(data: {"delta":"hi"}) <> "\n\n"
      }

      conn = Plug.Test.conn(:post, "/")

      result =
        Streaming.handle_streaming_response(upstream, conn,
          write_chunk: fn _chunk -> {:ok, nil} end,
          on_event: fn _event, _data, _usage -> raise "transform failed" end
        )

      assert result.completed == false
      assert result.conn.state == :chunked
      assert result.conn.status == 200
    end

    test "passthrough mode also writes SSE error on upstream error" do
      ref = make_ref()
      upstream = %{ref: ref, body: %{ref: ref}}
      conn = Plug.Test.conn(:post, "/")

      agent = start_supervised!({Agent, fn -> [] end})

      # Passthrough mode: no on_event callback — raw SSE error still written
      send(self(), {ref, {:error, "stream broken"}})

      Streaming.handle_streaming_response(upstream, conn,
        write_chunk: fn chunk -> Agent.update(agent, &(&1 ++ [chunk])) end
      )

      written = Agent.get(agent, & &1)
      assert Enum.any?(written, fn chunk -> String.contains?(chunk, "event: error") end)
    end
  end

  # ══════════════════════════════════════════════════
  # Stream state creation
  # ══════════════════════════════════════════════════

  describe "stream state creation" do
    test "create_stream_state/2 initializes correctly" do
      state = Translator.create_stream_state("claude-sonnet-4-6", true)
      assert String.starts_with?(state.chat_id, "chatcmpl-")
      assert state.model == "claude-sonnet-4-6"
      assert state.include_usage == true
      assert state.tool_calls == %{}
      assert state.next_tool_index == 0
    end

    test "make_responses_state/0 initializes correctly" do
      state = Translator.make_responses_state()
      assert String.starts_with?(state.resp_id, "resp_")
      assert String.starts_with?(state.msg_id, "msg_")
      assert state.seq == 0
      assert state.in_text_block == false
      assert state.in_tool_block == false
      assert state.in_thinking_block == false
    end
  end

  # ══════════════════════════════════════════════════
  # Streaming connection state threading
  # ══════════════════════════════════════════════════

  describe "handle_streaming_response/3 — connection state threading" do
    defmodule ThreadingMockAdapter do
      def send_chunked(payload, _status, _headers) do
        {:ok, [], Map.put(payload, :chunk_count, 0)}
      end

      def chunk(payload, _chunk) do
        current = Map.get(payload, :chunk_count, 0)
        {:ok, "", Map.put(payload, :chunk_count, current + 1)}
      end
    end

    test "threads updated conn with chunk count incremented" do
      conn = Plug.Test.conn(:post, "/")
      conn = %{conn | adapter: {ThreadingMockAdapter, %{}}}

      body = "event: message_delta\ndata: {}\n\nevent: message_delta\ndata: {}\n\n"
      upstream = %Req.Response{status: 200, body: body}

      result =
        Streaming.handle_streaming_response(upstream, conn,
          on_event: fn _event, _data, _usage ->
            ["chunk1", "chunk2"]
          end
        )

      {_adapter, payload} = result.conn.adapter
      assert payload.chunk_count == 4
    end
  end

  # ── Helpers ──

  defp extract_sse_type(sse_string) do
    case Regex.run(~r/^event: (.+)\n/, sse_string) do
      [_, type] -> String.trim(type)
      _ -> nil
    end
  end

  defp parse_sse_data(sse_string) do
    case Regex.run(~r/\ndata: (.+)\n/, sse_string) do
      [_, data] -> Jason.decode(data)
      _ -> {:error, :no_data}
    end
  end
end

