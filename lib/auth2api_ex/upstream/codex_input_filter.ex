defmodule Auth2ApiEx.Upstream.CodexInputFilter do
  @moduledoc """
  Filters and normalizes Codex Responses `input` array for upstream compatibility.

  The chatgpt.com/backend-api Codex endpoint rejects dirty input:
  - Stale `call_id` references in `function_call_output` cause 400/422
  - Orphan `function_call` items with no matching output cause errors
  - `role: "tool"` messages are not accepted — must be `function_call_output`
  - `call_id` prefix must be `fc_` (internal format), not public `call_`
  - `reasoning` items reference rs_* IDs that are never persisted (store=false)
  - Stale `previous_response_id` when input carries a full conversation

  Integration point: piped into `CodexAPI.transform_body/2` after `normalize_input/1`.
  """

  @tool_call_types ~w(
    function_call
    tool_call
    local_shell_call
    tool_search_call
    custom_tool_call
    mcp_tool_call
  )

  @tool_call_output_types ~w(
    function_call_output
    mcp_tool_call_output
    custom_tool_call_output
    tool_search_output
  )

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Normalize all `call_id` values in `body["input"]` to `fc_` prefix format.

  The chatgpt.com codex backend uses `fc_` (internal) rather than `call_`
  (public) for item IDs. This function:
  - Converts `call_XXX` → `fcXXX` on tool call items and item_references
  - Adds `fc_` prefix to bare IDs (e.g. `abc123` → `fc_abc123`)
  - Leaves `fcXXX` items unchanged
  - Strips spurious `call_id` from non-tool-call items
  """
  @spec fix_call_id_prefix(map()) :: map()
  def fix_call_id_prefix(%{"input" => input} = body) when is_list(input) do
    Map.put(body, "input", fix_call_ids(input))
  end

  def fix_call_id_prefix(body), do: body

  @doc """
  Convert `role: "tool"` input messages into `function_call_output` items.

  The Codex endpoint does not accept `role: "tool"` (a /v1/chat/completions
  convention). Each such message is rewritten to a Responses-native
  `function_call_output` item with `call_id` and `output`.
  """
  @spec normalize_tool_role_messages(map()) :: map()
  def normalize_tool_role_messages(%{"input" => input} = body) when is_list(input) do
    Map.put(body, "input", normalize_tool_roles(input))
  end

  def normalize_tool_role_messages(body), do: body

  @doc """
  Filter stale / orphan items from `body["input"]` and clear stale
  `previous_response_id`.

  Removes:
  - `reasoning` items (rs_* IDs not persisted when store=false)
  - `function_call_output` items whose `call_id` has no matching `function_call`
  - Orphan `function_call` items with no matching output or item_reference

  Clears `previous_response_id` when the input already contains a full
  conversation (non-empty user/assistant messages).
  """
  @spec filter_input(map()) :: map()
  def filter_input(%{"input" => input} = body) when is_list(input) do
    # Collect call_ids from function_call items
    fc_ids = collect_call_ids(input, @tool_call_types)

    # Collect call_ids referenced by function_call_output and item_reference
    output_refs = collect_output_refs(input)

    filtered =
      input
      |> drop_reasoning_items()
      |> drop_orphan_outputs(fc_ids)
      |> drop_orphan_calls(output_refs)

    body
    |> Map.put("input", filtered)
    |> maybe_clear_previous_response_id(filtered)
  end

  def filter_input(body), do: body

  # ── call_id prefix normalization ────────────────────────────────

  defp fix_call_ids(input) do
    Enum.map(input, fn item ->
      case item do
        %{"type" => "item_reference"} -> fix_item_reference_id(item)
        %{"type" => type} = m when type in @tool_call_types -> fix_tool_call_id(m)
        %{"type" => type} = m when type in @tool_call_output_types -> fix_tool_call_id(m)
        _ -> Map.delete(item, "call_id")
      end
    end)
  end

  defp fix_item_reference_id(item) do
    case item do
      %{"id" => id} when is_binary(id) and id != "" ->
        if String.starts_with?(id, "call_") do
          Map.put(item, "id", "fc" <> String.trim_leading(id, "call_"))
        else
          item
        end

      _ ->
        item
    end
  end

  defp fix_tool_call_id(item) do
    call_id = item["call_id"] || item["id"]

    case call_id do
      v when is_binary(v) and v != "" ->
        item
        |> Map.put("call_id", normalize_call_id(v))
        |> Map.delete("id")

      _ ->
        item
        |> Map.delete("call_id")
        |> Map.delete("id")
    end
  end

  defp normalize_call_id(id) when is_binary(id) do
    cond do
      String.starts_with?(id, "fc") -> id
      String.starts_with?(id, "call_") -> "fc" <> String.trim_leading(id, "call_")
      true -> "fc_" <> id
    end
  end

  # ── tool role normalization ─────────────────────────────────────

  defp normalize_tool_roles(input) do
    Enum.map(input, fn
      %{"role" => "tool"} = msg ->
        call_id =
          msg["tool_call_id"] || msg["call_id"] || msg["id"] ||
            ""

        call_id = String.trim(call_id)

        output = extract_text_content(msg["content"])

        if call_id != "" do
          %{
            "type" => "function_call_output",
            "call_id" => call_id,
            "output" => output
          }
        else
          # No call_id available — cannot construct valid function_call_output.
          # Fall back to a user message so the text is preserved.
          msg
          |> Map.put("role", "user")
          |> Map.delete("tool_call_id")
          |> Map.delete("call_id")
        end

      other ->
        other
    end)
  end

  defp extract_text_content(content) when is_binary(content), do: content

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("", &Map.get(&1, "text", ""))
  end

  defp extract_text_content(content) when is_map(content) do
    case Jason.encode(content) do
      {:ok, s} -> s
      _ -> ""
    end
  end

  defp extract_text_content(_), do: ""

  # ── input filtering ─────────────────────────────────────────────

  defp drop_reasoning_items(input) do
    Enum.reject(input, fn
      %{"type" => "reasoning"} -> true
      _ -> false
    end)
  end

  defp collect_call_ids(input, tool_call_types) do
    input
    |> Enum.filter(&(is_map(&1) and &1["type"] in tool_call_types))
    |> Enum.map(& &1["call_id"])
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp collect_output_refs(input) do
    output_refs =
      input
      |> Enum.filter(fn
        %{"type" => t} when t in @tool_call_output_types -> true
        %{"type" => "item_reference"} -> true
        _ -> false
      end)
      |> Enum.map(fn
        %{"type" => "item_reference"} = item -> item["id"]
        %{"call_id" => call_id} -> call_id
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    MapSet.new(output_refs)
  end

  defp drop_orphan_outputs(input, fc_ids) do
    Enum.reject(input, fn
      %{"type" => t, "call_id" => call_id} when t in @tool_call_output_types ->
        not MapSet.member?(fc_ids, call_id)

      _ ->
        false
    end)
  end

  defp drop_orphan_calls(input, output_refs) do
    Enum.reject(input, fn
      %{"type" => t, "call_id" => call_id} when t in @tool_call_types ->
        not MapSet.member?(output_refs, call_id)

      _ ->
        false
    end)
  end

  defp maybe_clear_previous_response_id(body, input) do
    has_conversation? =
      Enum.any?(input, fn
        %{"role" => r} when r in ~w(user assistant) -> true
        _ -> false
      end)

    if has_conversation? do
      body
      |> Map.delete("previous_response_id")
    else
      body
    end
  end
end
