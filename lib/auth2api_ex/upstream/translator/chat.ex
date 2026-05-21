defmodule Auth2ApiEx.Upstream.Translator.Chat do
  @moduledoc """
  Translation between OpenAI Chat Completions and Anthropic Messages APIs.

  Uses shared helpers from `Auth2ApiEx.Upstream.Translator` for model
  resolution, thinking, image conversion, and tool_choice mapping.
  """

  alias Auth2ApiEx.Upstream.Translator

  # ══════════════════════════════════════════════════════════════════
  # OpenAI Chat Completions → Anthropic Messages
  # ══════════════════════════════════════════════════════════════════

  @doc """
  Translate an OpenAI Chat Completions request to an Anthropic Messages request.
  """
  @spec openai_to_anthropic(map()) :: map()
  def openai_to_anthropic(body) do
    anthropic_body = %{
      "model" => Translator.resolve_model(body["model"] || "claude-sonnet-4-6"),
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
        Translator.apply_thinking(anthropic_body, body["reasoning_effort"])
      else
        anthropic_body
      end

    # response_format → output_config
    anthropic_body =
      if body["response_format"] && body["response_format"]["type"] == "json_schema" &&
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

    # Convert messages
    {messages, system_parts} = convert_chat_messages(body["messages"] || [])

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
        Map.put(
          anthropic_body,
          "tool_choice",
          Translator.convert_tool_choice(body["tool_choice"])
        )
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
      Translator.disable_thinking_if_tool_choice_forced(anthropic_body)
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

  defp convert_content_parts(parts) do
    Enum.map(parts, fn part ->
      if part["type"] == "image_url" && part["image_url"]["url"] do
        Translator.convert_image(part["image_url"]["url"])
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
      "id" => "chatcmpl-#{Translator.compact_uuid()}",
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => Translator.map_stop_reason(anthropic_resp["stop_reason"])
        }
      ],
      "usage" => Translator.format_chat_usage(input_tokens, output_tokens, cached_tokens)
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
end
