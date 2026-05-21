defmodule Auth2ApiEx.Upstream.CodexAPITransformTest do
  use ExUnit.Case, async: true
  alias Auth2ApiEx.Upstream.CodexAPI

  # ══════════════════════════════════════════════════
  # P0.1 — Strip unsupported fields
  # ══════════════════════════════════════════════════

  describe "transform_body/2 strips unsupported fields" do
    test "removes temperature/top_p/penalties/max_output_tokens" do
      body = %{
        "model" => "gpt-5.3",
        "temperature" => 0.7,
        "top_p" => 0.9,
        "frequency_penalty" => 0.2,
        "presence_penalty" => 0.1,
        "max_output_tokens" => 4096
      }

      out = CodexAPI.transform_body(body)

      refute Map.has_key?(out, "temperature")
      refute Map.has_key?(out, "top_p")
      refute Map.has_key?(out, "frequency_penalty")
      refute Map.has_key?(out, "presence_penalty")
      refute Map.has_key?(out, "max_output_tokens")
    end

    test "removes max_completion_tokens" do
      body = %{"model" => "gpt-5.3", "max_completion_tokens" => 2048}
      out = CodexAPI.transform_body(body)
      refute Map.has_key?(out, "max_completion_tokens")
    end

    test "removes user/metadata/prompt_cache_retention/safety_identifier/stream_options" do
      body = %{
        "model" => "gpt-5.3",
        "user" => "u1",
        "metadata" => %{"foo" => "bar"},
        "prompt_cache_retention" => "24h",
        "safety_identifier" => "safe-1",
        "stream_options" => %{"include_usage" => true}
      }

      out = CodexAPI.transform_body(body)

      refute Map.has_key?(out, "user")
      refute Map.has_key?(out, "metadata")
      refute Map.has_key?(out, "prompt_cache_retention")
      refute Map.has_key?(out, "safety_identifier")
      refute Map.has_key?(out, "stream_options")
    end

    test "strips unsupported fields in compact mode too" do
      body = %{
        "model" => "gpt-5.3",
        "temperature" => 0.5,
        "user" => "u2"
      }

      out = CodexAPI.transform_body(body, is_compact: true)

      refute Map.has_key?(out, "temperature")
      refute Map.has_key?(out, "user")
    end
  end

  # ══════════════════════════════════════════════════
  # P0.2 — Force store=false
  # ══════════════════════════════════════════════════

  describe "transform_body/2 forces store=false" do
    test "injects store=false when missing" do
      out = CodexAPI.transform_body(%{"model" => "gpt-5.3"})
      assert out["store"] == false
    end

    test "overrides store=true to false" do
      out = CodexAPI.transform_body(%{"store" => true})
      assert out["store"] == false
    end

    test "preserves store=false when already false" do
      out = CodexAPI.transform_body(%{"store" => false})
      assert out["store"] == false
    end
  end

  # ══════════════════════════════════════════════════
  # P0.3 — Force stream=true
  # ══════════════════════════════════════════════════

  describe "transform_body/2 forces stream=true" do
    test "injects stream=true when missing" do
      out = CodexAPI.transform_body(%{"model" => "gpt-5.3"})
      assert out["stream"] == true
    end

    test "overrides stream=false to true" do
      out = CodexAPI.transform_body(%{"stream" => false})
      assert out["stream"] == true
    end

    test "preserves stream=true when already true" do
      out = CodexAPI.transform_body(%{"stream" => true})
      assert out["stream"] == true
    end
  end

  # ══════════════════════════════════════════════════
  # P0.4 — Compact mode
  # ══════════════════════════════════════════════════

  describe "transform_body/2 compact mode" do
    test "strips store and stream entirely in compact mode" do
      out = CodexAPI.transform_body(%{"store" => true, "stream" => false}, is_compact: true)
      refute Map.has_key?(out, "store")
      refute Map.has_key?(out, "stream")
    end

    test "strips store/stream even when they were not set" do
      out = CodexAPI.transform_body(%{"model" => "gpt-5.3"}, is_compact: true)
      refute Map.has_key?(out, "store")
      refute Map.has_key?(out, "stream")
    end
  end

  # ══════════════════════════════════════════════════
  # P0.5 — functions → tools
  # ══════════════════════════════════════════════════

  describe "transform_body/2 functions -> tools" do
    test "wraps legacy functions array into tools" do
      body = %{"functions" => [%{"name" => "f", "parameters" => %{}}]}
      out = CodexAPI.transform_body(body)

      refute Map.has_key?(out, "functions")

      assert [%{"type" => "function", "function" => %{"name" => "f", "parameters" => %{}}}] =
               out["tools"]
    end

    test "wraps multiple functions" do
      body = %{
        "functions" => [
          %{"name" => "f1", "parameters" => %{}},
          %{"name" => "f2", "parameters" => %{"x" => "int"}}
        ]
      }

      out = CodexAPI.transform_body(body)

      refute Map.has_key?(out, "functions")
      assert length(out["tools"]) == 2
      assert Enum.at(out["tools"], 0)["type"] == "function"
      assert Enum.at(out["tools"], 1)["type"] == "function"
    end

    test "does not touch tools when functions key is absent" do
      body = %{"tools" => [%{"type" => "function", "name" => "f1"}]}
      out = CodexAPI.transform_body(body)
      assert out["tools"] == [%{"type" => "function", "name" => "f1"}]
    end
  end

  # ══════════════════════════════════════════════════
  # P0.6 — function_call → tool_choice
  # ══════════════════════════════════════════════════

  describe "transform_body/2 function_call -> tool_choice" do
    test "converts function_call string 'auto' to tool_choice" do
      body = %{"function_call" => "auto"}
      out = CodexAPI.transform_body(body)

      refute Map.has_key?(out, "function_call")
      assert out["tool_choice"] == "auto"
    end

    test "converts function_call string 'none' to tool_choice" do
      body = %{"function_call" => "none"}
      out = CodexAPI.transform_body(body)

      refute Map.has_key?(out, "function_call")
      assert out["tool_choice"] == "none"
    end

    test "converts function_call map to tool_choice" do
      body = %{"function_call" => %{"name" => "my_func"}}
      out = CodexAPI.transform_body(body)

      refute Map.has_key?(out, "function_call")
      assert out["tool_choice"] == %{"type" => "function", "name" => "my_func"}
    end
  end

  # ══════════════════════════════════════════════════
  # P0.7 — input string → array
  # ══════════════════════════════════════════════════

  describe "transform_body/2 input string -> array" do
    test "wraps string input into message array" do
      out = CodexAPI.transform_body(%{"input" => "hello"})
      assert [%{"type" => "message", "role" => "user", "content" => "hello"}] = out["input"]
    end

    test "converts empty string input to empty array" do
      out = CodexAPI.transform_body(%{"input" => ""})
      assert out["input"] == []
    end

    test "leaves list input untouched" do
      input = [%{"type" => "message", "role" => "user", "content" => "hi"}]
      out = CodexAPI.transform_body(%{"input" => input})
      assert out["input"] == input
    end
  end

  # ══════════════════════════════════════════════════
  # P0.8 — system message extraction
  # ══════════════════════════════════════════════════

  describe "transform_body/2 system message extraction" do
    test "extracts system messages into instructions when not codex_cli" do
      body = %{
        "input" => [
          %{"type" => "message", "role" => "system", "content" => "you are helpful"},
          %{"type" => "message", "role" => "user", "content" => "hi"}
        ]
      }

      out = CodexAPI.transform_body(body, is_codex_cli: false)
      assert out["instructions"] =~ "you are helpful"
      assert length(out["input"]) == 1
    end

    test "joins multiple system messages with newlines" do
      body = %{
        "input" => [
          %{"type" => "message", "role" => "system", "content" => "first"},
          %{"type" => "message", "role" => "system", "content" => "second"},
          %{"type" => "message", "role" => "user", "content" => "hi"}
        ]
      }

      out = CodexAPI.transform_body(body, is_codex_cli: false)
      assert out["instructions"] == "first\n\nsecond"
      assert length(out["input"]) == 1
    end

    test "appends extracted system messages to existing instructions" do
      body = %{
        "instructions" => "pre-existing",
        "input" => [
          %{"type" => "message", "role" => "system", "content" => "extracted"}
        ]
      }

      out = CodexAPI.transform_body(body, is_codex_cli: false)
      assert out["instructions"] == "extracted\n\npre-existing"
    end

    test "preserves system messages in input when client is codex_cli" do
      body = %{
        "input" => [%{"type" => "message", "role" => "system", "content" => "x"}]
      }

      out = CodexAPI.transform_body(body, is_codex_cli: true)
      # System message stays in input (not extracted to instructions)
      assert length(out["input"]) == 1
      assert hd(out["input"])["role"] == "system"
    end
  end

  # ══════════════════════════════════════════════════
  # P0.9 — model trim
  # ══════════════════════════════════════════════════

  describe "transform_body/2 model trim" do
    test "trims whitespace from model" do
      out = CodexAPI.transform_body(%{"model" => "  gpt-5.3  "})
      assert out["model"] == "gpt-5.3"
    end

    test "removes model when trimmed to empty string" do
      out = CodexAPI.transform_body(%{"model" => "   "})
      refute Map.has_key?(out, "model")
    end
  end

  # ══════════════════════════════════════════════════
  # P0.10 — normalize_body delegates to transform_body
  # ══════════════════════════════════════════════════

  describe "normalize_body/1 delegates to transform_body/2" do
    test "normalize_body is a thin wrapper around transform_body" do
      out = CodexAPI.normalize_body(%{"temperature" => 0.5, "store" => true})
      refute Map.has_key?(out, "temperature")
      assert out["store"] == false
      assert out["stream"] == true
    end
  end
end
