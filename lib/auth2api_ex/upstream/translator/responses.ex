defmodule Auth2ApiEx.Upstream.Translator.Responses do
  @moduledoc """
  Translation between OpenAI Responses API and Anthropic Messages API.

  Uses shared helpers from `Auth2ApiEx.Upstream.Translator` for model
  resolution, thinking, image conversion, and tool_choice mapping.
  """

  alias Auth2ApiEx.Upstream.Translator

  # ══════════════════════════════════════════════════════════════════
  # OpenAI Responses API → Anthropic Messages
  # ══════════════════════════════════════════════════════════════════

  @doc """
  Translate an OpenAI Responses API request to an Anthropic Messages request.
  """
  @spec responses_to_anthropic(map()) :: map()
  def responses_to_anthropic(body) do
    model = Translator.resolve_model(body["model"] || "claude-sonnet-4-6")

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
        Translator.apply_thinking(anthropic_body, effort, summary)
      else
        anthropic_body
      end

    # text.format → output_config
    anthropic_body =
      if get_in(body, ["text", "format", "type"]) == "json_schema" &&
           get_in(body, ["text", "format", "schema"]) do
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

    # instructions → system
    anthropic_body =
      if body["instructions"] do
        Map.put(anthropic_body, "system", [%{"type" => "text", "text" => body["instructions"]}])
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
    anthropic_body =
      if anthropic_body["thinking"] && anthropic_body["tool_choice"] do
        Translator.disable_thinking_if_tool_choice_forced(anthropic_body)
      else
        anthropic_body
      end

    # input[] → messages[]
    {messages, anthropic_body} = convert_responses_input(body["input"] || [], anthropic_body)
    Map.put(anthropic_body, "messages", messages)
  end

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
      [Translator.convert_image(url)]
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
    resp_id = "resp_#{Translator.compact_uuid()}"
    msg_id = "msg_#{Translator.compact_uuid()}"
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
      "usage" => Translator.format_responses_usage(input_tokens, output_tokens, cached_tokens)
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
end
