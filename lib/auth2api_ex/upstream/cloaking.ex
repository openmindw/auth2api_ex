defmodule Auth2ApiEx.Upstream.Cloaking do
  @moduledoc """
  Request cloaking — injects Claude Code CLI billing headers, prefix, and metadata
  to make upstream requests appear as if they come from the real Claude Code CLI.
  """

  alias Auth2ApiEx.Utils.Common

  @fingerprint_salt "59cf53e54c78"

  @doc """
  Test-only entry point for billing header generation.
  Do NOT use from app code.
  """
  def generate_billing_header_for_test(messages, version, entrypoint, workload \\ nil) do
    generate_billing_header(messages, version, entrypoint, workload)
  end

  @doc """
  Test-only entry point for workload derivation.
  Do NOT use from app code.
  """
  def derive_workload_for_test(conn) do
    derive_workload(nil, conn)
  end

  @doc """
  Apply Claude Code cloaking to the request body.
  Injects billing header, CLI prefix, and metadata.
  """
  @spec apply_cloaking(map(), Plug.Conn.t(), map(), map()) :: map()
  def apply_cloaking(body, conn, account, config) do
    cli_version = get_in(config.cloaking, [:cli_version]) || "2.1.88"
    entrypoint = get_in(config.cloaking, [:entrypoint]) || "cli"

    # Deep clone body
    body = deep_clone(body)

    # --- System prompt injection ---
    existing_system = body["system"] || []

    remaining =
      if is_list(existing_system),
        do: existing_system,
        else: [%{"type" => "text", "text" => existing_system}]

    # Extract existing billing header and prefix
    {billing_block, remaining} = extract_and_remove(remaining, &is_billing_header_block?/1)

    workload = derive_workload(account, conn)

    billing_block =
      billing_block ||
        %{
          "type" => "text",
          "text" =>
            generate_billing_header(body["messages"] || [], cli_version, entrypoint, workload)
        }

    {prefix_block, remaining} = extract_and_remove(remaining, &is_prefix_block?/1)

    prefix_block =
      prefix_block ||
        %{
          "type" => "text",
          "text" => "You are Claude Code, Anthropic's official CLI for Claude.",
          "cache_control" => %{"type" => "ephemeral"}
        }

    body = Map.put(body, "system", [billing_block, prefix_block | remaining])

    # --- Metadata injection ---
    api_key_hash = Common.hash_api_key(Common.extract_api_key(conn))

    session_id =
      case Plug.Conn.get_req_header(conn, "x-claude-code-session-id") do
        [id | _] -> id
        _ -> Auth2ApiEx.Upstream.AnthropicAPI.get_session_id(api_key_hash)
      end

    metadata = Map.get(body, "metadata", %{})

    metadata =
      Map.put(
        metadata,
        "user_id",
        build_user_id(account.device_id, account.account_uuid, session_id)
      )

    body = Map.put(body, "metadata", metadata)

    body
  end

  # ── Private helpers ──

  defp generate_billing_header(messages, version, entrypoint, workload) do
    msg_text = extract_first_user_message_text(messages)
    fp = compute_fingerprint(msg_text, version)
    workload_pair = if workload, do: " cc_workload=#{workload};", else: ""

    "x-anthropic-billing-header: cc_version=#{version}.#{fp}; cc_entrypoint=#{entrypoint};#{workload_pair}"
  end

  defp derive_workload(_account, conn) do
    # Check for workload cookie (e.g., channel=cli, channel=web, channel=cron)
    case Plug.Conn.get_req_header(conn, "x-auth2api_ex-workload") do
      [tag | _] when tag != "" -> tag
      _ -> nil
    end
  end

  defp compute_fingerprint(message_text, version) do
    indices = [4, 7, 20]

    chars =
      indices
      |> Enum.map(fn i -> String.at(message_text, i) || "0" end)
      |> Enum.join()

    input = "#{@fingerprint_salt}#{chars}#{version}"

    :crypto.hash(:sha256, input)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 3)
  end

  defp extract_first_user_message_text(messages) when is_list(messages) do
    case Enum.find(messages, fn m -> m["role"] == "user" end) do
      nil ->
        ""

      msg ->
        cond do
          is_binary(msg["content"]) ->
            msg["content"]

          is_list(msg["content"]) ->
            case Enum.find(msg["content"], fn b -> b["type"] == "text" end) do
              nil -> ""
              block -> block["text"] || ""
            end

          true ->
            ""
        end
    end
  end

  defp extract_first_user_message_text(_), do: ""

  defp build_user_id(device_id, account_uuid, session_id) do
    Jason.encode!(%{
      "device_id" => device_id,
      "account_uuid" => account_uuid,
      "session_id" => session_id
    })
  end

  defp is_billing_header_block?(block) do
    is_map(block) && is_binary(block["text"]) &&
      String.contains?(block["text"], "x-anthropic-billing-header")
  end

  defp is_prefix_block?(block) do
    is_map(block) && is_binary(block["text"]) &&
      String.contains?(block["text"], "You are Claude Code")
  end

  defp extract_and_remove(list, predicate) do
    case Enum.split_with(list, predicate) do
      {[found | _], remaining} -> {found, remaining}
      {[], remaining} -> {nil, remaining}
    end
  end

  defp deep_clone(body) when is_map(body) do
    # Use Jason for deep clone
    Jason.decode!(Jason.encode!(body))
  end

  defp deep_clone(body), do: body
end
