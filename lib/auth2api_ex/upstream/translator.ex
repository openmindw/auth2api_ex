defmodule Auth2ApiEx.Upstream.Translator do
  @moduledoc """
  Format translation between OpenAI and Anthropic APIs.
  Handles Chat Completions, Responses API, and streaming SSE conversion.
  """

  alias Auth2ApiEx.Accounts.Manager

  # ── Model alias resolution ──

  @model_aliases %{
    "opus" => "claude-opus-4-6",
    "sonnet" => "claude-sonnet-4-6",
    "haiku" => "claude-haiku-4-5-20251001",
    "claude-opus-4-6" => "claude-opus-4-6",
    "claude-sonnet-4-6" => "claude-sonnet-4-6",
    "claude-haiku-4-5" => "claude-haiku-4-5-20251001"
  }

  @doc """
  Resolve model alias to full model name.
  Unknown models pass through unchanged.
  """
  @spec resolve_model(String.t()) :: String.t()
  def resolve_model(model) do
    Map.get(@model_aliases, model, model)
  end

  # ── Shared: reasoning effort → Anthropic thinking ──

  @effort_to_budget %{
    "none" => 0,
    "low" => 1024,
    "medium" => 8192,
    "high" => 24576,
    "xhigh" => 32768
  }

  def apply_thinking(anthropic_body, effort, summary \\ nil) do
    if effort == "none" do
      Map.put(anthropic_body, "thinking", %{"type" => "disabled"})
    else
      budget = Map.get(@effort_to_budget, effort, 8192)

      anthropic_body =
        Map.put(anthropic_body, "thinking", %{"type" => "enabled", "budget_tokens" => budget})

      anthropic_body =
        if Map.get(anthropic_body, "max_tokens", 8192) <= budget do
          Map.put(anthropic_body, "max_tokens", budget + 4096)
        else
          anthropic_body
        end

      if summary && summary != "auto" do
        put_in(anthropic_body, ["thinking", "display"], "summarized")
      else
        anthropic_body
      end
    end
  end

  def disable_thinking_if_tool_choice_forced(anthropic_body) do
    tc_type = get_in(anthropic_body, ["tool_choice", "type"])

    if tc_type in ["any", "tool"] do
      Map.delete(anthropic_body, "thinking")
    else
      anthropic_body
    end
  end

  # ── Shared: image conversion ──

  def convert_image(url) do
    if String.starts_with?(url, "data:") do
      case Regex.run(~r/^data:([^;]+);base64,(.+)$/, url) do
        [_, media_type, data] ->
          %{
            "type" => "image",
            "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
          }

        _ ->
          %{"type" => "image", "source" => %{"type" => "url", "url" => url}}
      end
    else
      %{"type" => "image", "source" => %{"type" => "url", "url" => url}}
    end
  end

  # ── Shared: tool_choice conversion ──

  def convert_tool_choice(tc) when is_binary(tc) do
    case tc do
      "auto" -> %{"type" => "auto"}
      "required" -> %{"type" => "any"}
      "none" -> %{"type" => "none"}
      _ -> tc
    end
  end

  def convert_tool_choice(tc) when is_map(tc) do
    cond do
      tc["type"] == "auto" ->
        %{"type" => "auto"}

      tc["type"] == "required" ->
        %{"type" => "any"}

      tc["type"] == "none" ->
        %{"type" => "none"}

      tc["type"] == "function" && tc["function"]["name"] ->
        %{"type" => "tool", "name" => tc["function"]["name"]}

      true ->
        tc
    end
  end

  def convert_tool_choice(tc), do: tc

  # ══════════════════════════════════════════════════════════════════
  # OpenAI Chat Completions → Anthropic Messages
  # ══════════════════════════════════════════════════════════════════

  @doc """
  Translate an OpenAI Chat Completions request to an Anthropic Messages request.
  """
  @spec openai_to_anthropic(map()) :: map()
  def openai_to_anthropic(body) do
    anthropic_body = %{
      "model" => resolve_model(body["model"] || "claude-sonnet-4-6"),
      "max_tokens" => body["max_completion_tokens"] || body["max_tokens"] || 8192,
      "stream" => !!body["stream"]
    }

    anthropic_body =
      if body["temperature"] != nil do
        Map.put(anthropic_body, "temperature", body["temperature"])
      else
        anthropic_body
      end

    anthropic_body =
      if body["top_p"] != nil do
        Map.put(anthropic_body, "top_p", body["top_p"])
      else
        anthropic_body
      end

    anthropic_body =
      if body["stop"] do
        stop = if is_list(body["stop"]), do: body["stop"], else: [body["stop"]]
        Map.put(anthropic_body, "stop_sequences", stop)
      else
        anthropic_body
      end

    # Thinking / reasoning
    anthropic_body =
      if body["reasoning_effort"] do
        apply_thinking(anthropic_body, body["reasoning_effort"])
      else
        anthropic_body
      end

    # Convert messages
    {messages, system_parts} = convert_chat_messages(body["messages"] || [])

    system_parts =
      if get_in(body, ["response_format", "type"]) == "json_object" do
        [json_object_system_hint() | system_parts]
      else
        system_parts
      end

    # response_format → output_config or system hint
    anthropic_body =
      if get_in(body, ["response_format", "type"]) == "json_schema" &&
           body["response_format"]["json_schema"] do
        fmt = body["response_format"]["json_schema"]

        Map.put(anthropic_body, "output_config", %{
          "format" => %{
            "type" => "json_schema",
            "schema" => fmt["schema"],
            "name" => fmt["name"]
          }
        })
      else
        anthropic_body
      end

    anthropic_body =
      if length(system_parts) > 0 do
        Map.put(anthropic_body, "system", system_parts)
      else
        anthropic_body
      end

    anthropic_body = Map.put(anthropic_body, "messages", messages)

    # Tools
    anthropic_body =
      if body["tools"] do
        Map.put(anthropic_body, "tools", convert_chat_tools(body["tools"]))
      else
        anthropic_body
      end

    # Tool choice
    anthropic_body =
      if body["tool_choice"] do
        Map.put(anthropic_body, "tool_choice", convert_tool_choice(body["tool_choice"]))
      else
        anthropic_body
      end

    # parallel_tool_calls
    anthropic_body =
      if body["parallel_tool_calls"] == false && anthropic_body["tool_choice"] do
        put_in(anthropic_body, ["tool_choice", "disable_parallel_tool_use"], true)
      else
        anthropic_body
      end

    # Disable thinking if tool_choice is forced
    if anthropic_body["thinking"] && anthropic_body["tool_choice"] do
      disable_thinking_if_tool_choice_forced(anthropic_body)
    else
      anthropic_body
    end
  end

  defp convert_chat_messages(messages) do
    {messages_acc, system_acc} =
      Enum.reduce(messages, {[], []}, fn msg, {msgs, sys} ->
        case msg["role"] do
          "system" ->
            text = extract_system_text(msg["content"])
            {msgs, sys ++ [%{"type" => "text", "text" => text}]}

          "tool" ->
            content =
              if is_binary(msg["content"]) do
                msg["content"]
              else
                Jason.encode!(msg["content"])
              end

            tool_msg = %{
              "role" => "user",
              "content" => [
                %{
                  "type" => "tool_result",
                  "tool_use_id" => msg["tool_call_id"],
                  "content" => content
                }
              ]
            }

            {msgs ++ [tool_msg], sys}

          "assistant" ->
            tool_calls = msg["tool_calls"]

            if is_list(tool_calls) do
              content = []

              content =
                if msg["content"] do
                  text = if is_binary(msg["content"]), do: msg["content"], else: ""
                  [%{"type" => "text", "text" => text} | content]
                else
                  content
                end

              tool_uses =
                Enum.map(tool_calls, fn tc ->
                  input =
                    if tc["function"]["arguments"] do
                      Jason.decode!(tc["function"]["arguments"])
                    else
                      %{}
                    end

                  %{
                    "type" => "tool_use",
                    "id" => tc["id"],
                    "name" => tc["function"]["name"] || "",
                    "input" => input
                  }
                end)

              {msgs ++ [%{"role" => "assistant", "content" => content ++ tool_uses}], sys}
            else
              text = if is_binary(msg["content"]), do: msg["content"], else: ""
              {msgs ++ [%{"role" => "assistant", "content" => text}], sys}
            end

          role ->
            content = msg["content"]

            content =
              if is_list(content) do
                convert_content_parts(content)
              else
                content
              end

            mapped_role = if role == "user", do: "user", else: "assistant"
            {msgs ++ [%{"role" => mapped_role, "content" => content}], sys}
        end
      end)

    {messages_acc, system_acc}
  end

  defp extract_system_text(content) when is_binary(content), do: content

  defp extract_system_text(content) when is_list(content) do
    Enum.map(content, fn c -> c["text"] || "" end)
    |> Enum.join("\n")
  end

  defp extract_system_text(_), do: ""

  defp json_object_system_hint do
    %{
      "type" => "text",
      "text" => "Respond with valid JSON only. Do not include any text outside the JSON object."
    }
  end

  defp append_system_part(anthropic_body, part) do
    Map.update(anthropic_body, "system", [part], fn
      system when is_list(system) -> system ++ [part]
      system when is_binary(system) -> [%{"type" => "text", "text" => system}, part]
      _ -> [part]
    end)
  end

  defp convert_content_parts(parts) do
    Enum.map(parts, fn part ->
      if part["type"] == "image_url" && part["image_url"]["url"] do
        convert_image(part["image_url"]["url"])
      else
        part
      end
    end)
  end

  defp convert_chat_tools(tools) do
    Enum.map(tools, fn t ->
      if t["type"] == "function" && t["function"] do
        %{
          "name" => t["function"]["name"],
          "description" => t["function"]["description"] || "",
          "input_schema" =>
            t["function"]["parameters"] || %{"type" => "object", "properties" => %{}}
        }
      else
        t
      end
    end)
  end

  # ══════════════════════════════════════════════════════════════════
  # Anthropic → OpenAI Chat Completions (non-streaming)
  # ══════════════════════════════════════════════════════════════════

  @doc """
  Translate an Anthropic Messages response to an OpenAI Chat Completions response.
  """
  @spec anthropic_to_openai(map(), String.t()) :: map()
  def anthropic_to_openai(anthropic_resp, model) do
    {text_content, tool_calls} = extract_content_and_tools(anthropic_resp["content"] || [])

    message = %{
      "role" => "assistant",
      "content" => if(text_content == "", do: nil, else: text_content)
    }

    message =
      if length(tool_calls) > 0, do: Map.put(message, "tool_calls", tool_calls), else: message

    input_tokens = get_in(anthropic_resp, ["usage", "input_tokens"]) || 0
    output_tokens = get_in(anthropic_resp, ["usage", "output_tokens"]) || 0
    cached_tokens = get_in(anthropic_resp, ["usage", "cache_read_input_tokens"]) || 0

    %{
      "id" => "chatcmpl-#{compact_uuid()}",
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => map_stop_reason(anthropic_resp["stop_reason"])
        }
      ],
      "usage" => format_chat_usage(input_tokens, output_tokens, cached_tokens)
    }
  end

  defp extract_content_and_tools(content) when is_list(content) do
    Enum.reduce(content, {"", []}, fn block, {text, tools} ->
      case block["type"] do
        "text" ->
          {text <> block["text"], tools}

        "thinking" ->
          {text, tools}

        "tool_use" ->
          tool = %{
            "id" => block["id"],
            "type" => "function",
            "function" => %{
              "name" => block["name"],
              "arguments" => Jason.encode!(block["input"] || %{})
            }
          }

          {text, tools ++ [tool]}

        _ ->
          {text, tools}
      end
    end)
  end

  defp extract_content_and_tools(_), do: {"", []}

  def map_stop_reason("end_turn"), do: "stop"
  def map_stop_reason("max_tokens"), do: "length"
  def map_stop_reason("tool_use"), do: "tool_calls"
  def map_stop_reason(_), do: "stop"

  def format_chat_usage(input_tokens, output_tokens, cached_tokens) do
    %{
      "prompt_tokens" => input_tokens,
      "completion_tokens" => output_tokens,
      "total_tokens" => input_tokens + output_tokens,
      "prompt_tokens_details" => %{"cached_tokens" => cached_tokens},
      "completion_tokens_details" => %{"reasoning_tokens" => 0}
    }
  end

  def format_responses_usage(input_tokens, output_tokens, cached_tokens) do
    %{
      "input_tokens" => input_tokens,
      "output_tokens" => output_tokens,
      "total_tokens" => input_tokens + output_tokens,
      "input_tokens_details" => %{"cached_tokens" => cached_tokens},
      "output_tokens_details" => %{"reasoning_tokens" => 0}
    }
  end

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
      chat_id: "chatcmpl-#{compact_uuid()}",
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
        {[make_chunk(state, %{}, map_stop_reason(stop_reason))], state}

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
                  format_chat_usage(
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

  # ══════════════════════════════════════════════════════════════════
  # OpenAI Responses API → Anthropic Messages
  # ══════════════════════════════════════════════════════════════════

  @doc """
  Translate an OpenAI Responses API request to an Anthropic Messages request.
  Trims stale turns from the input, keeping only the latest turn and any
  function_call items whose call_ids are referenced by function_call_output
  items in the latest turn. This prevents previous_response_not_found errors
  when the client sends a continuation request with a trimmed input.
  """
  @spec responses_to_anthropic(map()) :: map()
  def responses_to_anthropic(body) do
    model = resolve_model(body["model"] || "claude-sonnet-4-6")

    anthropic_body = %{
      "model" => model,
      "max_tokens" => body["max_output_tokens"] || 8192,
      "stream" => !!body["stream"]
    }

    anthropic_body =
      if body["temperature"] != nil do
        Map.put(anthropic_body, "temperature", body["temperature"])
      else
        anthropic_body
      end

    anthropic_body =
      if body["top_p"] != nil do
        Map.put(anthropic_body, "top_p", body["top_p"])
      else
        anthropic_body
      end

    # reasoning.effort → Anthropic thinking
    effort = get_in(body, ["reasoning", "effort"])
    summary = get_in(body, ["reasoning", "summary"])

    anthropic_body =
      if effort && effort != "none" do
        apply_thinking(anthropic_body, effort, summary)
      else
        anthropic_body
      end

    # text.format → output_config or system hint
    anthropic_body =
      case get_in(body, ["text", "format", "type"]) do
        "json_schema" ->
          if get_in(body, ["text", "format", "schema"]) do
            fmt = body["text"]["format"]

            Map.put(anthropic_body, "output_config", %{
              "format" => %{
                "type" => "json_schema",
                "schema" => fmt["schema"],
                "name" => fmt["name"]
              }
            })
          else
            anthropic_body
          end

        "json_object" ->
          append_system_part(anthropic_body, json_object_system_hint())

        _ ->
          anthropic_body
      end

    # instructions → system
    anthropic_body =
      if body["instructions"] do
        append_system_part(
          anthropic_body,
          %{"type" => "text", "text" => body["instructions"]}
        )
      else
        anthropic_body
      end

    # tools
    anthropic_body =
      if is_list(body["tools"]) do
        tools =
          Enum.map(body["tools"], fn t ->
            %{
              "name" => t["name"],
              "description" => t["description"] || "",
              "input_schema" =>
                t["parameters"] || t["input_schema"] || %{"type" => "object", "properties" => %{}}
            }
          end)

        Map.put(anthropic_body, "tools", tools)
      else
        anthropic_body
      end

    # tool_choice
    anthropic_body =
      if body["tool_choice"] do
        Map.put(anthropic_body, "tool_choice", convert_tool_choice(body["tool_choice"]))
      else
        anthropic_body
      end

    # parallel_tool_calls
    anthropic_body =
      if body["parallel_tool_calls"] == false && anthropic_body["tool_choice"] do
        put_in(anthropic_body, ["tool_choice", "disable_parallel_tool_use"], true)
      else
        anthropic_body
      end

    # Disable thinking if tool_choice is forced
    anthropic_body =
      if anthropic_body["thinking"] && anthropic_body["tool_choice"] do
        disable_thinking_if_tool_choice_forced(anthropic_body)
      else
        anthropic_body
      end

    # input[] → messages[] — trim stale turns for continuation requests
    {messages, anthropic_body} =
      convert_responses_input(trim_responses_input(body["input"] || []), anthropic_body)

    Map.put(anthropic_body, "messages", messages)
  end

  # ── Responses API input trimming ──

  @doc """
  Trim a Responses API input array to the latest turn, expanding backward to
  include function_call items whose call_ids are referenced by function_call_output
  items in the latest turn.  Returns the trimmed (or original) list.
  """
  @spec trim_responses_input([map()]) :: [map()]
  def trim_responses_input(input) when is_list(input) do
    case find_latest_turn_start(input) do
      nil -> input
      start when start <= 0 -> input
      start -> Enum.slice(input, start, length(input) - start)
    end
  end

  def trim_responses_input(input), do: input

  # find_latest_turn_start returns the index of the first item in the latest turn.
  # Latest turn = last cluster of: user/assistant msgs + function_call_output items
  # + their matching function_call items.
  defp find_latest_turn_start(items) do
    if length(items) < 3, do: nil, else: find_latest_turn_start(items, length(items) - 1)
  end

  defp find_latest_turn_start(_items, -1), do: nil

  defp find_latest_turn_start(items, idx) do
    item = Enum.at(items, idx)

    cond do
      is_function_call_output?(item) ->
        start = find_consecutive_function_call_outputs(items, idx)
        expand_with_function_calls(items, start)

      item["role"] == "user" ->
        expand_with_function_calls(items, idx)

      true ->
        find_latest_turn_start(items, idx - 1)
    end
  end

  defp find_consecutive_function_call_outputs(items, idx) do
    if idx > 0 && is_function_call_output?(Enum.at(items, idx - 1)),
      do: find_consecutive_function_call_outputs(items, idx - 1),
      else: idx
  end

  defp is_function_call_output?(item) when is_map(item),
    do: item["type"] == "function_call_output"

  defp is_function_call_output?(_), do: false

  defp expand_with_function_calls(items, start_idx) do
    needed = collect_output_call_ids(items, start_idx)

    fc_start =
      if map_size(needed) == 0, do: start_idx, else: expand_backward(items, start_idx - 1, needed)

    # Also include the nearest preceding user/assistant message so the turn is complete
    turn_start = expand_to_earliest_turn_message(items, fc_start)
    turn_start
  end

  defp expand_to_earliest_turn_message(items, from_idx) do
    case from_idx - 1 do
      idx when idx < 0 ->
        0

      idx ->
        prev = Enum.at(items, idx)

        if is_map(prev) && prev["role"] in ["user", "assistant"],
          do: expand_to_earliest_turn_message(items, idx),
          else: from_idx
    end
  end

  defp collect_output_call_ids(items, from_idx) do
    Enum.reduce(Enum.slice(items, from_idx, length(items) - from_idx), %{}, fn item, acc ->
      if is_function_call_output?(item) do
        call_id = item["call_id"] || item["id"] || "" |> String.trim()
        if call_id != "", do: Map.put(acc, call_id, true), else: acc
      else
        acc
      end
    end)
  end

  defp expand_backward(_items, idx, _needed) when idx < 0, do: 0

  defp expand_backward(items, idx, needed) do
    item = Enum.at(items, idx)

    cond do
      is_function_call_item?(item) ->
        call_id = String.trim(item["call_id"] || item["id"] || "")

        if call_id != "" && Map.has_key?(needed, call_id),
          do: idx,
          else: expand_backward(items, idx - 1, needed)

      true ->
        expand_backward(items, idx - 1, needed)
    end
  end

  defp is_function_call_item?(item) when is_map(item),
    do: item["type"] in ["function_call", "tool_call"]

  defp is_function_call_item?(_), do: false

  defp convert_responses_input(input, anthropic_body) do
    {messages, anthropic_body} =
      Enum.reduce(input, {[], anthropic_body}, fn item, {msgs, ab} ->
        role = item["role"]

        cond do
          role == "system" ->
            if !ab["system"] do
              text = extract_responses_text(item["content"])

              ab =
                if text != "" do
                  Map.put(ab, "system", [%{"type" => "text", "text" => text}])
                else
                  ab
                end

              {msgs, ab}
            else
              {msgs, ab}
            end

          role in ["user", "assistant"] ->
            msg =
              cond do
                is_binary(item["content"]) ->
                  %{"role" => role, "content" => item["content"]}

                is_list(item["content"]) ->
                  content = Enum.flat_map(item["content"], &convert_responses_part(&1, role))
                  if length(content) > 0, do: %{"role" => role, "content" => content}, else: nil

                true ->
                  nil
              end

            {if(msg, do: msgs ++ [msg], else: msgs), ab}

          item["type"] == "function_call_output" ->
            output_content =
              if is_binary(item["output"]) do
                item["output"]
              else
                Jason.encode!(item["output"])
              end

            msg = %{
              "role" => "user",
              "content" => [
                %{
                  "type" => "tool_result",
                  "tool_use_id" => item["call_id"],
                  "content" => output_content
                }
              ]
            }

            {msgs ++ [msg], ab}

          item["type"] == "function_call" ->
            input =
              try do
                Jason.decode!(item["arguments"] || "{}")
              rescue
                _ -> %{}
              end

            msg = %{
              "role" => "assistant",
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => item["call_id"] || item["id"],
                  "name" => item["name"],
                  "input" => input
                }
              ]
            }

            {msgs ++ [msg], ab}

          true ->
            {msgs, ab}
        end
      end)

    {messages, anthropic_body}
  end

  defp convert_responses_part(part, _role) when is_nil(part) or not is_map(part), do: []

  defp convert_responses_part(%{"type" => type, "text" => text}, _role)
       when type in ["input_text", "output_text", "text"] do
    [%{"type" => "text", "text" => text || ""}]
  end

  defp convert_responses_part(%{"type" => type} = part, _role)
       when type in ["image", "input_image"] do
    url = get_in(part, ["image_url", "url"]) || part["url"] || ""

    if url != "" do
      [convert_image(url)]
    else
      []
    end
  end

  defp convert_responses_part(%{"type" => type} = part, "assistant")
       when type in ["tool_use", "function_call"] do
    input =
      try do
        Jason.decode!(part["arguments"] || "{}")
      rescue
        _ -> %{}
      end

    [
      %{
        "type" => "tool_use",
        "id" => part["call_id"] || part["id"],
        "name" => part["name"],
        "input" => input
      }
    ]
  end

  defp convert_responses_part(%{"type" => type}, _role)
       when type in ["tool_result", "function_call_output"] do
    # Handled separately in input loop
    []
  end

  defp convert_responses_part(_, _), do: []

  defp extract_responses_text(content) when is_binary(content), do: content

  defp extract_responses_text(content) when is_list(content) do
    Enum.map(content, fn p -> p["text"] || "" end)
    |> Enum.join("\n")
  end

  defp extract_responses_text(_), do: ""

  # ══════════════════════════════════════════════════════════════════
  # Anthropic → OpenAI Responses API (non-streaming)
  # ══════════════════════════════════════════════════════════════════

  @doc """
  Translate an Anthropic Messages response to an OpenAI Responses API response.
  """
  @spec anthropic_to_responses(map(), String.t()) :: map()
  def anthropic_to_responses(anthropic_resp, model) do
    resp_id = "resp_#{compact_uuid()}"
    msg_id = "msg_#{compact_uuid()}"
    created_at = System.system_time(:second)

    {content_parts, tool_calls} = extract_responses_content(anthropic_resp["content"] || [])

    output =
      if length(content_parts) > 0 do
        [
          %{
            "type" => "message",
            "id" => msg_id,
            "role" => "assistant",
            "status" => "completed",
            "content" => content_parts
          }
          | tool_calls
        ]
      else
        tool_calls
      end

    output_text =
      content_parts
      |> Enum.filter(fn p -> p["type"] == "output_text" end)
      |> Enum.map(fn p -> p["text"] end)
      |> Enum.join("")

    stop_reason = anthropic_resp["stop_reason"]
    status = if stop_reason == "max_tokens", do: "incomplete", else: "completed"

    input_tokens = get_in(anthropic_resp, ["usage", "input_tokens"]) || 0
    output_tokens = get_in(anthropic_resp, ["usage", "output_tokens"]) || 0
    cached_tokens = get_in(anthropic_resp, ["usage", "cache_read_input_tokens"]) || 0

    %{
      "id" => resp_id,
      "object" => "response",
      "created_at" => created_at,
      "status" => status,
      "model" => model,
      "output" => output,
      "output_text" => if(output_text == "", do: nil, else: output_text),
      "usage" => format_responses_usage(input_tokens, output_tokens, cached_tokens)
    }
  end

  defp extract_responses_content(content) when is_list(content) do
    Enum.reduce(content, {[], []}, fn block, {parts, tools} ->
      case block["type"] do
        "text" ->
          part = %{"type" => "output_text", "text" => block["text"], "annotations" => []}
          {parts ++ [part], tools}

        "thinking" ->
          if block["thinking"] do
            part = %{
              "type" => "reasoning",
              "summary" => [%{"type" => "summary_text", "text" => block["thinking"]}]
            }

            {parts ++ [part], tools}
          else
            {parts, tools}
          end

        "Read" ->
          pages = block["pages"] || []

          if length(pages) > 0 do
            read_part = %{
              "type" => "read",
              "name" => block["name"] || "",
              "pages" => pages
            }

            {parts ++ [read_part], tools}
          else
            {parts, tools}
          end

        "tool_use" ->
          tool = %{
            "type" => "function_call",
            "id" => "fc_#{block["id"]}",
            "call_id" => block["id"],
            "name" => block["name"],
            "arguments" => Jason.encode!(block["input"] || %{}),
            "status" => "completed"
          }

          {parts, tools ++ [tool]}

        _ ->
          {parts, tools}
      end
    end)
  end

  defp extract_responses_content(_), do: {[], []}

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
      resp_id: "resp_#{compact_uuid()}",
      msg_id: "msg_#{compact_uuid()}",
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
          format_sse(%{
            "type" => "response.created",
            "sequence_number" => next_seq,
            "response" => response
          }),
          format_sse(%{
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
              format_sse(%{
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
              format_sse(%{
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
            reasoning_id = "rs_#{compact_uuid()}"

            state = %{
              state
              | in_thinking_block: true,
                current_thinking_text: "",
                current_reasoning_id: reasoning_id
            }

            {next_seq, state} = next_seq(state)
            {next_seq2, state} = next_seq(state)

            events = [
              format_sse(%{
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
              format_sse(%{
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
              format_sse(%{
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
              format_sse(%{
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
              format_sse(%{
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
              format_sse(%{
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
          format_sse(%{
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
                format_responses_usage(
                  usage.input_tokens,
                  usage.output_tokens,
                  usage.cache_read_input_tokens
                )
            }
          }),
          format_sse(%{"type" => "response.done", "sequence_number" => next_seq2})
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
          format_sse(%{
            "type" => "response.output_text.done",
            "sequence_number" => next_seq,
            "item_id" => state.msg_id,
            "output_index" => idx,
            "content_index" => 0,
            "text" => state.current_text
          }),
          format_sse(%{
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
          format_sse(%{
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
          format_sse(%{
            "type" => "response.reasoning_summary_text.done",
            "sequence_number" => next_seq,
            "item_id" => state.current_reasoning_id,
            "output_index" => idx,
            "summary_index" => 0,
            "text" => state.current_thinking_text
          }),
          format_sse(%{
            "type" => "response.reasoning_summary_part.done",
            "sequence_number" => next_seq2,
            "item_id" => state.current_reasoning_id,
            "output_index" => idx,
            "summary_index" => 0,
            "part" => %{"type" => "summary_text", "text" => state.current_thinking_text}
          }),
          format_sse(%{
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
          format_sse(%{
            "type" => "response.function_call_arguments.done",
            "sequence_number" => next_seq,
            "item_id" => "fc_#{state.current_tool_id}",
            "output_index" => idx,
            "arguments" => state.current_tool_args
          }),
          format_sse(%{
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

  # ── Helpers ──

  def compact_uuid do
    UUID.uuid4() |> String.replace("-", "")
  end

  def format_sse(data) do
    "event: #{data["type"]}\ndata: #{Jason.encode!(data)}\n\n"
  end

  defp next_seq(state) do
    seq = state.seq + 1
    {seq, %{state | seq: seq}}
  end
end
