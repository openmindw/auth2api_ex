defmodule Auth2ApiEx.Config do
  @moduledoc """
  Configuration loading and parsing for auth2api_ex.
  Reads YAML config file, merges with defaults, and normalizes values.
  """

  defstruct host: "",
            port: 8318,
            auth_dir: "~/.auth2api_ex",
            api_keys: MapSet.new(),
            admin_username: nil,
            admin_password: nil,
            body_limit: "200mb",
            cloaking: %{cli_version: "2.1.88", entrypoint: "cli"},
            images: %{
              default_model: "gpt-image-2",
              upstream_codex_model: "gpt-5.4-mini",
              max_image_bytes: 20 * 1024 * 1024,
              max_upload_bytes: 20 * 1024 * 1024,
              pointer_retry_count: 8,
              pointer_retry_delay_ms: 750,
              edits_oauth_max_n: 1
            },
            timeouts: %{
              messages_ms: 120_000,
              stream_messages_ms: 600_000,
              count_tokens_ms: 30_000
            },
            debug: "off"

  @type debug_mode :: :off | :errors | :verbose
  @type t :: %__MODULE__{
          host: String.t(),
          port: integer(),
          auth_dir: String.t(),
          api_keys: MapSet.t(String.t()),
          admin_username: String.t() | nil,
          admin_password: String.t() | nil,
          body_limit: String.t(),
          cloaking: %{cli_version: String.t(), entrypoint: String.t()},
          images: %{
            default_model: String.t(),
            upstream_codex_model: String.t(),
            max_image_bytes: integer(),
            max_upload_bytes: integer(),
            pointer_retry_count: integer(),
            pointer_retry_delay_ms: integer(),
            edits_oauth_max_n: integer()
          },
          timeouts: %{
            messages_ms: integer(),
            stream_messages_ms: integer(),
            count_tokens_ms: integer()
          },
          debug: String.t()
        }

  @default_raw %{
    host: "",
    port: 8318,
    auth_dir: "~/.auth2api_ex",
    api_keys: [],
    admin: %{username: nil, password: nil},
    body_limit: "200mb",
    cloaking: %{cli_version: "2.1.88", entrypoint: "cli"},
    images: %{
      default_model: "gpt-image-2",
      upstream_codex_model: "gpt-5.4-mini",
      max_image_bytes: 20 * 1024 * 1024,
      max_upload_bytes: 20 * 1024 * 1024,
      pointer_retry_count: 8,
      pointer_retry_delay_ms: 750,
      edits_oauth_max_n: 1
    },
    timeouts: %{messages_ms: 120_000, stream_messages_ms: 600_000, count_tokens_ms: 30_000},
    debug: "off"
  }

  @doc """
  Check if the current debug level includes the given level.
  """
  @spec debug_level?(String.t(), :errors | :verbose) :: boolean()
  def debug_level?(debug, level) do
    cond do
      debug == "verbose" -> true
      debug == "errors" and level == :errors -> true
      true -> false
    end
  end

  @doc """
  Expand tilde and resolve relative paths in auth directory.
  """
  @spec resolve_auth_dir(String.t()) :: String.t()
  def resolve_auth_dir(dir) do
    dir
    |> String.replace("~", System.get_env("HOME") || "/root", global: false)
    |> Path.expand()
  end

  @doc """
  Generate a random API key with sk- prefix.
  """
  @spec generate_api_key() :: String.t()
  def generate_api_key do
    "sk-" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
  end

  @doc """
  Normalize debug mode from various input formats.
  """
  @spec normalize_debug_mode(any()) :: String.t()
  def normalize_debug_mode(true), do: "errors"
  def normalize_debug_mode(false), do: "off"
  def normalize_debug_mode(nil), do: "off"
  def normalize_debug_mode(value) when value in ["off", "errors", "verbose"], do: value
  def normalize_debug_mode(_), do: "off"

  @doc """
  Load configuration from a YAML file, merging with defaults.
  Auto-generates an API key if none is configured.
  """
  @spec load_config(String.t()) :: t()
  def load_config(config_path \\ "config.yaml") do
    raw =
      if File.exists?(config_path) do
        parsed = YamlElixir.read_from_file!(config_path)
        merge_raw(@default_raw, parsed)
      else
        IO.puts("Config file not found at #{config_path}, using defaults")
        @default_raw
      end

    raw = %{raw | debug: normalize_debug_mode(raw.debug)}

    # Auto-generate admin credentials if not configured
    raw =
      if is_nil(raw.admin.username) or raw.admin.username == "" do
        username = generate_admin_username()
        password = generate_admin_password()
        raw = put_in(raw, [:admin, :username], username)
        raw = put_in(raw, [:admin, :password], password)
        write_config_file(config_path, raw)

        IO.puts(
          "\nGenerated admin credentials (saved to #{config_path}):\n\n  username: #{username}\n  password: #{password}\n"
        )

        raw
      else
        raw
      end

    # Auto-generate API key only when missing from both file and loaded config
    api_keys =
      case List.wrap(raw.api_keys) do
        [] ->
          key = generate_api_key()
          raw = %{raw | api_keys: [key]}
          write_config_file(config_path, raw)
          IO.puts("\nGenerated API key (saved to #{config_path}):\n\n  #{key}\n")
          [key]

        keys ->
          keys
      end

    %__MODULE__{
      host: raw.host,
      port: raw.port,
      auth_dir: raw.auth_dir,
      api_keys: MapSet.new(api_keys),
      admin_username: raw.admin.username,
      admin_password: raw.admin.password,
      body_limit: raw.body_limit,
      cloaking: raw.cloaking,
      images: raw.images,
      timeouts: raw.timeouts,
      debug: raw.debug
    }
  end

  @doc """
  Add an API key to the YAML config file.
  """
  @spec add_api_key(String.t(), String.t()) :: {:ok, t()} | {:error, any()}
  def add_api_key(config_path, key) do
    update_config(config_path, fn raw ->
      api_keys = raw.api_keys |> List.wrap() |> Enum.uniq()

      if key in api_keys do
        raw
      else
        %{raw | api_keys: api_keys ++ [key]}
      end
    end)
  end

  @doc """
  Remove an API key from the YAML config file.
  """
  @spec remove_api_key(String.t(), String.t()) :: {:ok, t()} | {:error, any()}
  def remove_api_key(config_path, key) do
    raw = load_raw_config(config_path)

    if key in raw.api_keys do
      updated = %{raw | api_keys: Enum.reject(raw.api_keys, &(&1 == key))}
      write_config_file(config_path, updated)
      {:ok, config_from_raw(updated)}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Parse body limit string (e.g., "200mb") to bytes.
  """
  @spec parse_body_limit(String.t()) :: integer()
  def parse_body_limit(limit) do
    limit = String.downcase(limit)

    cond do
      String.ends_with?(limit, "gb") ->
        String.trim_trailing(limit, "gb") |> String.to_integer() |> Kernel.*(1024 * 1024 * 1024)

      String.ends_with?(limit, "mb") ->
        String.trim_trailing(limit, "mb") |> String.to_integer() |> Kernel.*(1024 * 1024)

      String.ends_with?(limit, "kb") ->
        String.trim_trailing(limit, "kb") |> String.to_integer() |> Kernel.*(1024)

      true ->
        String.to_integer(limit)
    end
  end

  # ── Private helpers ──

  defp merge_raw(defaults, parsed) when is_map(parsed) do
    raw_admin = Map.get(parsed, "admin", %{})
    raw_cloaking = Map.get(parsed, "cloaking", %{})
    raw_codex = Map.get(raw_cloaking, "codex", %{})

    cloaking = %{
      cli_version: Map.get(raw_cloaking, "cli-version", defaults.cloaking.cli_version),
      entrypoint: Map.get(raw_cloaking, "entrypoint", defaults.cloaking.entrypoint),
      codex: %{
        "originator" => Map.get(raw_codex, "originator", "codex_cli_rs"),
        "cli-version" => Map.get(raw_codex, "cli-version", "0.125.0")
      }
    }

    raw_timeouts = Map.get(parsed, "timeouts", %{})

    raw_images = Map.get(parsed, "images", %{})

    images = %{
      default_model: Map.get(raw_images, "default-model", defaults.images.default_model),
      upstream_codex_model:
        Map.get(raw_images, "upstream-codex-model", defaults.images.upstream_codex_model),
      max_image_bytes: Map.get(raw_images, "max-image-bytes", defaults.images.max_image_bytes),
      max_upload_bytes: Map.get(raw_images, "max-upload-bytes", defaults.images.max_upload_bytes),
      pointer_retry_count:
        Map.get(raw_images, "pointer-retry-count", defaults.images.pointer_retry_count),
      pointer_retry_delay_ms:
        Map.get(raw_images, "pointer-retry-delay-ms", defaults.images.pointer_retry_delay_ms),
      edits_oauth_max_n:
        Map.get(raw_images, "edits-oauth-max-n", defaults.images.edits_oauth_max_n)
    }

    timeouts = %{
      messages_ms: Map.get(raw_timeouts, "messages-ms", defaults.timeouts.messages_ms),
      stream_messages_ms:
        Map.get(raw_timeouts, "stream-messages-ms", defaults.timeouts.stream_messages_ms),
      count_tokens_ms: Map.get(raw_timeouts, "count-tokens-ms", defaults.timeouts.count_tokens_ms)
    }

    %{
      host: Map.get(parsed, "host", defaults.host),
      port: Map.get(parsed, "port", defaults.port),
      auth_dir: Map.get(parsed, "auth-dir", defaults.auth_dir),
      api_keys: Map.get(parsed, "api-keys", defaults.api_keys),
      admin: %{
        username: Map.get(raw_admin, "username", defaults.admin.username),
        password: Map.get(raw_admin, "password", defaults.admin.password)
      },
      body_limit: Map.get(parsed, "body-limit", defaults.body_limit),
      cloaking: cloaking,
      images: images,
      timeouts: timeouts,
      debug: Map.get(parsed, "debug", defaults.debug)
    }
  end

  defp merge_raw(defaults, _), do: defaults

  defp load_raw_config(config_path) do
    if File.exists?(config_path) do
      config_path
      |> YamlElixir.read_from_file!()
      |> then(&merge_raw(@default_raw, &1))
    else
      @default_raw
    end
  end

  defp update_config(config_path, fun) do
    raw = config_path |> load_raw_config() |> fun.()
    write_config_file(config_path, raw)
    {:ok, config_from_raw(raw)}
  rescue
    error -> {:error, error}
  end

  defp config_from_raw(raw) do
    %__MODULE__{
      host: raw.host,
      port: raw.port,
      auth_dir: raw.auth_dir,
      api_keys: MapSet.new(List.wrap(raw.api_keys)),
      admin_username: raw.admin.username,
      admin_password: raw.admin.password,
      body_limit: raw.body_limit,
      cloaking: raw.cloaking,
      images: raw.images,
      timeouts: raw.timeouts,
      debug: raw.debug
    }
  end

  defp write_config_file(path, raw) do
    api_keys_yaml =
      case List.wrap(raw.api_keys) do
        [] -> " []"
        keys -> "\n" <> Enum.map_join(keys, "\n", fn k -> "  - #{k}" end)
      end

    admin_yaml =
      case {raw.admin.username, raw.admin.password} do
        {nil, nil} ->
          ""

        {username, password} ->
          "admin:\n  username: \"#{username || ""}\"\n  password: \"#{password || ""}\"\n"
      end

    yaml = """
    host: "#{raw.host}"
    port: #{raw.port}
    auth-dir: "#{raw.auth_dir}"
    api-keys:#{api_keys_yaml}
    #{admin_yaml}body-limit: "#{raw.body_limit}"
    cloaking:
      cli-version: "#{raw.cloaking.cli_version}"
      entrypoint: "#{raw.cloaking.entrypoint}"
    images:
      default-model: "#{raw.images.default_model}"
      upstream-codex-model: "#{raw.images.upstream_codex_model}"
      max-image-bytes: #{raw.images.max_image_bytes}
      max-upload-bytes: #{raw.images.max_upload_bytes}
      pointer-retry-count: #{raw.images.pointer_retry_count}
      pointer-retry-delay-ms: #{raw.images.pointer_retry_delay_ms}
      edits-oauth-max-n: #{raw.images.edits_oauth_max_n}
    timeouts:
      messages-ms: #{raw.timeouts.messages_ms}
      stream-messages-ms: #{raw.timeouts.stream_messages_ms}
      count-tokens-ms: #{raw.timeouts.count_tokens_ms}
    debug: "#{raw.debug}"
    """

    File.write!(path, yaml, mode: 0o600)
  end

  # Generate a random admin username like `admin-xxxxxx`
  defp generate_admin_username do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode64() |> binary_part(0, 6)
    "admin-#{suffix}"
  end

  # Generate a random admin password
  defp generate_admin_password do
    :crypto.strong_rand_bytes(16) |> Base.encode64() |> binary_part(0, 22)
  end
end
