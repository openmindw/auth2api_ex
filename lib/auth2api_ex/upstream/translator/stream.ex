defmodule Auth2ApiEx.Upstream.Translator.Stream do
  @moduledoc """
  SSE streaming state machines for Chat Completions and Responses API.

  Uses shared helpers from `Auth2ApiEx.Upstream.Translator` for UUID
  generation, SSE formatting, and stop_reason mapping.
  """

  alias Auth2ApiEx.Accounts.Manager
  alias Auth2ApiEx.Upstream.Translator

  # ── Streaming: Chat Completions ──

  defmodule StreamState do
    @moduledoc false
    defstruct chat_id: "", model: "", tool_calls: %{}, next_tool_index: 0, include_usage: true
  end

  @doc """
  Create a new stream state for Chat Completions SSE conversion.
  """
  @spec create_stream_state(String.t(), boolean()) :: %StreamState{}
  def create_stream_state(model, include_usage) do
    %StreamState{
      chat_id: "chatcmpl-#{Translator.compact_uuid()}",
      model: model,
      include_usage: include_usage
    }
  end

  @doc """
  Convert an Anthropic SSE event to OpenAI Chat Completions SSE chunks.
  Returns {events, updated_state} to properly thread tool call state.
  """
  @spec anthropic_sse_to_chat(String.t(), map(), %StreamState{}, Manager.usage_data() | nil) ::
          {[String.t()], %StreamState{}}
  def anthropic_sse_to_chat(event, data, state, usage \\ nil) do
    case event do
      "message_start" ->
        {[make_chunk(state, %{"role" => "assistant", "content" => ""}, nil)], state}

      "content_block_start" ->
        block = data["content_block"]

        if block && block["type"] == "tool_use" do
          idx = state.next_tool_index
          tool_info = %{id: block["id"], name: block["name"], args: "", openai_index: idx}

          new_state = %{
            state
            | tool_calls: Map.put(state.tool_calls, data["index"], tool_info),
              next_tool_index: idx + 1
          }

          chunk =
            make_chunk(
              new_state,
              %{
                "tool_calls" => [
                  %{
                    "index" => idx,
                    "id" => block["id"],
                    "type" => "function",
                    "function" => %{"name" => block["name"], "arguments" => ""}
                  }
                ]
              },
              nil
            )

          {[chunk], new_state}
        else
          {[], state}
        end

      "content_block_delta" ->
        delta_type = get_in(data, ["delta", "type"])

        case delta_type do
          "text_delta" ->
            {[make_chunk(state, %{"content" => data["delta"]["text"]}, nil)], state}

          "thinking_delta" ->
            {[make_chunk(state, %{"reasoning_content" => data["delta"]["thinking"]}, nil)], state}

          "input_json_delta" ->
            tc = Map.get(state.tool_calls, data["index"])

            if tc do
              {[
                 make_chunk(
                   state,
                   %{
                     "tool_calls" => [
                       %{
                         "index" => tc.openai_index,
                         "function" => %{"arguments" => data["delta"]["partial_json"]}
                       }
                     ]
                   },
                   nil
                 )
               ], state}
            else
              {[], state}
            end

          _ ->
            {[], state}
        end

      "message_delta" ->
        stop_reason = get_in(data, ["delta", "stop_reason"]) || "end_turn"
        {[make_chunk(state, %{}, Translator.map_stop_reason(stop_reason))], state}

      "message_stop" ->
        chunks =
          if state.include_usage && usage do
            [
              Jason.encode!(%{
                "id" => state.chat_id,
                "object" => "chat.completion.chunk",
                "created" => System.system_time(:second),
                "model" => state.model,
                "choices" => [],
                "usage" =>
                  Translator.format_chat_usage(
                    usage.input_tokens,
                    usage.output_tokens,
                    usage.cache_read_input_tokens
                  )
              })
            ]
          else
            []
          end

        {chunks ++ ["[DONE]"], state}

      _ ->
        {[], state}
    end
  end

  defp make_chunk(state, delta, finish_reason) do
    Jason.encode!(%{
      "id" => state.chat_id,
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => state.model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}]
    })
  end

  # ── Streaming: Responses API ──

  defmodule ResponsesStreamState do
    @moduledoc false
    defstruct resp_id: "",
              msg_id: "",
              created_at: 0,
              seq: 0,
              in_text_block: false,
              in_thinking_block: false,
              in_tool_block: false,
              current_tool_id: "",
              current_tool_name: "",
              current_text: "",
              current_tool_args: "",
              current_thinking_text: "",
              current_reasoning_id: ""
  end

  @doc """
  Create a new stream state for Responses API SSE conversion.
  """
  @spec make_responses_state() :: %ResponsesStreamState{}
  def make_responses_state do
    %ResponsesStreamState{
      resp_id: "resp_#{Translator.compact_uuid()}",
      msg_id: "msg_#{Translator.compact_uuid()}",
      created_at: System.system_time(:second)
    }
  end

  @doc """
  Convert an Anthropic SSE event to OpenAI Responses API SSE events.
  """
  @spec anthropic_sse_to_responses(
          String.t(),
          map(),
          %ResponsesStreamState{},
          String.t(),
          Manager.usage_data()
        ) ::
          {[String.t()], %ResponsesStreamState{}}
  def anthropic_sse_to_responses(event, data, state, model, usage) do
    case event do
      "message_start" ->
        {next_seq, state} = next_seq(state)

        response = %{
          "id" => state.resp_id,
          "object" => "response",
          "created_at" => state.created_at,
          "status" => "in_progress",
          "model" => model,
          "output" => []
        }

        events = [
          Translator.format_sse(%{
            "type" => "response.created",
            "sequence_number" => next_seq,
            "response" => response
          }),
          Translator.format_sse(%{
            "type" => "response.in_progress",
            "sequence_number" => next_seq,
            "response" => response
          })
        ]

        {events, state}

      "content_block_start" ->
        block = data["content_block"]
        idx = data["index"]

        cond do
          block && block["type"] == "text" ->
            state = %{state | in_text_block: true, current_text: ""}
            {next_seq, state} = next_seq(state)
            {next_seq2, state} = next_seq(state)

            events = [
              Translator.format_sse(%{
                "type" => "response.output_item.added",
                "sequence_number" => next_seq,
                "output_index" => idx,
                "item" => %{
                  "id" => state.msg_id,
                  "type" => "message",
                  "status" => "in_progress",
                  "role" => "assistant",
                  "content" => []
                }
              }),
              Translator.format_sse(%{
                "type" => "response.content_part.added",
                "sequence_number" => next_seq2,
                "item_id" => state.msg_id,
                "output_index" => idx,
                "content_index" => 0,
                "part" => %{"type" => "output_text", "text" => "", "annotations" => []}
              })
            ]

            {events, state}

          block && block["type"] == "thinking" ->
            reasoning_id = "rs_#{Translator.compact_uuid()}"

            state = %{
              state
              | in_thinking_block: true,
                current_thinking_text: "",
                current_reasoning_id: reasoning_id
            }

            {next_seq, state} = next_seq(state)
            {next_seq2, state} = next_seq(state)

            events = [
              Translator.format_sse(%{
                "type" => "response.output_item.added",
                "sequence_number" => next_seq,
                "output_index" => idx,
                "item" => %{
                  "id" => reasoning_id,
                  "type" => "reasoning",
                  "status" => "in_progress",
                  "summary" => []
                }
              }),
              Translator.format_sse(%{
                "type" => "response.reasoning_summary_part.added",
                "sequence_number" => next_seq2,
                "item_id" => reasoning_id,
                "output_index" => idx,
                "summary_index" => 0,
                "part" => %{"type" => "summary_text", "text" => ""}
              })
            ]

            {events, state}

          block && block["type"] == "tool_use" ->
            state = %{
              state
              | in_tool_block: true,
                current_tool_id: block["id"],
                current_tool_name: block["name"],
                current_tool_args: ""
            }

            {next_seq, state} = next_seq(state)

            events = [
              Translator.format_sse(%{
                "type" => "response.output_item.added",
                "sequence_number" => next_seq,
                "output_index" => idx,
                "item" => %{
                  "id" => "fc_#{block["id"]}",
                  "type" => "function_call",
                  "status" => "in_progress",
                  "call_id" => block["id"],
                  "name" => block["name"],
                  "arguments" => ""
                }
              })
            ]

            {events, state}

          true ->
            {[], state}
        end

      "content_block_delta" ->
        delta_type = get_in(data, ["delta", "type"])
        idx = data["index"]

        cond do
          delta_type == "text_delta" ->
            state = %{state | current_text: state.current_text <> data["delta"]["text"]}
            {next_seq, state} = next_seq(state)

            events = [
              Translator.format_sse(%{
                "type" => "response.output_text.delta",
                "sequence_number" => next_seq,
                "item_id" => state.msg_id,
                "output_index" => idx,
                "content_index" => 0,
                "delta" => data["delta"]["text"]
              })
            ]

            {events, state}

          delta_type == "thinking_delta" ->
            state = %{
              state
              | current_thinking_text: state.current_thinking_text <> data["delta"]["thinking"]
            }

            {next_seq, state} = next_seq(state)

            events = [
              Translator.format_sse(%{
                "type" => "response.reasoning_summary_text.delta",
                "sequence_number" => next_seq,
                "item_id" => state.current_reasoning_id,
                "output_index" => idx,
                "summary_index" => 0,
                "delta" => data["delta"]["thinking"]
              })
            ]

            {events, state}

          delta_type == "input_json_delta" ->
            state = %{
              state
              | current_tool_args: state.current_tool_args <> data["delta"]["partial_json"]
            }

            {next_seq, state} = next_seq(state)

            events = [
              Translator.format_sse(%{
                "type" => "response.function_call_arguments.delta",
                "sequence_number" => next_seq,
                "item_id" => "fc_#{state.current_tool_id}",
                "output_index" => idx,
                "delta" => data["delta"]["partial_json"]
              })
            ]

            {events, state}

          true ->
            {[], state}
        end

      "content_block_stop" ->
        idx = data["index"]
        {events, state} = handle_content_block_stop(state, idx)
        {events, state}

      "message_stop" ->
        {next_seq, state} = next_seq(state)
        {next_seq2, state} = next_seq(state)

        events = [
          Translator.format_sse(%{
            "type" => "response.completed",
            "sequence_number" => next_seq,
            "response" => %{
              "id" => state.resp_id,
              "object" => "response",
              "created_at" => state.created_at,
              "status" => "completed",
              "model" => model,
              "output" => [],
              "usage" =>
                Translator.format_responses_usage(
                  usage.input_tokens,
                  usage.output_tokens,
                  usage.cache_read_input_tokens
                )
            }
          }),
          Translator.format_sse(%{"type" => "response.done", "sequence_number" => next_seq2})
        ]

        {events, state}

      _ ->
        {[], state}
    end
  end

  defp handle_content_block_stop(state, idx) do
    cond do
      state.in_text_block ->
        {next_seq, state} = next_seq(state)
        {next_seq2, state} = next_seq(state)
        {next_seq3, state} = next_seq(state)

        events = [
          Translator.format_sse(%{
            "type" => "response.output_text.done",
            "sequence_number" => next_seq,
            "item_id" => state.msg_id,
            "output_index" => idx,
            "content_index" => 0,
            "text" => state.current_text
          }),
          Translator.format_sse(%{
            "type" => "response.content_part.done",
            "sequence_number" => next_seq2,
            "item_id" => state.msg_id,
            "output_index" => idx,
            "content_index" => 0,
            "part" => %{
              "type" => "output_text",
              "text" => state.current_text,
              "annotations" => []
            }
          }),
          Translator.format_sse(%{
            "type" => "response.output_item.done",
            "sequence_number" => next_seq3,
            "output_index" => idx,
            "item" => %{
              "id" => state.msg_id,
              "type" => "message",
              "status" => "completed",
              "role" => "assistant",
              "content" => []
            }
          })
        ]

        state = %{state | in_text_block: false, current_text: ""}
        {events, state}

      state.in_thinking_block ->
        {next_seq, state} = next_seq(state)
        {next_seq2, state} = next_seq(state)
        {next_seq3, state} = next_seq(state)

        events = [
          Translator.format_sse(%{
            "type" => "response.reasoning_summary_text.done",
            "sequence_number" => next_seq,
            "item_id" => state.current_reasoning_id,
            "output_index" => idx,
            "summary_index" => 0,
            "text" => state.current_thinking_text
          }),
          Translator.format_sse(%{
            "type" => "response.reasoning_summary_part.done",
            "sequence_number" => next_seq2,
            "item_id" => state.current_reasoning_id,
            "output_index" => idx,
            "summary_index" => 0,
            "part" => %{"type" => "summary_text", "text" => state.current_thinking_text}
          }),
          Translator.format_sse(%{
            "type" => "response.output_item.done",
            "sequence_number" => next_seq3,
            "output_index" => idx,
            "item" => %{
              "id" => state.current_reasoning_id,
              "type" => "reasoning",
              "status" => "completed",
              "summary" => [%{"type" => "summary_text", "text" => state.current_thinking_text}]
            }
          })
        ]

        state = %{state | in_thinking_block: false, current_thinking_text: ""}
        {events, state}

      state.in_tool_block ->
        {next_seq, state} = next_seq(state)

        events = [
          Translator.format_sse(%{
            "type" => "response.function_call_arguments.done",
            "sequence_number" => next_seq,
            "item_id" => "fc_#{state.current_tool_id}",
            "output_index" => idx,
            "arguments" => state.current_tool_args
          }),
          Translator.format_sse(%{
            "type" => "response.output_item.done",
            "sequence_number" => next_seq,
            "output_index" => idx,
            "item" => %{
              "id" => "fc_#{state.current_tool_id}",
              "type" => "function_call",
              "status" => "completed",
              "call_id" => state.current_tool_id,
              "name" => state.current_tool_name,
              "arguments" => state.current_tool_args
            }
          })
        ]

        state = %{state | in_tool_block: false, current_tool_args: ""}
        {events, state}

      true ->
        {[], state}
    end
  end

  defp next_seq(state) do
    seq = state.seq + 1
    {seq, %{state | seq: seq}}
  end
end
