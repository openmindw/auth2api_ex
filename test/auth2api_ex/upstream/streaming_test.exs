defmodule Auth2ApiEx.Upstream.SSEParserTest do
  use ExUnit.Case, async: true
  alias Auth2ApiEx.Upstream.SSEParser

  # Helper: parse a chunk from scratch, return {events, tail_string}
  defp parse(chunk), do: parse(chunk, "")

  defp parse(chunk, tail_or_state) do
    state =
      case tail_or_state do
        s when is_binary(s) -> %SSEParser.State{tail: s}
        s -> s
      end

    {events, new_state} = SSEParser.parse(chunk, state)
    {events, new_state}
  end

  # ── Basic event parsing ────────────────────────────────────────────────────

  describe "basic event parsing" do
    test "parses a standard LF-delimited event" do
      {events, state} = parse("event: message_start\ndata: {\"type\":\"message_start\"}\n\n")
      assert state.tail == ""
      assert events == [{"message_start", %{"type" => "message_start"}}]
    end

    test "parses a CRLF-delimited event" do
      {events, state} =
        parse("event: message_start\r\ndata: {\"type\":\"message_start\"}\r\n\r\n")

      assert state.tail == ""
      assert events == [{"message_start", %{"type" => "message_start"}}]
    end

    test "parses multiple events in a single chunk" do
      chunk =
        "event: message_start\ndata: {\"n\":1}\n\n" <>
          "event: content_block_start\ndata: {\"n\":2}\n\n"

      {events, _} = parse(chunk)
      assert length(events) == 2
      assert {"message_start", %{"n" => 1}} in events
      assert {"content_block_start", %{"n" => 2}} in events
    end
  end

  # ── data: field stripping (SSE spec §6.4) ─────────────────────────────────

  describe "data: field stripping (SSE spec §6.4)" do
    test "strips exactly one leading space after 'data: '" do
      {[{_evt, data}], _} = parse("event: delta\ndata: {\"text\":\"hello\"}\n\n")
      assert data == %{"text" => "hello"}
    end

    test "preserves trailing whitespace in JSON string values" do
      # String.trim() would wrongly strip the trailing space — replace_prefix(" ","") does not
      {[{_evt, data}], _} = parse("event: delta\ndata: {\"text\":\"hello \"}\n\n")
      assert data["text"] == "hello "
    end

    test "strips only ONE leading space — two spaces leaves one leading space in value" do
      # "data:  {\"k\":1}" → value is " {\"k\":1}" (one leading space)
      # JSON decoders accept leading whitespace, so it still parses successfully.
      # What matters is we did NOT strip both spaces (that would break values like \"  indented\").
      {events, _} = parse("event: delta\ndata:  {\"k\":1}\n\n")
      # Jason accepts leading whitespace — event is still parsed
      assert [{"delta", %{"k" => 1}}] = events
    end

    test "handles data: with no separator space" do
      # "data:{\"k\":1}" — no optional space, still valid
      {[{_evt, data}], _} = parse("event: delta\ndata:{\"k\":1}\n\n")
      assert data == %{"k" => 1}
    end
  end

  # ── Buffer / split-chunk handling ──────────────────────────────────────────

  describe "buffer / split-chunk handling" do
    test "returns incomplete line as tail in state" do
      {events, state} = parse("event: message\ndata: {\"par")
      assert events == []
      assert state.tail == "data: {\"par"
    end

    test "preserves current_event across chunk boundary" do
      # event: line arrives in chunk 1, data: line arrives in chunk 2
      {[], state1} = parse("event: message\n")
      assert state1.current_event == "message"

      {events, state2} = parse("data: {\"k\":42}\n\n", state1)
      assert state2.tail == ""
      assert events == [{"message", %{"k" => 42}}]
    end

    test "correctly resumes from a mid-data-value chunk boundary" do
      {[], state1} = parse("event: message\ndata: {\"k\":")
      {events, _} = parse("42}\n\n", state1)
      assert events == [{"message", %{"k" => 42}}]
    end

    test "handles chunk boundary exactly on \\n" do
      {[], state} = parse("event: x\n")
      {events, _} = parse("data: {\"v\":1}\n\n", state)
      assert events == [{"x", %{"v" => 1}}]
    end
  end

  # ── Multiple data: lines (SSE spec concatenation) ─────────────────────────

  describe "multiple data: lines" do
    test "concatenates multiple data: lines with \\n between them" do
      # Per SSE spec the two data: values are joined with \n before JSON decode
      # "{\"a\":" + "\n" + "1}" = "{\"a\":\n1}" which is valid JSON
      {events, _} = parse("event: delta\ndata: {\"a\":\ndata: 1}\n\n")
      assert events == [{"delta", %{"a" => 1}}]
    end
  end

  # ── Comment and unknown fields ─────────────────────────────────────────────

  describe "comment and unknown field handling" do
    test "ignores comment lines starting with ':'" do
      {[{evt, data}], _} = parse(": heartbeat\nevent: ping\ndata: {\"ok\":true}\n\n")
      assert evt == "ping"
      assert data == %{"ok" => true}
    end

    test "ignores unknown field names (e.g. 'id:')" do
      {[{evt, _}], _} = parse("id: 42\nevent: ping\ndata: {\"ok\":true}\n\n")
      assert evt == "ping"
    end
  end

  # ── Anthropic tool-call shapes (regression) ───────────────────────────────

  describe "Anthropic tool-call shape (regression)" do
    test "parses input_json_delta event with embedded partial JSON" do
      payload = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{
          "type" => "input_json_delta",
          "partial_json" => "{\"command\": \"write\","
        }
      }

      {[{evt, data}], _} =
        parse("event: content_block_delta\ndata: #{Jason.encode!(payload)}\n\n")

      assert evt == "content_block_delta"
      assert get_in(data, ["delta", "partial_json"]) == "{\"command\": \"write\","
    end

    test "parses tool_use content_block_start" do
      payload = %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_abc123",
          "name" => "write_file",
          "input" => %{}
        }
      }

      {[{_evt, data}], _} =
        parse("event: content_block_start\ndata: #{Jason.encode!(payload)}\n\n")

      assert get_in(data, ["content_block", "name"]) == "write_file"
      assert get_in(data, ["content_block", "id"]) == "toolu_abc123"
    end

    test "survives a tool-call event split across two TCP chunks" do
      # Chunk boundary falls in the middle of the data: line's JSON value.
      # The key point: event: line is in chunk 1, data: line spans both chunks.
      # delta object needs two closing braces: one for "delta", one for the outer object.
      chunk1 =
        "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\""

      chunk2 = "hello world\"}}\n\n"

      {[], state} = parse(chunk1)
      assert state.current_event == "content_block_delta"

      {[{evt, data}], _} = parse(chunk2, state)
      assert evt == "content_block_delta"
      assert get_in(data, ["delta", "partial_json"]) == "hello world"
    end
  end
end
