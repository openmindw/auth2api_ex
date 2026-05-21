defmodule Auth2ApiEx.UnitTest do
  use ExUnit.Case, async: true

  # ══════════════════════════════════════════════════
  # Utils.Common
  # ══════════════════════════════════════════════════

  describe "extract_api_key/1" do
    test "extracts Bearer token" do
      conn = conn_with_headers(%{"authorization" => "Bearer sk-test-123"})
      assert Auth2ApiEx.Utils.Common.extract_api_key(conn) == "sk-test-123"
    end

    test "extracts x-api-key header" do
      conn = conn_with_headers(%{"x-api-key" => "sk-test-456"})
      assert Auth2ApiEx.Utils.Common.extract_api_key(conn) == "sk-test-456"
    end

    test "prefers Bearer over x-api-key" do
      conn = conn_with_headers(%{"authorization" => "Bearer sk-bearer", "x-api-key" => "sk-xapi"})
      assert Auth2ApiEx.Utils.Common.extract_api_key(conn) == "sk-bearer"
    end

    test "returns empty string when no key" do
      conn = Plug.Test.conn(:get, "/")
      assert Auth2ApiEx.Utils.Common.extract_api_key(conn) == ""
    end
  end

  describe "hash_api_key/1" do
    test "returns consistent sha256 hex" do
      hash1 = Auth2ApiEx.Utils.Common.hash_api_key("test-key")
      hash2 = Auth2ApiEx.Utils.Common.hash_api_key("test-key")
      assert hash1 == hash2
      assert String.length(hash1) == 64
      assert Regex.match?(~r/^[a-f0-9]{64}$/, hash1)
    end

    test "returns different hashes for different keys" do
      hash_a = Auth2ApiEx.Utils.Common.hash_api_key("key-a")
      hash_b = Auth2ApiEx.Utils.Common.hash_api_key("key-b")
      refute hash_a == hash_b
    end
  end

  # ══════════════════════════════════════════════════
  # Utils.HTTP
  # ══════════════════════════════════════════════════

  describe "classify_failure/1" do
    test "maps status codes correctly" do
      assert Auth2ApiEx.Utils.HTTP.classify_failure(429) == :rate_limit
      assert Auth2ApiEx.Utils.HTTP.classify_failure(401) == :auth
      assert Auth2ApiEx.Utils.HTTP.classify_failure(403) == :forbidden
      assert Auth2ApiEx.Utils.HTTP.classify_failure(500) == :server
      assert Auth2ApiEx.Utils.HTTP.classify_failure(502) == :server
      assert Auth2ApiEx.Utils.HTTP.classify_failure(503) == :server
      assert Auth2ApiEx.Utils.HTTP.classify_failure(418) == :server
    end
  end

  describe "parse_codex_utilization/1" do
    test "accepts list and numeric header values from HTTP clients" do
      info =
        Auth2ApiEx.Utils.HTTP.parse_codex_utilization([
          {"x-codex-primary-used-percent", ["88"]},
          {"x-codex-primary-reset-after-seconds", [604_800]},
          {"x-codex-primary-window-minutes", ["10080"]},
          {"x-codex-secondary-used-percent", 42},
          {"x-codex-secondary-reset-after-seconds", ["18000"]},
          {"x-codex-secondary-window-minutes", [300]}
        ])

      assert info.utilization_5h == 42.0
      assert info.reset_5h_seconds == 18_000
      assert info.window_5h_minutes == 300
      assert info.utilization_7d == 88.0
      assert info.reset_7d_seconds == 604_800
      assert info.window_7d_minutes == 10_080
    end

    test "uses legacy primary=7d secondary=5h mapping when windows are absent" do
      info =
        Auth2ApiEx.Utils.HTTP.parse_codex_utilization([
          {"x-codex-primary-used-percent", "80"},
          {"x-codex-primary-reset-after-seconds", "50000"},
          {"x-codex-secondary-used-percent", "60"},
          {"x-codex-secondary-reset-after-seconds", "3000"}
        ])

      assert info.utilization_5h == 60.0
      assert info.reset_5h_seconds == 3_000
      assert info.utilization_7d == 80.0
      assert info.reset_7d_seconds == 50_000
    end

    test "classifies single secondary window by duration threshold" do
      short =
        Auth2ApiEx.Utils.HTTP.parse_codex_utilization([
          {"x-codex-secondary-used-percent", "12"},
          {"x-codex-secondary-window-minutes", "300"}
        ])

      assert short.utilization_5h == 12.0
      assert short.utilization_7d == nil

      long =
        Auth2ApiEx.Utils.HTTP.parse_codex_utilization([
          {"x-codex-secondary-used-percent", "34"},
          {"x-codex-secondary-window-minutes", "10080"}
        ])

      assert long.utilization_5h == nil
      assert long.utilization_7d == 34.0
    end
  end

  # ══════════════════════════════════════════════════
  # Config
  # ══════════════════════════════════════════════════

  describe "debug_level?/2" do
    test "returns correct values" do
      assert Auth2ApiEx.Config.debug_level?("off", :errors) == false
      assert Auth2ApiEx.Config.debug_level?("errors", :errors) == true
      assert Auth2ApiEx.Config.debug_level?("errors", :verbose) == false
      assert Auth2ApiEx.Config.debug_level?("verbose", :errors) == true
      assert Auth2ApiEx.Config.debug_level?("verbose", :verbose) == true
    end
  end

  describe "resolve_auth_dir/1" do
    test "expands tilde" do
      result = Auth2ApiEx.Config.resolve_auth_dir("~/.auth2api_ex")
      refute String.starts_with?(result, "~")
      assert String.ends_with?(result, ".auth2api_ex")
    end

    test "resolves relative paths" do
      result = Auth2ApiEx.Config.resolve_auth_dir("./data")
      assert Path.type(result) == :absolute
    end
  end

  describe "load_config/1" do
    test "uses defaults when file missing" do
      config =
        Auth2ApiEx.Config.load_config(
          "/tmp/nonexistent-config-#{System.system_time(:millisecond)}.yaml"
        )

      assert config.port == 8318
      assert config.body_limit == "200mb"
      assert config.debug == "off"
      assert MapSet.size(config.api_keys) > 0
    end

    test "normalizes debug mode" do
      config_path =
        Path.join(
          System.tmp_dir!(),
          "auth2api_ex-debug-test-#{System.system_time(:millisecond)}.yaml"
        )

      File.write!(config_path, "api-keys:\n  - \"sk-test\"\ndebug: true\n")

      try do
        config = Auth2ApiEx.Config.load_config(config_path)
        assert config.debug == "errors"
      after
        File.rm(config_path)
      end
    end
  end

  # ══════════════════════════════════════════════════
  # Translator — model resolution
  # ══════════════════════════════════════════════════

  describe "resolve_model/1" do
    test "maps aliases" do
      assert Auth2ApiEx.Upstream.Translator.resolve_model("opus") == "claude-opus-4-6"
      assert Auth2ApiEx.Upstream.Translator.resolve_model("sonnet") == "claude-sonnet-4-6"
      assert Auth2ApiEx.Upstream.Translator.resolve_model("haiku") == "claude-haiku-4-5-20251001"
    end

    test "passes through unknown models" do
      assert Auth2ApiEx.Upstream.Translator.resolve_model("gpt-4o") == "gpt-4o"

      assert Auth2ApiEx.Upstream.Translator.resolve_model("claude-sonnet-4-6") ==
               "claude-sonnet-4-6"
    end
  end

  # ══════════════════════════════════════════════════
  # Translator — OpenAI Chat → Anthropic
  # ══════════════════════════════════════════════════

  describe "openai_to_anthropic/1" do
    test "translates basic request" do
      result =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "messages" => [%{"role" => "user", "content" => "hello"}],
          "stream" => false
        })

      assert result["model"] == "claude-sonnet-4-6"
      assert result["stream"] == false
      assert result["max_tokens"] == 8192
      assert result["messages"] == [%{"role" => "user", "content" => "hello"}]
    end

    test "uses max_completion_tokens over max_tokens" do
      result =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "max_tokens" => 100,
          "max_completion_tokens" => 500,
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert result["max_tokens"] == 500
    end

    test "translates temperature and top_p" do
      result =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "temperature" => 0.5,
          "top_p" => 0.9,
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert result["temperature"] == 0.5
      assert result["top_p"] == 0.9
    end

    test "translates stop sequences" do
      result =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "stop" => ["END", "STOP"],
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert result["stop_sequences"] == ["END", "STOP"]
    end

    test "translates single stop string" do
      result =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "stop" => "END",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert result["stop_sequences"] == ["END"]
    end

    test "translates system messages" do
      result =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "messages" => [
            %{"role" => "system", "content" => "You are helpful."},
            %{"role" => "user", "content" => "hi"}
          ]
        })

      assert result["system"] == [%{"type" => "text", "text" => "You are helpful."}]
      assert length(result["messages"]) == 1
    end

    test "adds JSON-only system hint for json_object response_format" do
      result =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "response_format" => %{"type" => "json_object"},
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert Enum.any?(result["system"], fn part ->
               part["text"] =~ "Respond with valid JSON only"
             end)
    end

    test "translates reasoning_effort to thinking" do
      result =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "reasoning_effort" => "high",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert result["thinking"]["type"] == "enabled"
      assert result["thinking"]["budget_tokens"] == 24576
    end

    test "translates tools" do
      result =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "tools" => [
            %{
              "type" => "function",
              "function" => %{
                "name" => "get_weather",
                "description" => "Get weather",
                "parameters" => %{"type" => "object", "properties" => %{}}
              }
            }
          ]
        })

      [tool | _] = result["tools"]
      assert tool["name"] == "get_weather"
      assert tool["description"] == "Get weather"
      assert tool["input_schema"] != nil
    end

    test "translates tool_choice" do
      auto =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "tool_choice" => "auto"
        })

      assert auto["tool_choice"] == %{"type" => "auto"}

      required =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "tool_choice" => "required"
        })

      assert required["tool_choice"] == %{"type" => "any"}
    end

    test "translates parallel_tool_calls" do
      result =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "tool_choice" => "auto",
          "parallel_tool_calls" => false
        })

      assert result["tool_choice"]["disable_parallel_tool_use"] == true
    end

    test "translates response_format json_schema" do
      result =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "response_format" => %{
            "type" => "json_schema",
            "json_schema" => %{
              "name" => "test",
              "schema" => %{
                "type" => "object",
                "properties" => %{"name" => %{"type" => "string"}}
              }
            }
          }
        })

      assert result["output_config"]["format"]["type"] == "json_schema"
      assert result["output_config"]["format"]["name"] == "test"
    end

    test "translates tool role messages" do
      result =
        Auth2ApiEx.Upstream.Translator.openai_to_anthropic(%{
          "model" => "sonnet",
          "messages" => [
            %{"role" => "user", "content" => "hi"},
            %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "get_weather", "arguments" => "{\"city\":\"NYC\"}"}
                }
              ]
            },
            %{"role" => "tool", "tool_call_id" => "call_1", "content" => "{\"temp\":72}"}
          ]
        })

      # assistant message with tool_use
      assistant_msg = Enum.at(result["messages"], 1)
      assert assistant_msg["role"] == "assistant"
      assert Enum.any?(assistant_msg["content"], fn c -> c["type"] == "tool_use" end)

      # tool result
      tool_msg = Enum.at(result["messages"], 2)
      assert tool_msg["role"] == "user"
      [tool_result | _] = tool_msg["content"]
      assert tool_result["type"] == "tool_result"
      assert tool_result["tool_use_id"] == "call_1"
    end
  end

  # ══════════════════════════════════════════════════
  # Translator — Anthropic → OpenAI Chat
  # ══════════════════════════════════════════════════

  describe "anthropic_to_openai/2" do
    test "translates basic response" do
      result =
        Auth2ApiEx.Upstream.Translator.anthropic_to_openai(
          %{
            "content" => [%{"type" => "text", "text" => "Hello!"}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
          },
          "claude-sonnet-4-6"
        )

      assert result["object"] == "chat.completion"
      [choice] = result["choices"]
      assert choice["message"]["content"] == "Hello!"
      assert choice["message"]["role"] == "assistant"
      assert choice["finish_reason"] == "stop"
      assert result["usage"]["prompt_tokens"] == 10
      assert result["usage"]["completion_tokens"] == 5
      assert result["usage"]["total_tokens"] == 15
    end

    test "maps stop reasons correctly" do
      end_turn =
        Auth2ApiEx.Upstream.Translator.anthropic_to_openai(
          %{"content" => [], "stop_reason" => "end_turn", "usage" => %{}},
          "sonnet"
        )

      assert hd(end_turn["choices"])["finish_reason"] == "stop"

      max_tokens =
        Auth2ApiEx.Upstream.Translator.anthropic_to_openai(
          %{"content" => [], "stop_reason" => "max_tokens", "usage" => %{}},
          "sonnet"
        )

      assert hd(max_tokens["choices"])["finish_reason"] == "length"

      tool_use =
        Auth2ApiEx.Upstream.Translator.anthropic_to_openai(
          %{"content" => [], "stop_reason" => "tool_use", "usage" => %{}},
          "sonnet"
        )

      assert hd(tool_use["choices"])["finish_reason"] == "tool_calls"
    end

    test "translates tool_use blocks" do
      result =
        Auth2ApiEx.Upstream.Translator.anthropic_to_openai(
          %{
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "call_1",
                "name" => "get_weather",
                "input" => %{"city" => "NYC"}
              }
            ],
            "stop_reason" => "tool_use",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
          },
          "sonnet"
        )

      [choice] = result["choices"]
      [tool_call | _] = choice["message"]["tool_calls"]
      assert tool_call["id"] == "call_1"
      assert tool_call["function"]["name"] == "get_weather"
      assert tool_call["function"]["arguments"] == "{\"city\":\"NYC\"}"
    end

    test "includes usage details" do
      result =
        Auth2ApiEx.Upstream.Translator.anthropic_to_openai(
          %{
            "content" => [],
            "stop_reason" => "end_turn",
            "usage" => %{
              "input_tokens" => 100,
              "output_tokens" => 50,
              "cache_read_input_tokens" => 30
            }
          },
          "sonnet"
        )

      assert result["usage"]["prompt_tokens_details"]["cached_tokens"] == 30
      assert result["usage"]["completion_tokens_details"]["reasoning_tokens"] == 0
    end
  end

  # ══════════════════════════════════════════════════
  # Translator — Responses API
  # ══════════════════════════════════════════════════

  describe "responses_to_anthropic/1" do
    test "translates basic request" do
      result =
        Auth2ApiEx.Upstream.Translator.responses_to_anthropic(%{
          "model" => "sonnet",
          "input" => [%{"role" => "user", "content" => "hello"}],
          "stream" => false
        })

      assert result["model"] == "claude-sonnet-4-6"
      assert result["stream"] == false
      assert result["messages"] == [%{"role" => "user", "content" => "hello"}]
    end

    test "translates instructions to system" do
      result =
        Auth2ApiEx.Upstream.Translator.responses_to_anthropic(%{
          "model" => "sonnet",
          "instructions" => "Be helpful",
          "input" => [%{"role" => "user", "content" => "hi"}]
        })

      assert result["system"] == [%{"type" => "text", "text" => "Be helpful"}]
    end

    test "adds JSON-only system hint for json_object text format" do
      result =
        Auth2ApiEx.Upstream.Translator.responses_to_anthropic(%{
          "model" => "sonnet",
          "text" => %{"format" => %{"type" => "json_object"}},
          "input" => [%{"role" => "user", "content" => "hi"}]
        })

      assert Enum.any?(result["system"], fn part ->
               part["text"] =~ "Respond with valid JSON only"
             end)
    end

    test "keeps JSON-only hint ahead of instructions for json_object text format" do
      result =
        Auth2ApiEx.Upstream.Translator.responses_to_anthropic(%{
          "model" => "sonnet",
          "instructions" => "Be helpful",
          "text" => %{"format" => %{"type" => "json_object"}},
          "input" => [%{"role" => "user", "content" => "hi"}]
        })

      assert result["system"] |> hd() |> Map.get("text") =~ "Respond with valid JSON only"
      assert Enum.any?(result["system"], fn part -> part["text"] == "Be helpful" end)
    end

    test "translates reasoning with summary" do
      result =
        Auth2ApiEx.Upstream.Translator.responses_to_anthropic(%{
          "model" => "sonnet",
          "input" => [%{"role" => "user", "content" => "hi"}],
          "reasoning" => %{"effort" => "high", "summary" => "concise"}
        })

      assert result["thinking"]["type"] == "enabled"
      assert result["thinking"]["budget_tokens"] == 24576
      assert result["thinking"]["display"] == "summarized"
    end

    # ── Multi-tool continuation trimming ──

    test "preserves all items when input has no stale turns" do
      body = %{
        "model" => "sonnet",
        "input" => [
          %{"role" => "user", "content" => "hi"},
          %{
            "type" => "function_call",
            "call_id" => "fc_1",
            "name" => "read",
            "arguments" => "{}"
          },
          %{"type" => "function_call_output", "call_id" => "fc_1", "output" => "content"}
        ]
      }

      result = Auth2ApiEx.Upstream.Translator.responses_to_anthropic(body)
      messages = result["messages"]

      # All 3 items are within the same turn — trimming finds fc_1's call_id match
      # and starts from index 0. The user message + assistant tool_use + user tool_result
      # should all appear.
      assert length(messages) == 3
      assert Enum.at(messages, 0) == %{"role" => "user", "content" => "hi"}

      assistant_msg = Enum.at(messages, 1)
      assert assistant_msg["role"] == "assistant"
      [tool_use | _] = assistant_msg["content"]
      assert tool_use["type"] == "tool_use"
      assert tool_use["name"] == "read"
      assert tool_use["id"] == "fc_1"

      tool_result = Enum.at(messages, 2)
      assert tool_result["role"] == "user"
      [tr | _] = tool_result["content"]
      assert tr["type"] == "tool_result"
      assert tr["tool_use_id"] == "fc_1"
    end

    test "drops stale turns before latest function_call_output" do
      body = %{
        "model" => "sonnet",
        "input" => [
          %{"role" => "user", "content" => "turn 1 old"},
          %{
            "type" => "function_call",
            "call_id" => "call_old",
            "name" => "old_tool",
            "arguments" => "{}"
          },
          %{"type" => "function_call_output", "call_id" => "call_old", "output" => "old_result"},
          %{"role" => "user", "content" => "turn 2 latest"},
          %{
            "type" => "function_call",
            "call_id" => "call_new",
            "name" => "new_tool",
            "arguments" => "{}"
          },
          %{"type" => "function_call_output", "call_id" => "call_new", "output" => "new_result"}
        ]
      }

      result = Auth2ApiEx.Upstream.Translator.responses_to_anthropic(body)
      messages = result["messages"]

      # After trimming: user(turn2 latest), assistant(tool_use), user(tool_result)
      # The preceding user message is part of the turn so all 3 survive.
      assert length(messages) == 3

      # Turn 1 content must be trimmed
      refute Enum.any?(messages, fn m ->
               is_binary(m["content"]) && String.contains?(m["content"], "turn 1 old")
             end)

      # Turn 2 user message must survive
      assert Enum.any?(messages, fn m ->
               is_binary(m["content"]) && String.contains?(m["content"], "turn 2 latest")
             end)

      # call_new's function_call must be preserved
      assert Enum.any?(messages, fn m ->
               m["role"] == "assistant" &&
                 Enum.any?(m["content"], fn c ->
                   c["type"] == "tool_use" && c["name"] == "new_tool"
                 end)
             end)
    end

    test "expands function_call context backward only for matched call_ids" do
      # Two function_call_output in latest turn: call_A and call_B.
      # call_B's function_call is present; call_A's was already trimmed.
      # Only call_B should be restored, not call_A.
      body = %{
        "model" => "sonnet",
        "input" => [
          %{"role" => "user", "content" => "turn 1"},
          %{
            "type" => "function_call",
            "call_id" => "call_B",
            "name" => "tool_b",
            "arguments" => "{}"
          },
          %{"type" => "function_call_output", "call_id" => "call_A", "output" => "result_a"},
          %{"type" => "function_call_output", "call_id" => "call_B", "output" => "result_b"}
        ]
      }

      result = Auth2ApiEx.Upstream.Translator.responses_to_anthropic(body)
      messages = result["messages"]

      # call_A's function_call was NOT in input → must not appear
      refute Enum.any?(messages, fn m ->
               m["role"] == "assistant" &&
                 Enum.any?(m["content"], fn c ->
                   c["type"] == "tool_use" && c["name"] == "tool_a"
                 end)
             end)

      # call_B's function_call IS in input → must be preserved
      assert Enum.any?(messages, fn m ->
               m["role"] == "assistant" &&
                 Enum.any?(m["content"], fn c ->
                   c["type"] == "tool_use" && c["name"] == "tool_b"
                 end)
             end)
    end

    test "handles single tool_call output pair end-to-end" do
      body = %{
        "model" => "sonnet",
        "input" => [
          %{"role" => "user", "content" => "read the file"},
          %{
            "type" => "function_call",
            "call_id" => "fc_001",
            "name" => "read_file",
            "arguments" => "{\"path\":\"/tmp/x\"}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "fc_001",
            "output" => "file contents here"
          }
        ]
      }

      result = Auth2ApiEx.Upstream.Translator.responses_to_anthropic(body)
      messages = result["messages"]

      # All 3 items are in the same turn — trimming starts from the matching
      # function_call (fc_001), expands back to find preceding user message at idx 0,
      # so all 3 items are included.
      assert length(messages) == 3
      assert Enum.at(messages, 0) == %{"role" => "user", "content" => "read the file"}

      assistant_msg = Enum.at(messages, 1)
      assert assistant_msg["role"] == "assistant"
      [tool_use | _] = assistant_msg["content"]
      assert tool_use["type"] == "tool_use"
      assert tool_use["name"] == "read_file"
      assert tool_use["id"] == "fc_001"

      tool_result = Enum.at(messages, 2)
      assert tool_result["role"] == "user"
      [tr | _] = tool_result["content"]
      assert tr["type"] == "tool_result"
      assert tr["tool_use_id"] == "fc_001"
      assert tr["content"] == "file contents here"
    end
  end

  describe "anthropic_to_responses/2" do
    test "translates basic response" do
      result =
        Auth2ApiEx.Upstream.Translator.anthropic_to_responses(
          %{
            "content" => [%{"type" => "text", "text" => "Hello!"}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
          },
          "claude-sonnet-4-6"
        )

      assert result["object"] == "response"
      assert result["status"] == "completed"
      assert result["output_text"] == "Hello!"
      assert result["usage"]["input_tokens"] == 10
      assert result["usage"]["output_tokens"] == 5
    end

    test "sets incomplete status on max_tokens" do
      result =
        Auth2ApiEx.Upstream.Translator.anthropic_to_responses(
          %{
            "content" => [%{"type" => "text", "text" => "partial"}],
            "stop_reason" => "max_tokens",
            "usage" => %{}
          },
          "sonnet"
        )

      assert result["status"] == "incomplete"
    end

    test "includes usage details" do
      result =
        Auth2ApiEx.Upstream.Translator.anthropic_to_responses(
          %{
            "content" => [],
            "stop_reason" => "end_turn",
            "usage" => %{
              "input_tokens" => 100,
              "output_tokens" => 50,
              "cache_read_input_tokens" => 20
            }
          },
          "sonnet"
        )

      assert result["usage"]["input_tokens_details"]["cached_tokens"] == 20
      assert result["usage"]["output_tokens_details"]["reasoning_tokens"] == 0
    end
  end

  describe "anthropic_to_responses/2 — empty Read.pages filter" do
    test "filters out empty Read content blocks" do
      anthropic_resp = %{
        "content" => [
          %{"type" => "text", "text" => "Here is a summary."},
          %{"type" => "Read", "name" => "/tmp/empty.txt", "pages" => []}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{}
      }

      result =
        Auth2ApiEx.Upstream.Translator.anthropic_to_responses(anthropic_resp, "claude-sonnet-4-6")

      output = result["output"] || []

      # Empty Read block should be filtered out; text output must remain
      refute Enum.any?(output, fn item -> item["type"] == "read" end)
      assert Enum.any?(output, fn item -> item["type"] == "message" end)
      assert result["output_text"] == "Here is a summary."
    end

    test "keeps Read blocks with non-empty pages" do
      anthropic_resp = %{
        "content" => [
          %{
            "type" => "Read",
            "name" => "/tmp/file.txt",
            "pages" => [%{"page" => 1, "text" => "page 1"}]
          },
          %{"type" => "text", "text" => "done"}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{}
      }

      result =
        Auth2ApiEx.Upstream.Translator.anthropic_to_responses(anthropic_resp, "claude-sonnet-4-6")

      output = result["output"] || []

      # Non-empty Read appears inside the message content, not as a top-level output item
      msg = Enum.find(output, fn item -> item["type"] == "message" end)
      assert msg != nil
      read_parts = Enum.filter(msg["content"], fn c -> c["type"] == "read" end)
      assert length(read_parts) == 1
      assert hd(read_parts)["name"] == "/tmp/file.txt"
      assert result["output_text"] == "done"
    end
  end

  # ══════════════════════════════════════════════════
  # PKCE
  # ══════════════════════════════════════════════════

  describe "generate_pkce_codes/0" do
    test "generates valid PKCE codes" do
      pkce = Auth2ApiEx.Auth.PKCE.generate_pkce_codes()
      assert is_binary(pkce.code_verifier)
      assert is_binary(pkce.code_challenge)
      assert String.length(pkce.code_verifier) > 0
      assert String.length(pkce.code_challenge) > 0
    end

    test "generates different codes each time" do
      pkce1 = Auth2ApiEx.Auth.PKCE.generate_pkce_codes()
      pkce2 = Auth2ApiEx.Auth.PKCE.generate_pkce_codes()
      refute pkce1.code_verifier == pkce2.code_verifier
    end
  end

  # ══════════════════════════════════════════════════
  # RequestDecompression
  # ══════════════════════════════════════════════════

  describe "Auth2ApiEx.Utils.RequestDecompression" do
    test "decompresses gzip body" do
      original = ~s({"model":"claude","messages":[{"role":"user","content":"hello"}]})
      compressed = :zlib.gzip(original)

      conn = Plug.Test.conn(:post, "/", compressed)
      conn = Plug.Conn.put_req_header(conn, "content-encoding", "gzip")

      conn = Auth2ApiEx.Utils.RequestDecompression.call(conn, [])

      assert conn.halted == false
      raw = conn.private[:raw_body]
      assert Jason.decode!(raw) == Jason.decode!(original)
    end

    test "decompresses zstd body" do
      original = ~s({"model":"claude","messages":[{"role":"user","content":"hello"}]})
      compressed = :ezstd.compress(original)

      conn = Plug.Test.conn(:post, "/", compressed)
      conn = Plug.Conn.put_req_header(conn, "content-encoding", "zstd")

      conn = Auth2ApiEx.Utils.RequestDecompression.call(conn, [])

      assert conn.halted == false
      raw = conn.private[:raw_body]
      assert Jason.decode!(raw) == Jason.decode!(original)
    end

    test "passes through uncompressed body unchanged" do
      body = ~s({"model":"claude"})

      conn = Plug.Test.conn(:post, "/", body)

      conn = Auth2ApiEx.Utils.RequestDecompression.call(conn, [])

      assert conn.halted == false
    end

    test "halts with 400 on unsupported Content-Encoding" do
      conn = Plug.Test.conn(:post, "/", "data")
      conn = Plug.Conn.put_req_header(conn, "content-encoding", "br")

      conn = Auth2ApiEx.Utils.RequestDecompression.call(conn, [])

      assert conn.halted == true
    end

    test "halts with 400 on corrupted gzip body" do
      conn = Plug.Test.conn(:post, "/", "not gzip data")
      conn = Plug.Conn.put_req_header(conn, "content-encoding", "gzip")

      conn = Auth2ApiEx.Utils.RequestDecompression.call(conn, [])

      assert conn.halted == true
    end

    test "ignores empty body with Content-Encoding" do
      conn = Plug.Test.conn(:post, "/", "")
      conn = Plug.Conn.put_req_header(conn, "content-encoding", "gzip")

      conn = Auth2ApiEx.Utils.RequestDecompression.call(conn, [])

      assert conn.halted == false
    end
  end

  # ══════════════════════════════════════════════════
  # RequestDecompression → parse_body pipeline (e2e)
  # ══════════════════════════════════════════════════

  describe "RequestDecompression → parse_body pipeline" do
    setup do
      # ETS tables normally created at app start — ensure they exist for
      # --no-start test runs (the rate_limit plug uses :auth2api_ex_rate_limit).
      for table <- [:auth2api_ex_rate_limit, :auth2api_ex_sessions] do
        try do
          :ets.new(table, [:set, :public, :named_table])
        rescue
          ArgumentError -> :ok
        end
      end

      config = %Auth2ApiEx.Config{
        host: "127.0.0.1",
        port: 8319,
        auth_dir: "/tmp/auth2api_ex-test",
        api_keys: MapSet.new(["sk-test-key"]),
        admin_username: nil,
        admin_password: nil,
        body_limit: "10mb",
        cloaking: %{},
        timeouts: %{},
        debug: "off"
      }

      Application.put_env(:auth2api_ex, :config, config)
      :ok
    end

    test "gzip-compressed body is parsed correctly through full pipeline" do
      original =
        Jason.encode!(%{
          "model" => "claude-sonnet-4-6",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        })

      compressed = :zlib.gzip(original)

      conn = Plug.Test.conn(:post, "/v1/messages", compressed)
      conn = Plug.Conn.put_req_header(conn, "content-encoding", "gzip")
      conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")
      conn = Plug.Conn.put_req_header(conn, "x-api-key", "sk-test-key")

      # Run through the full Server plug pipeline
      conn = Auth2ApiEx.Server.call(conn, [])

      # Should NOT be halted
      assert conn.halted == false
      # Body should be the decompressed JSON
      assert conn.assigns[:parsed_body] == %{
               "model" => "claude-sonnet-4-6",
               "messages" => [%{"role" => "user", "content" => "hello"}]
             }
    end

    test "zstd-compressed body is parsed correctly through full pipeline" do
      original =
        Jason.encode!(%{
          "model" => "claude-sonnet-4-6",
          "messages" => [%{"role" => "user", "content" => "test"}]
        })

      compressed = :ezstd.compress(original)

      conn = Plug.Test.conn(:post, "/v1/messages", compressed)
      conn = Plug.Conn.put_req_header(conn, "content-encoding", "zstd")
      conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")
      conn = Plug.Conn.put_req_header(conn, "x-api-key", "sk-test-key")

      conn = Auth2ApiEx.Server.call(conn, [])
      assert conn.halted == false

      assert conn.assigns[:parsed_body] == %{
               "model" => "claude-sonnet-4-6",
               "messages" => [%{"role" => "user", "content" => "test"}]
             }
    end

    test "uncompressed body still works through pipeline" do
      body = Jason.encode!(%{"model" => "claude-sonnet-4-6"})

      conn = Plug.Test.conn(:post, "/v1/messages", body)
      conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")
      conn = Plug.Conn.put_req_header(conn, "x-api-key", "sk-test-key")
      conn = Auth2ApiEx.Server.call(conn, [])

      assert conn.halted == false

      assert conn.assigns[:parsed_body] == %{"model" => "claude-sonnet-4-6"} ||
               conn.body_params == %{"model" => "claude-sonnet-4-6"} ||
               conn.params == %{"model" => "claude-sonnet-4-6"}
    end

    test "corrupted gzip body halts before reaching handler" do
      conn = Plug.Test.conn(:post, "/v1/messages", "not gzip")
      conn = Plug.Conn.put_req_header(conn, "content-encoding", "gzip")
      conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")
      conn = Plug.Conn.put_req_header(conn, "x-api-key", "sk-test-key")

      conn = Auth2ApiEx.Server.call(conn, [])
      assert conn.halted == true
    end
  end

  # ── Helpers ──

  defp conn_with_headers(headers) do
    Enum.reduce(headers, Plug.Test.conn(:get, "/"), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, String.downcase(key), value)
    end)
  end
end
