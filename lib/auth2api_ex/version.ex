defmodule Auth2ApiEx.Version do
  @moduledoc """
  Provides version and runtime information for the auth2api_ex service.

  Build-time data is read from `priv/version.json`, runtime data is gathered
  from Application env and system state.
  """

  @app :auth2api_ex

  @doc """
  Returns a map with version info:

    %{
      app: "auth2api_ex-elixir",
      version: "1.0.0",
      git_commit: "5c8b08b",
      build_time: "2026-05-13T13:24:00Z",
      started_at: "2026-05-13T21:16:17Z",
      uptime_seconds: 833,
      env: "prod",
      config_path: "/opt/auth2api_ex-elixir/config.yaml",
      auth_dir: "/root/.auth2api_ex"
    }
  """
  @spec info() :: map()
  def info do
    build_info = load_build_info()
    runtime_info = gather_runtime_info()

    Map.merge(build_info, runtime_info)
  end

  defp load_build_info do
    build =
      case File.read(version_json_path()) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, map} -> map
            _ -> %{}
          end

        {:error, _} ->
          %{}
      end

    vsn =
      case Application.spec(@app, :vsn) do
        nil -> "unknown"
        v -> List.to_string(v)
      end

    %{
      app: Map.get(build, "app", "auth2api_ex-elixir"),
      version: Map.get(build, "version", System.get_env("AUTH2API_VERSION") || vsn),
      git_commit:
        Map.get(build, "git_commit", System.get_env("AUTH2API_GIT_COMMIT") || "unknown"),
      build_time: Map.get(build, "build_time", System.get_env("AUTH2API_BUILD_TIME") || "unknown")
    }
  end

  defp version_json_path do
    case :code.priv_dir(@app) do
      {:error, _reason} ->
        Path.expand("priv/version.json")

      path ->
        path |> to_string() |> Path.join("version.json")
    end
  end

  defp gather_runtime_info do
    started_at = Application.get_env(@app, :started_at)

    uptime =
      case started_at do
        nil -> nil
        dt -> DateTime.diff(DateTime.utc_now(), dt, :second)
      end

    env = Application.get_env(@app, :env) || "unknown"

    %{
      started_at: format_started_at(started_at),
      uptime_seconds: uptime,
      env: env,
      config_path: Application.get_env(@app, :config_path) || "config.yaml",
      auth_dir: Application.get_env(@app, :auth_dir) || "~/.auth2api_ex"
    }
  end

  defp format_started_at(nil), do: nil

  defp format_started_at(dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
