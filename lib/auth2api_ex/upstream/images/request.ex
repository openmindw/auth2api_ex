defmodule Auth2ApiEx.Upstream.Images.Request do
  @moduledoc """
  OpenAI Images API request parser.

  Parses JSON and multipart/form-data requests for both
  /v1/images/generations and /v1/images/edits.

  ## Struct fields (subset — only what the Codex path needs)

    * `endpoint` — `:generations` or `:edits`
    * `multipart?` — whether the request was multipart
    * `model` — client-requested model (defaults to configurable)
    * `prompt` — text prompt
    * `stream` — client-requested stream flag
    * `n` — expected image count
    * `size` — original size string
    * `size_tier` — normalised tier (`"1K"` | `"2K"`)
    * `response_format` — `"b64_json"` | `"url"`
    * `uploads` — list of `%{name, content_type, data}` maps
    * `mask_upload` — optional mask upload
    * `raw_body` — raw binary for downstream inspection

  Other OpenAI native options (quality, background, output_format,
  output_compression, moderation, input_fidelity, style,
  partial_images, input_image_urls, mask_image_url, has_mask?)
  are parsed but only forwarded via the Codex tool block.
  """

  defstruct endpoint: :generations,
            multipart?: false,
            model: "gpt-image-2",
            prompt: "",
            stream: false,
            n: 1,
            size: nil,
            size_tier: "2K",
            response_format: "b64_json",
            quality: nil,
            background: nil,
            output_format: nil,
            output_compression: nil,
            moderation: nil,
            input_fidelity: nil,
            style: nil,
            partial_images: nil,
            has_mask?: false,
            input_image_urls: [],
            mask_image_url: nil,
            uploads: [],
            mask_upload: nil,
            raw_body: <<>>

  @type t :: %__MODULE__{}

  @doc """
  Parse a JSON generations request body.

  Returns `{:ok, %Request{}}` or `{:error, reason}`.
  """
  @spec parse_generations(map(), String.t()) :: {:ok, __MODULE__.t()} | {:error, String.t()}
  def parse_generations(body, default_model) when is_map(body) do
    model = Map.get(body, "model") || default_model

    with :ok <- validate_model(model) do
      size = Map.get(body, "size")
      stream = parse_bool(Map.get(body, "stream"))

      {:ok,
       %__MODULE__{
         endpoint: :generations,
         model: model,
         prompt: Map.get(body, "prompt") || "",
         stream: stream,
         n: parse_pos_int(Map.get(body, "n"), 1),
         size: size,
         size_tier: normalize_size_tier(size),
         response_format: Map.get(body, "response_format") || "b64_json",
         quality: Map.get(body, "quality"),
         background: Map.get(body, "background"),
         output_format: Map.get(body, "output_format"),
         output_compression: parse_int_or_nil(Map.get(body, "output_compression")),
         moderation: Map.get(body, "moderation"),
         input_fidelity: Map.get(body, "input_fidelity"),
         style: Map.get(body, "style"),
         partial_images: parse_int_or_nil(Map.get(body, "partial_images")),
         raw_body: Jason.encode!(body)
       }}
    end
  end

  def parse_generations(_body, _default_model), do: {:error, "request body must be a JSON object"}

  @doc """
  Parse a multipart edits request body.

  `conn` must have `Plug.Parsers.MULTIPART` populated (i.e. `conn.body_params`
  contains multipart fields and `conn.params` has `Plug.Upload` structs).

  Returns `{:ok, %Request{}}` or `{:error, reason}`.
  """
  @spec parse_edits(Plug.Conn.t(), String.t()) :: {:ok, __MODULE__.t()} | {:error, String.t()}
  def parse_edits(conn, default_model) do
    body_params = conn.body_params || %{}
    uploads = get_uploads(conn)

    prompt = Map.get(body_params, "prompt") || ""
    model = Map.get(body_params, "model") || default_model

    with :ok <- validate_model(model) do
      size = Map.get(body_params, "size")
      stream = parse_bool(Map.get(body_params, "stream"))

      {:ok,
       %__MODULE__{
         endpoint: :edits,
         multipart?: true,
         model: model,
         prompt: prompt,
         stream: stream,
         n: parse_pos_int(Map.get(body_params, "n"), 1),
         size: size,
         size_tier: normalize_size_tier(size),
         response_format: Map.get(body_params, "response_format") || "b64_json",
         quality: Map.get(body_params, "quality"),
         background: Map.get(body_params, "background"),
         output_format: Map.get(body_params, "output_format"),
         output_compression: parse_int_or_nil(Map.get(body_params, "output_compression")),
         moderation: Map.get(body_params, "moderation"),
         input_fidelity: Map.get(body_params, "input_fidelity"),
         style: Map.get(body_params, "style"),
         partial_images: parse_int_or_nil(Map.get(body_params, "partial_images")),
         has_mask?: has_mask?(body_params, uploads),
         uploads: filter_images(uploads),
         mask_upload: pick_mask(body_params, uploads),
         raw_body: <<>>
       }}
    end
  end

  # ── Normalisation ──

  @doc """
  Normalise image size to a tier string ("1K" or "2K").
  """
  @spec normalize_size_tier(String.t() | nil) :: String.t()
  def normalize_size_tier(nil), do: "2K"
  def normalize_size_tier(""), do: "2K"
  def normalize_size_tier("1024x1024"), do: "1K"
  def normalize_size_tier("auto"), do: "2K"
  def normalize_size_tier(_), do: "2K"

  # ── Validation ──

  @spec validate_model(String.t()) :: :ok | {:error, String.t()}
  def validate_model(model) when is_binary(model) do
    if String.starts_with?(model, "gpt-image-") do
      :ok
    else
      {:error, "unsupported_model"}
    end
  end

  # ── Private helpers ──

  defp parse_bool(nil), do: false
  defp parse_bool(val) when is_boolean(val), do: val
  defp parse_bool(val) when is_binary(val), do: String.downcase(val) == "true"
  defp parse_bool(_), do: false

  defp parse_pos_int(nil, default), do: default
  defp parse_pos_int(val, _default) when is_integer(val) and val > 0, do: val

  defp parse_pos_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_pos_int(_, default), do: default

  defp parse_int_or_nil(nil), do: nil

  defp parse_int_or_nil(val) when is_integer(val), do: val

  defp parse_int_or_nil(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # ── Multipart helpers ──

  # Extract uploaded files from conn.params structured by Plug.Parsers.MULTIPART.
  # Returns list of %{name: field_name, content_type: mime, data: binary}.
  defp get_uploads(conn) do
    params = conn.params || %{}

    Enum.flat_map(params, fn {name, value} ->
      case value do
        %Plug.Upload{} -> [upload_to_map(name, value)]
        _ when is_list(value) -> Enum.map(value, fn v -> upload_to_map(name, v) end)
        _ -> []
      end
    end)
  end

  defp upload_to_map(name, %Plug.Upload{content_type: mime, path: path}) do
    data = File.read!(path)
    %{name: name, content_type: mime, data: data}
  end

  defp filter_images(uploads) do
    Enum.filter(uploads, fn u -> image_field?(u.name) end)
  end

  defp pick_mask(_body_params, uploads) do
    Enum.find(uploads, fn u -> u.name == "mask" end)
  end

  defp has_mask?(_body_params, uploads) do
    Enum.any?(uploads, fn u -> u.name == "mask" end)
  end

  defp image_field?("image"), do: true
  defp image_field?(<<"image[", _::binary>>), do: true
  defp image_field?(_), do: false
end
