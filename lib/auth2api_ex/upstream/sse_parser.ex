defmodule Auth2ApiEx.Upstream.SSEParser do
  @moduledoc """
  RFC 8895-compliant Server-Sent Events parser.

  Mirrors the line-by-line state machine in the Node.js auth2api_ex `streaming.ts`:

      buffer += decoder.decode(value, { stream: true })
      const lines = buffer.split("\\n")
      buffer = lines.pop() ?? ""          // keep incomplete tail
      for (const line of lines) {
        if (line.startsWith("event:")) currentEvent = line.slice(6).trim()
        else if (line.startsWith("data:")) JSON.parse(line.slice(5).trim())
      }

  Key design decisions (matching Node.js):
  - Split on `\\n`; strip trailing `\\r` per-line (handles both LF and CRLF).
  - `event:` and `data:` are **line-level** fields, not block-splitting on `\\n\\n`.
  - Each `data:` line's JSON is parsed independently (Anthropic sends one
    complete JSON per `data:` line). Multiple `data:` lines within a single
    event ARE concatenated per SSE spec, but that never occurs in practice.
  - Strip exactly one optional leading space per SSE spec §6.4
    (`String.replace_prefix(" ", "")`) rather than `String.trim/1`, preserving
    any meaningful trailing whitespace in JSON string values.
  - Comment lines (`:`) are silently ignored.
  - The parser state (current_event, accumulated data_lines, incomplete tail)
    is fully captured in the returned `t:state/0` struct so it survives across
    chunk boundaries without any data loss.
  """

  @typedoc """
  Opaque parser state that must be threaded across successive `parse/2` calls.
  Initialise with `new_state/0`.
  """
  @type state :: %__MODULE__.State{}

  @typedoc "A fully parsed SSE event: `{event_type, decoded_json_map}`."
  @type event :: {String.t(), map()}

  defmodule State do
    @moduledoc false
    defstruct tail: "",
              current_event: "",
              data_lines: []
  end

  @doc "Return a fresh parser state."
  @spec new_state() :: state()
  def new_state, do: %State{}

  @doc """
  Parse SSE events from `chunk` using the given `state`.

  Returns `{events, new_state}` where:
  - `events` — ordered list of `{event_type, parsed_json_map}` tuples.
  - `new_state` — updated state to pass into the next `parse/2` call.

  ## Simple (stateless) usage

  For callers that only need the raw `{events, buffer_string}` interface
  (e.g. tests), use `parse/2` with `new_state()` and extract the tail:

      {events, state} = SSEParser.parse(chunk, SSEParser.new_state())
      buffer = state.tail
  """
  @spec parse(binary(), state()) :: {[event()], state()}
  def parse(chunk, %State{} = state) when is_binary(chunk) do
    full = state.tail <> chunk
    lines = String.split(full, "\n")

    # Everything but the last element is a complete line.
    # The last element is either an incomplete line or "" (chunk ended with \n).
    {complete_lines, new_tail} =
      case Enum.split(lines, -1) do
        {complete, [tail]} -> {complete, tail}
        {[], []} -> {[], ""}
      end

    {events, new_state} =
      Enum.reduce(
        complete_lines,
        {[], %{state | tail: ""}},
        fn raw_line, {evts, st} ->
          # Strip trailing \r so CRLF and LF are treated identically
          line = String.trim_trailing(raw_line, "\r")

          cond do
            # event: field
            String.starts_with?(line, "event:") ->
              event_type = line |> String.slice(6..-1//1) |> String.replace_prefix(" ", "")
              {evts, %{st | current_event: event_type}}

            # data: field — strip exactly one optional leading space (SSE spec §6.4)
            String.starts_with?(line, "data:") ->
              value = line |> String.slice(5..-1//1) |> String.replace_prefix(" ", "")
              {evts, %{st | data_lines: st.data_lines ++ [value]}}

            # Empty line → dispatch the accumulated event, reset event state
            line == "" ->
              evt = dispatch(st.current_event, st.data_lines)
              new_st = %{st | current_event: "", data_lines: []}
              {if(evt, do: evts ++ [evt], else: evts), new_st}

            # Comment (`:`) or unknown field — ignore
            true ->
              {evts, st}
          end
        end
      )

    {events, %{new_state | tail: new_tail}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp dispatch("", _data_lines), do: nil
  defp dispatch(_event_type, []), do: nil

  defp dispatch(event_type, data_lines) do
    data_str = Enum.join(data_lines, "\n")

    case Jason.decode(data_str) do
      {:ok, parsed} -> {event_type, parsed}
      _ -> nil
    end
  end
end
