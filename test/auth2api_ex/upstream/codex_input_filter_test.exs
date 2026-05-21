defmodule Auth2ApiEx.Upstream.CodexInputFilterTest do
  use ExUnit.Case, async: true
  alias Auth2ApiEx.Upstream.CodexInputFilter

  # ══════════════════════════════════════════════════
  # fix_call_id_prefix/1
  # ══════════════════════════════════════════════════

  describe "fix_call_id_prefix/1" do
    test "converts call_ prefix to fc prefix on function_call items" do
      body = %{
        "input" => [
          %{
            "type" => "function_call",
            "call_id" => "call_1",
            "name" => "tool",
            "arguments" => "{}"
          },
          %{"type" => "function_call_output", "call_id" => "call_1", "output" => "ok"}
        ]
      }

      out = CodexInputFilter.fix_call_id_prefix(body)
      input = out["input"]

      assert length(input) == 2
      assert Enum.at(input, 0)["call_id"] == "fc1"
      assert Enum.at(input, 1)["call_id"] == "fc1"
    end

    test "adds fc_ prefix to bare call_ids (no prefix)" do
      body = %{
        "input" => [
          %{
            "type" => "function_call",
            "call_id" => "abc123",
            "name" => "tool",
            "arguments" => "{}"
          }
        ]
      }

      out = CodexInputFilter.fix_call_id_prefix(body)
      assert hd(out["input"])["call_id"] == "fc_abc123"
    end

    test "leaves fc-prefixed call_ids unchanged" do
      body = %{
        "input" => [
          %{
            "type" => "function_call",
            "call_id" => "fc789",
            "name" => "tool",
            "arguments" => "{}"
          }
        ]
      }

      out = CodexInputFilter.fix_call_id_prefix(body)
      assert hd(out["input"])["call_id"] == "fc789"
    end

    test "handles custom_tool_call and mcp_tool_call" do
      body = %{
        "input" => [
          %{
            "type" => "custom_tool_call",
            "call_id" => "call_custom",
            "name" => "shell",
            "input" => "pwd"
          },
          %{
            "type" => "mcp_tool_call",
            "call_id" => "call_mcp",
            "name" => "remote",
            "arguments" => "{}"
          }
        ]
      }

      out = CodexInputFilter.fix_call_id_prefix(body)
      input = out["input"]
      assert Enum.at(input, 0)["call_id"] == "fccustom"
      assert Enum.at(input, 1)["call_id"] == "fcmcp"
    end

    test "fixes item_reference id prefix from call_ to fc" do
      body = %{
        "input" => [
          %{"type" => "item_reference", "id" => "call_1"},
          %{"type" => "function_call_output", "call_id" => "call_1", "output" => "ok"}
        ]
      }

      out = CodexInputFilter.fix_call_id_prefix(body)
      input = out["input"]
      assert Enum.at(input, 0)["id"] == "fc1"
      assert Enum.at(input, 1)["call_id"] == "fc1"
    end

    test "does not change non-call_ item_reference ids" do
      body = %{
        "input" => [
          %{"type" => "item_reference", "id" => "rs_123"}
        ]
      }

      out = CodexInputFilter.fix_call_id_prefix(body)
      assert hd(out["input"])["id"] == "rs_123"
    end

    test "strips call_id from non-tool-call items" do
      body = %{
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "hi", "call_id" => "call_bad"},
          %{
            "type" => "image_generation_call",
            "id" => "ig_1",
            "status" => "completed",
            "call_id" => "call_bad"
          }
        ]
      }

      out = CodexInputFilter.fix_call_id_prefix(body)
      refute Map.has_key?(hd(out["input"]), "call_id")
    end

    test "handles function_call with id fallback for call_id" do
      body = %{
        "input" => [
          %{"type" => "function_call", "id" => "call_42", "name" => "tool", "arguments" => "{}"}
        ]
      }

      out = CodexInputFilter.fix_call_id_prefix(body)
      item = hd(out["input"])
      assert item["call_id"] == "fc42"
      refute Map.has_key?(item, "id")
    end

    test "handles empty input" do
      body = %{"input" => []}
      out = CodexInputFilter.fix_call_id_prefix(body)
      assert out["input"] == []
    end

    test "passes through body without input key" do
      body = %{"model" => "gpt-5.4"}
      out = CodexInputFilter.fix_call_id_prefix(body)
      assert out == body
    end
  end

  # ══════════════════════════════════════════════════
  # normalize_tool_role_messages/1
  # ══════════════════════════════════════════════════

  describe "normalize_tool_role_messages/1" do
    test "converts role:tool to function_call_output with tool_call_id" do
      body = %{
        "input" => [
          %{"type" => "message", "role" => "tool", "tool_call_id" => "call_1", "content" => "ok"}
        ]
      }

      out = CodexInputFilter.normalize_tool_role_messages(body)
      item = hd(out["input"])
      assert item["type"] == "function_call_output"
      assert item["call_id"] == "call_1"
      assert item["output"] == "ok"
      refute Map.has_key?(item, "role")
    end

    test "uses call_id when tool_call_id is absent" do
      body = %{
        "input" => [
          %{"type" => "message", "role" => "tool", "call_id" => "call_abc", "content" => "result"}
        ]
      }

      out = CodexInputFilter.normalize_tool_role_messages(body)
      item = hd(out["input"])
      assert item["type"] == "function_call_output"
      assert item["call_id"] == "call_abc"
      assert item["output"] == "result"
    end

    test "uses id when both tool_call_id and call_id are absent" do
      body = %{
        "input" => [
          %{"type" => "message", "role" => "tool", "id" => "call_xyz", "content" => "done"}
        ]
      }

      out = CodexInputFilter.normalize_tool_role_messages(body)
      item = hd(out["input"])
      assert item["type"] == "function_call_output"
      assert item["call_id"] == "call_xyz"
    end

    test "extracts text from array content" do
      body = %{
        "input" => [
          %{
            "type" => "message",
            "role" => "tool",
            "tool_call_id" => "call_1",
            "content" => [
              %{"type" => "text", "text" => "part1"},
              %{"type" => "text", "text" => "part2"}
            ]
          }
        ]
      }

      out = CodexInputFilter.normalize_tool_role_messages(body)
      item = hd(out["input"])
      assert item["output"] == "part1part2"
    end

    test "json-encodes non-string, non-array content" do
      body = %{
        "input" => [
          %{
            "type" => "message",
            "role" => "tool",
            "tool_call_id" => "call_1",
            "content" => %{"result" => 42}
          }
        ]
      }

      out = CodexInputFilter.normalize_tool_role_messages(body)
      item = hd(out["input"])
      assert item["output"] =~ "42"
    end

    test "falls back to user role when no call_id available" do
      body = %{
        "input" => [
          %{"type" => "message", "role" => "tool", "content" => "orphan tool msg"}
        ]
      }

      out = CodexInputFilter.normalize_tool_role_messages(body)
      item = hd(out["input"])
      assert item["role"] == "user"
      refute Map.has_key?(item, "tool_call_id")
    end

    test "leaves non-tool messages untouched" do
      body = %{
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "hello"},
          %{"type" => "message", "role" => "assistant", "content" => "hi"}
        ]
      }

      out = CodexInputFilter.normalize_tool_role_messages(body)
      assert out["input"] == body["input"]
    end

    test "handles empty input" do
      body = %{"input" => []}
      out = CodexInputFilter.normalize_tool_role_messages(body)
      assert out["input"] == []
    end
  end

  # ══════════════════════════════════════════════════
  # filter_input/1
  # ══════════════════════════════════════════════════

  describe "filter_input/1 — drops reasoning items" do
    test "removes reasoning items regardless of context" do
      body = %{
        "input" => [
          %{"type" => "message", "id" => "msg_0", "role" => "user", "content" => "hi"},
          %{
            "type" => "reasoning",
            "id" => "rs_0672f12450da0b9c0169f07220a6c08198b68c2455ced99344",
            "summary" => []
          },
          %{"type" => "function_call", "call_id" => "fc1", "name" => "tool", "arguments" => "{}"},
          %{"type" => "function_call_output", "call_id" => "fc1", "output" => "{}"}
        ]
      }

      out = CodexInputFilter.filter_input(body)
      input = out["input"]

      types = Enum.map(input, & &1["type"])
      assert "message" in types
      assert "function_call" in types
      assert "function_call_output" in types
      refute "reasoning" in types

      # No rs_* id should survive
      for item <- input do
        refute String.starts_with?(Map.get(item, "id", "") || "", "rs_")
      end
    end
  end

  describe "filter_input/1 — drops orphan function_call_output" do
    test "removes function_call_output with no matching function_call" do
      body = %{
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "hi"},
          %{"type" => "function_call", "call_id" => "fc1", "name" => "tool", "arguments" => "{}"},
          %{"type" => "function_call_output", "call_id" => "fc1", "output" => "ok"},
          %{"type" => "function_call_output", "call_id" => "fc_missing", "output" => "stale"}
        ]
      }

      out = CodexInputFilter.filter_input(body)
      input = out["input"]

      assert length(input) == 3
      outputs = Enum.filter(input, &(&1["type"] == "function_call_output"))
      assert length(outputs) == 1
      assert hd(outputs)["call_id"] == "fc1"
    end

    test "removes all function_call_output when no function_call exists" do
      body = %{
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "hi"},
          %{"type" => "function_call_output", "call_id" => "fc_missing", "output" => "stale"}
        ]
      }

      out = CodexInputFilter.filter_input(body)
      input = out["input"]
      assert length(input) == 1
      assert hd(input)["type"] == "message"
    end
  end

  describe "filter_input/1 — drops orphan function_call" do
    test "removes function_call with no matching output or item_reference" do
      body = %{
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "hi"},
          %{"type" => "function_call", "call_id" => "fc1", "name" => "tool", "arguments" => "{}"},
          %{"type" => "function_call_output", "call_id" => "fc1", "output" => "ok"},
          %{
            "type" => "function_call",
            "call_id" => "fc_orphan",
            "name" => "orphan",
            "arguments" => "{}"
          }
        ]
      }

      out = CodexInputFilter.filter_input(body)
      input = out["input"]

      calls = Enum.filter(input, &(&1["type"] == "function_call"))
      assert length(calls) == 1
      assert hd(calls)["call_id"] == "fc1"
    end

    test "preserves function_call referenced by item_reference (no output needed)" do
      body = %{
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "hi"},
          %{"type" => "function_call", "call_id" => "fc1", "name" => "tool", "arguments" => "{}"},
          %{"type" => "item_reference", "id" => "fc1"}
        ]
      }

      out = CodexInputFilter.filter_input(body)
      input = out["input"]

      calls = Enum.filter(input, &(&1["type"] == "function_call"))
      assert length(calls) == 1
    end
  end

  describe "filter_input/1 — previous_response_id" do
    test "clears previous_response_id when input contains user/assistant messages" do
      body = %{
        "previous_response_id" => "resp_stale_123",
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "hello"}
        ]
      }

      out = CodexInputFilter.filter_input(body)
      refute Map.has_key?(out, "previous_response_id")
    end

    test "preserves previous_response_id when input has no conversation" do
      body = %{
        "previous_response_id" => "resp_active_123",
        "input" => [
          %{"type" => "function_call_output", "call_id" => "fc1", "output" => "ok"}
        ]
      }

      out = CodexInputFilter.filter_input(body)
      # Without user/assistant messages, previous_response_id stays
      assert out["previous_response_id"] == "resp_active_123"
    end

    test "clears previous_response_id when input has assistant message" do
      body = %{
        "previous_response_id" => "resp_stale",
        "input" => [
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "hi"}]
          }
        ]
      }

      out = CodexInputFilter.filter_input(body)
      refute Map.has_key?(out, "previous_response_id")
    end
  end

  # ══════════════════════════════════════════════════
  # Pipeline integration — dirty input → clean output
  # ══════════════════════════════════════════════════

  describe "full pipeline: fix_call_id_prefix + normalize_tool_role_messages + filter_input" do
    test "cleans dirty input with call_ prefix, tool role, and orphan refs" do
      # Simulate a dirty input from a client that:
      # - Uses call_ prefix (public API convention) instead of fc_ (internal)
      # - Includes a role:"tool" message (Chat Completions convention)
      # - Has an orphan function_call with no output
      dirty = %{
        "previous_response_id" => "resp_stale",
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "run the tool"},
          %{
            "type" => "message",
            "role" => "tool",
            "tool_call_id" => "call_abc",
            "content" => "tool result here"
          },
          %{
            "type" => "function_call",
            "call_id" => "call_abc",
            "name" => "search",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call",
            "call_id" => "call_orphan",
            "name" => "orphan",
            "arguments" => "{}"
          }
        ]
      }

      cleaned =
        dirty
        |> CodexInputFilter.normalize_tool_role_messages()
        |> CodexInputFilter.fix_call_id_prefix()
        |> CodexInputFilter.filter_input()

      # previous_response_id should be cleared
      refute Map.has_key?(cleaned, "previous_response_id")

      input = cleaned["input"]

      # Should have: message + function_call_output + function_call (matched pair)
      assert length(input) == 3

      types = Enum.map(input, & &1["type"])
      assert "message" in types
      assert "function_call_output" in types
      assert "function_call" in types

      # The orphan function_call (call_orphan) should be gone
      call_ids = Enum.map(input, &Map.get(&1, "call_id"))
      refute "fcorphan" in call_ids
      refute "fc_orphan" in call_ids

      # The matched pair should have fc prefix
      fc_output = Enum.find(input, &(&1["type"] == "function_call_output"))
      fc_call = Enum.find(input, &(&1["type"] == "function_call"))
      assert fc_output["call_id"] == "fcabc"
      assert fc_call["call_id"] == "fcabc"

      # No role:"tool" should remain
      refute Enum.any?(input, &(Map.get(&1, "role") == "tool"))
    end

    test "handles empty input gracefully" do
      body = %{"input" => []}

      cleaned =
        body
        |> CodexInputFilter.normalize_tool_role_messages()
        |> CodexInputFilter.fix_call_id_prefix()
        |> CodexInputFilter.filter_input()

      assert cleaned["input"] == []
    end

    test "handles missing input key gracefully" do
      body = %{"model" => "gpt-5.4"}

      cleaned =
        body
        |> CodexInputFilter.normalize_tool_role_messages()
        |> CodexInputFilter.fix_call_id_prefix()
        |> CodexInputFilter.filter_input()

      assert cleaned["model"] == "gpt-5.4"
      refute Map.has_key?(cleaned, "input")
    end
  end

  # ══════════════════════════════════════════════════
  # CodexAPI.transform_body/2 integration
  # ══════════════════════════════════════════════════

  describe "CodexAPI.transform_body/2 includes input filter" do
    test "dirty call_ids are normalized through transform_body pipeline" do
      alias Auth2ApiEx.Upstream.CodexAPI

      body = %{
        "model" => "gpt-5.4",
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "hi"},
          %{
            "type" => "function_call",
            "call_id" => "call_1",
            "name" => "tool",
            "arguments" => "{}"
          },
          %{"type" => "function_call_output", "call_id" => "call_1", "output" => "ok"}
        ]
      }

      out = CodexAPI.transform_body(body)
      input = out["input"]

      assert length(input) == 3
      fc_call = Enum.find(input, &(&1["type"] == "function_call"))
      fc_output = Enum.find(input, &(&1["type"] == "function_call_output"))
      assert fc_call["call_id"] == "fc1"
      assert fc_output["call_id"] == "fc1"
    end

    test "tool role messages are normalized through transform_body" do
      alias Auth2ApiEx.Upstream.CodexAPI

      body = %{
        "model" => "gpt-5.4",
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "hi"},
          %{
            "type" => "function_call",
            "call_id" => "call_1",
            "name" => "tool",
            "arguments" => "{}"
          },
          %{
            "type" => "message",
            "role" => "tool",
            "tool_call_id" => "call_1",
            "content" => "result"
          }
        ]
      }

      out = CodexAPI.transform_body(body, is_codex_cli: true)
      input = out["input"]

      assert length(input) == 3
      tool_item = Enum.find(input, &(&1["type"] == "function_call_output"))
      assert tool_item
      assert tool_item["output"] == "result"
      # Call IDs should be normalized to fc prefix
      assert tool_item["call_id"] == "fc1"
    end
  end
end
