defmodule Auth2ApiEx.Upstream.CodexResponses do
  @moduledoc """
  Helpers for draining Codex Responses SSE into a non-stream Responses JSON body.

  The ChatGPT Codex backend requires `stream: true` upstream. For downstream
  clients that requested non-streaming `/v1/responses`, we collect the SSE
  stream and rebuild the final Responses object. Real Codex streams often send
  `response.completed.response.output` as an empty array; the actual items are
  emitted earlier as `response.output_item.done` events.
  """

  @type drained :: %{
          text_out: String.t(),
          reasoning_out: String.t(),
          tool_calls: map(),
          output_items: [map()],
          completed_response: map() | nil,
          upstream_error: String.t() | nil,
          status: String.t(),
          usage: map() | nil
        }

  @spec drain_sse_body(binary()) :: drained()
  def drain_sse_body(body) when is_binary(body) do
    initial = %{
      text_out: "",
      reasoning_out: "",
      tool_calls: %{},
      item_id_to_call_id: %{},
      output_items: [],
      completed_response: nil,
      upstream_error: nil,
      status: "completed",
      usage: nil
    }

    body
    |> parse_sse_events()
    |> Enum.reduce(initial, &apply_event/2)
    |> Map.update!(:output_items, &Enum.reverse/1)
    |> Map.drop([:item_id_to_call_id])
  end

  @spec build_response(drained(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def build_response(%{upstream_error: error, completed_response: nil}, _model)
      when is_binary(error) do
    {:error, error}
  end

  def build_response(%{completed_response: completed, output_items: output_items}, _model)
      when is_map(completed) do
    upstream_output = Map.get(completed, "output")

    output =
      if is_list(upstream_output) && upstream_output != [] do
        upstream_output
      else
        output_items
      end

    {:ok, Map.put(completed, "output", output)}
  end

  def build_response(drained, model) do
    output =
      if drained.output_items != [] do
        drained.output_items
      else
        fallback_output(drained)
      end

    {:ok,
     %{
       "id" => "resp_#{System.system_time(:millisecond)}",
       "object" => "response",
       "created_at" => System.system_time(:second),
       "status" => "incomplete",
       "model" => model,
       "output" => output,
       "usage" => drained.usage
     }}
  end

  @spec usage(map()) :: Auth2ApiEx.Accounts.Manager.usage_data()
  def usage(response) do
    u = response["usage"] || %{}

    %{
      input_tokens: u["input_tokens"] || 0,
      output_tokens: u["output_tokens"] || 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: get_in(u, ["input_tokens_details", "cached_tokens"]) || 0,
      reasoning_output_tokens: get_in(u, ["output_tokens_details", "reasoning_tokens"]) || 0
    }
  end

  defp apply_event({"response.output_text.delta", data}, acc) do
    update_text(acc, :text_out, data["delta"])
  end

  defp apply_event({"response.reasoning_summary_text.delta", data}, acc) do
    update_text(acc, :reasoning_out, data["delta"])
  end

  defp apply_event({"response.output_item.added", %{"item" => item}}, acc)
       when is_map(item) do
    if item["type"] == "function_call" && item["call_id"] do
      call_id = item["call_id"]
      item_id = item["id"]
      call = %{id: call_id, name: item["name"] || "", args: ""}

      acc
      |> put_in([:tool_calls, call_id], call)
      |> maybe_map_item_id(item_id, call_id)
    else
      acc
    end
  end

  defp apply_event({"response.output_item.done", %{"item" => item}}, acc)
       when is_map(item) do
    %{acc | output_items: [item | acc.output_items]}
  end

  defp apply_event({"response.function_call_arguments.delta", data}, acc) do
    ref = data["item_id"] || data["call_id"]
    call_id = resolve_call_id(acc, ref)
    delta = data["delta"]

    if call_id && is_binary(delta) do
      update_in(acc, [:tool_calls, call_id, :args], fn existing -> (existing || "") <> delta end)
    else
      acc
    end
  end

  defp apply_event({"response.completed", %{"response" => response}}, acc)
       when is_map(response) do
    %{
      acc
      | completed_response: response,
        usage: response["usage"] || acc.usage,
        status: response["status"] || acc.status
    }
  end

  defp apply_event({"response.failed", data}, acc) do
    message =
      get_in(data, ["response", "error", "message"]) ||
        get_in(data, ["error", "message"]) ||
        "Upstream error"

    %{acc | upstream_error: message}
  end

  defp apply_event(_, acc), do: acc

  defp update_text(acc, key, delta) when is_binary(delta) do
    Map.update!(acc, key, &(&1 <> delta))
  end

  defp update_text(acc, _key, _delta), do: acc

  defp maybe_map_item_id(acc, item_id, call_id)
       when is_binary(item_id) and is_binary(call_id) and item_id != call_id do
    put_in(acc, [:item_id_to_call_id, item_id], call_id)
  end

  defp maybe_map_item_id(acc, _item_id, _call_id), do: acc

  defp resolve_call_id(_acc, nil), do: nil

  defp resolve_call_id(acc, ref),
    do: if(acc.tool_calls[ref], do: ref, else: acc.item_id_to_call_id[ref])

  defp fallback_output(drained) do
    reasoning =
      if drained.reasoning_out != "" do
        [
          %{
            "type" => "reasoning",
            "summary" => [%{"type" => "summary_text", "text" => drained.reasoning_out}]
          }
        ]
      else
        []
      end

    message =
      if drained.text_out != "" do
        [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => drained.text_out}]
          }
        ]
      else
        []
      end

    tool_calls =
      drained.tool_calls
      |> Map.values()
      |> Enum.map(fn tc ->
        %{
          "type" => "function_call",
          "call_id" => tc.id,
          "name" => tc.name,
          "arguments" => tc.args || "{}"
        }
      end)

    reasoning ++ message ++ tool_calls
  end

  defp parse_sse_events(body) do
    body
    |> String.replace("\r\n", "\n")
    |> then(fn data -> data <> "\n\n" end)
    |> String.split(~r/\n\n+/, trim: true)
    |> Enum.flat_map(&parse_sse_block/1)
  end

  defp parse_sse_block(block) do
    lines = String.split(block, "\n")

    event =
      Enum.find_value(lines, fn line ->
        if String.starts_with?(line, "event:"), do: String.trim(String.slice(line, 6..-1//1))
      end)

    data =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", fn line -> String.trim_leading(String.slice(line, 5..-1//1)) end)

    if event && data != "" do
      case Jason.decode(data) do
        {:ok, parsed} -> [{event, parsed}]
        {:error, _} -> []
      end
    else
      []
    end
  end
end
