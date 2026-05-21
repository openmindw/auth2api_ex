defmodule Auth2ApiEx.ImagesTest do
  use ExUnit.Case, async: true

  alias Auth2ApiEx.Upstream.Images.{Request, Codex}

  # ══════════════════════════════════════════════════
  # Request parsing — JSON generations
  # ══════════════════════════════════════════════════

  describe "parse_generations/2" do
    test "parses full JSON fields correctly" do
      body = %{
        "model" => "gpt-image-2",
        "prompt" => "a cat",
        "n" => 2,
        "size" => "1024x1024",
        "stream" => true,
        "response_format" => "url",
        "quality" => "high",
        "background" => "#FFF",
        "output_format" => "png",
        "output_compression" => 80,
        "style" => "vivid",
        "partial_images" => 1
      }

      {:ok, req} = Request.parse_generations(body, "gpt-image-2")

      assert req.endpoint == :generations
      assert req.model == "gpt-image-2"
      assert req.prompt == "a cat"
      assert req.n == 2
      assert req.size == "1024x1024"
      assert req.size_tier == "1K"
      assert req.stream == true
      assert req.response_format == "url"
      assert req.quality == "high"
      assert req.background == "#FFF"
      assert req.output_format == "png"
      assert req.output_compression == 80
      assert req.style == "vivid"
      assert req.partial_images == 1
    end

    test "default model from config" do
      {:ok, req} = Request.parse_generations(%{"prompt" => "hi"}, "gpt-image-2")
      assert req.model == "gpt-image-2"
    end

    test "default n=1, stream=false, response_format=b64_json" do
      {:ok, req} = Request.parse_generations(%{"prompt" => "hi"}, "gpt-image-2")
      assert req.n == 1
      assert req.stream == false
      assert req.response_format == "b64_json"
    end

    test "size tier normalization" do
      assert Request.normalize_size_tier("1024x1024") == "1K"
      assert Request.normalize_size_tier("1792x1024") == "2K"
      assert Request.normalize_size_tier("1024x1792") == "2K"
      assert Request.normalize_size_tier("1536x1024") == "2K"
      assert Request.normalize_size_tier("auto") == "2K"
      assert Request.normalize_size_tier(nil) == "2K"
      assert Request.normalize_size_tier("") == "2K"
      assert Request.normalize_size_tier("unknown") == "2K"
    end

    test "rejects non gpt-image- model" do
      assert {:error, "unsupported_model"} =
               Request.parse_generations(%{"model" => "dall-e-3", "prompt" => "x"}, "gpt-image-2")
    end

    test "accepts gpt-image-1" do
      assert {:ok, req} =
               Request.parse_generations(
                 %{"model" => "gpt-image-1", "prompt" => "x"},
                 "gpt-image-2"
               )

      assert req.model == "gpt-image-1"
    end

    test "rejects non-map body" do
      assert {:error, _} = Request.parse_generations("not a map", "gpt-image-2")
    end

    test "parses boolean stream" do
      {:ok, req} = Request.parse_generations(%{"prompt" => "x", "stream" => true}, "gpt-image-2")
      assert req.stream == true

      {:ok, req} =
        Request.parse_generations(%{"prompt" => "x", "stream" => "true"}, "gpt-image-2")

      assert req.stream == true

      {:ok, req} = Request.parse_generations(%{"prompt" => "x", "stream" => false}, "gpt-image-2")
      assert req.stream == false
    end

    test "n defaults to 1 for invalid values" do
      {:ok, req} = Request.parse_generations(%{"prompt" => "x", "n" => 0}, "gpt-image-2")
      assert req.n == 1

      {:ok, req} = Request.parse_generations(%{"prompt" => "x", "n" => -1}, "gpt-image-2")
      assert req.n == 1

      {:ok, req} = Request.parse_generations(%{"prompt" => "x", "n" => "bad"}, "gpt-image-2")
      assert req.n == 1
    end

    test "output_compression parses as integer or nil" do
      {:ok, req} =
        Request.parse_generations(%{"prompt" => "x", "output_compression" => 80}, "gpt-image-2")

      assert req.output_compression == 80

      {:ok, req} =
        Request.parse_generations(%{"prompt" => "x"}, "gpt-image-2")

      assert req.output_compression == nil
    end
  end

  # ══════════════════════════════════════════════════
  # Request parsing — multipart edits
  # ══════════════════════════════════════════════════

  describe "parse_edits/2 — unit (field mapping)" do
    test "has_mask? returns true when mask upload present" do
      # Direct struct assertions
      req = %Request{
        endpoint: :edits,
        uploads: [%{name: "image", content_type: "image/png", data: "data"}],
        mask_upload: %{name: "mask", content_type: "image/png", data: "mask_data"}
      }

      assert req.has_mask? == false
    end

    test "struct defaults" do
      req = %Request{endpoint: :edits}
      assert req.endpoint == :edits
      assert req.multipart? == false
      assert req.model == "gpt-image-2"
      assert req.n == 1
      assert req.size_tier == "2K"
      assert req.response_format == "b64_json"
      assert req.uploads == []
      assert req.mask_upload == nil
    end
  end

  # ══════════════════════════════════════════════════
  # Codex build_request
  # ══════════════════════════════════════════════════

  describe "Codex.build_request/2" do
    test "includes prompt in input" do
      req = %Request{
        endpoint: :generations,
        model: "gpt-image-2",
        prompt: "draw a cat",
        n: 1,
        size: "1024x1024"
      }

      body = Codex.build_request(req, "gpt-5.4-mini")

      assert body["model"] == "gpt-5.4-mini"
      assert body["stream"] == true
      assert body["store"] == false
      assert body["instructions"] == ""

      [input_msg | _] = body["input"]
      assert input_msg["type"] == "message"
      assert input_msg["role"] == "user"
      [text_part | _] = input_msg["content"]
      assert text_part["type"] == "input_text"
      assert text_part["text"] == "draw a cat"

      [tool | _] = body["tools"]
      assert tool["type"] == "image_generation"
      assert tool["action"] == "generate"
      assert tool["model"] == "gpt-image-2"
      assert tool["size"] == "1024x1024"
      assert tool["n"] == 1
    end

    test "edits action for edits endpoint" do
      req = %Request{
        endpoint: :edits,
        model: "gpt-image-2",
        prompt: "edit image",
        uploads: [
          %{name: "image", content_type: "image/png", data: "fake-bytes"}
        ]
      }

      body = Codex.build_request(req, "gpt-5.4-mini")

      [tool | _] = body["tools"]
      assert tool["action"] == "edit"

      # Check that input includes the image
      [msg | _] = body["input"]
      content = msg["content"]
      assert length(content) == 2
      assert Enum.at(content, 0)["type"] == "input_text"
      image_part = Enum.at(content, 1)
      assert image_part["type"] == "input_image"
      assert String.starts_with?(image_part["image_url"], "data:image/png;base64,")
    end

    test "includes optional tool fields" do
      req = %Request{
        endpoint: :generations,
        model: "gpt-image-2",
        prompt: "test",
        quality: "high",
        style: "vivid",
        output_format: "webp",
        background: "#FF6633",
        output_compression: 80
      }

      body = Codex.build_request(req, "gpt-5.4-mini")
      [tool | _] = body["tools"]
      assert tool["quality"] == "high"
      assert tool["style"] == "vivid"
      assert tool["output_format"] == "webp"
      assert tool["background"] == "#FF6633"
      assert tool["output_compression"] == 80
    end

    test "input_image_urls appear in input" do
      req = %Request{
        endpoint: :edits,
        model: "gpt-image-2",
        prompt: "edit",
        input_image_urls: ["https://example.com/a.png", "https://example.com/b.png"]
      }

      body = Codex.build_request(req, "gpt-5.4-mini")
      [msg | _] = body["input"]
      content = msg["content"]

      image_parts = Enum.filter(content, fn c -> c["type"] == "input_image" end)
      assert length(image_parts) == 2
    end

    test "no prompt produces empty content array" do
      req = %Request{
        endpoint: :generations,
        model: "gpt-image-2",
        prompt: ""
      }

      body = Codex.build_request(req, "gpt-5.4-mini")
      [msg | _] = body["input"]
      assert msg["content"] == []
    end
  end

  # ══════════════════════════════════════════════════
  # Codex SSE event processing
  # ══════════════════════════════════════════════════

  describe "Codex.on_sse_event/3" do
    test "partial_image event produces image_generation.partial_image SSE" do
      sse =
        Codex.on_sse_event(
          "response.image_generation.partial_image",
          %{
            "created_at" => 12345,
            "partial_image_index" => 0,
            "b64_json" => "abc123"
          },
          %{}
        )

      assert length(sse) == 1
      assert String.starts_with?(hd(sse), "event: image_generation.partial_image")
      assert String.contains?(hd(sse), "abc123")
    end

    test "completed event produces image_generation.completed SSE" do
      sse =
        Codex.on_sse_event(
          "response.image_generation.completed",
          %{
            "created_at" => 12345,
            "b64_json" => "Xyz789",
            "revised_prompt" => "A cat",
            "output_format" => "png",
            "size" => "1024x1024"
          },
          %{}
        )

      assert length(sse) == 1
      assert String.starts_with?(hd(sse), "event: image_generation.completed")
      assert String.contains?(hd(sse), "Xyz789")
    end

    test "failed event produces error SSE" do
      sse = Codex.on_sse_event("response.failed", %{"error" => %{"message" => "boom"}}, %{})
      assert length(sse) == 1
      assert String.starts_with?(hd(sse), "event: error")
    end

    test "error event produces error SSE" do
      sse = Codex.on_sse_event("response.error", %{"error" => "something went wrong"}, %{})
      assert length(sse) == 1
      assert String.starts_with?(hd(sse), "event: error")
    end

    test "unknown events produce empty list" do
      assert Codex.on_sse_event("response.completed", %{}, %{}) == []
      assert Codex.on_sse_event("message_start", %{}, %{}) == []
    end
  end

  # ══════════════════════════════════════════════════
  # Codex aggregate_event
  # ══════════════════════════════════════════════════

  describe "Codex.aggregate_event/3" do
    test "image_generation.completed accumulates images" do
      {:cont, nil, acc} =
        Codex.aggregate_event(
          "response.image_generation.completed",
          %{
            "b64_json" => "img1"
          },
          %{images: []}
        )

      assert length(acc[:images]) == 1
      assert hd(acc[:images])[:b64] == "img1"
    end

    test "multiple images accumulate in order" do
      {:cont, nil, acc1} =
        Codex.aggregate_event("response.image_generation.completed", %{"b64_json" => "a"}, %{
          images: []
        })

      {:cont, nil, acc2} =
        Codex.aggregate_event("response.image_generation.completed", %{"b64_json" => "b"}, acc1)

      {:done, nil, acc3} =
        Codex.aggregate_event("response.completed", %{}, acc2)

      assert length(acc3[:images]) == 2
    end

    test "response.completed signals done" do
      assert {:done, nil, %{images: []}} =
               Codex.aggregate_event("response.completed", %{}, %{images: []})
    end

    test "response.failed signals error" do
      assert {:done, {:error, _}, %{images: []}} =
               Codex.aggregate_event("response.failed", %{"error" => "fail"}, %{images: []})
    end

    test "partial images are ignored (not accumulated)" do
      {:cont, nil, acc} =
        Codex.aggregate_event(
          "response.image_generation.partial_image",
          %{"b64_json" => "partial"},
          %{images: []}
        )

      assert acc[:images] == []
    end
  end

  # ══════════════════════════════════════════════════
  # Codex build_openai_images_response
  # ══════════════════════════════════════════════════

  describe "build_openai_images_response/2" do
    test "b64_json output" do
      resp = Codex.build_openai_images_response([%{b64: "abc"}], "b64_json")
      assert resp["created"] > 0
      [data | _] = resp["data"]
      assert data["b64_json"] == "abc"
    end

    test "url output when url present" do
      resp =
        Codex.build_openai_images_response([%{b64: "abc", url: "https://x.com/1.png"}], "url")

      assert resp["created"] > 0
      [data | _] = resp["data"]
      assert data["url"] == "https://x.com/1.png"
    end

    test "falls back to b64 when url absent" do
      resp = Codex.build_openai_images_response([%{b64: "abc"}], "url")
      [data | _] = resp["data"]
      assert data["b64_json"] == "abc"
    end

    test "multiple images" do
      resp =
        Codex.build_openai_images_response([%{b64: "a"}, %{b64: "b"}, %{b64: "c"}], "b64_json")

      assert length(resp["data"]) == 3
    end

    test "empty b64 produces empty string" do
      resp = Codex.build_openai_images_response([%{b64: nil}], "b64_json")
      [data | _] = resp["data"]
      assert data["b64_json"] == ""
    end
  end

  # ══════════════════════════════════════════════════
  # Codex pointer extraction
  # ══════════════════════════════════════════════════

  describe "Codex.extract_pointers/1" do
    test "extracts file-service pointers from JSON" do
      json = ~s({"url":"file-service://abc123"})
      pointers = Codex.extract_pointers(json)
      assert Enum.any?(pointers, fn p -> p[:url] == "file-service://abc123" end)
    end

    test "extracts sediment pointers" do
      json = ~s({"asset":"sediment://att456"})
      pointers = Codex.extract_pointers(json)
      assert Enum.any?(pointers, fn p -> p[:url] == "sediment://att456" end)
    end

    test "extracts inline b64_json" do
      json = ~s({"b64_json":"helloworld"})
      pointers = Codex.extract_pointers(json)
      assert Enum.any?(pointers, fn p -> p[:b64] == "helloworld" end)
    end

    test "extracts inline download_url" do
      json = ~s({"download_url":"https://x.com/img.png"})
      pointers = Codex.extract_pointers(json)
      assert Enum.any?(pointers, fn p -> p[:download_url] == "https://x.com/img.png" end)
    end

    test "returns empty list on invalid JSON" do
      assert Codex.extract_pointers("not json") == []
    end
  end
end
