defmodule Auth2ApiEx.CLI do
  @moduledoc """
  CLI entry point for auth2api_ex.
  Handles --login, --login --manual, and server startup.
  """

  require Logger

  alias Auth2ApiEx.{Config, Accounts.Manager}
  alias Auth2ApiEx.Auth.{PKCE, OAuth, CodexOAuth, CallbackServer}

  @doc """
  Main entry point — parse CLI args and dispatch.
  """
  @spec main([String.t()]) :: :ok
  def main(args \\ System.argv()) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [login: :boolean, manual: :boolean, config: :string, provider: :string]
      )

    config_path = opts[:config] || "config.yaml"

    if opts[:login] do
      do_login(config_path, opts[:manual] || false, opts[:provider] || "anthropic")
    else
      start_server(config_path)
    end
  end

  defp do_login(config_path, manual, provider) do
    config = Config.load_config(config_path)
    auth_dir = Config.resolve_auth_dir(config.auth_dir)

    # Ensure manager is started for the correct provider
    manager_name = String.to_atom("#{provider}_login_manager")

    {:ok, _} =
      Manager.start_link(
        auth_dir: auth_dir,
        provider: provider,
        name: manager_name
      )

    Manager.load(manager_name)

    pkce = PKCE.generate_pkce_codes()
    state = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    {auth_url, callback_port, callback_path} =
      if provider == "codex" do
        {CodexOAuth.generate_auth_url(state, pkce), 1455, "/auth/callback"}
      else
        {OAuth.generate_auth_url(state, pkce), 54545, "/callback"}
      end

    IO.puts("\nOpen this URL in your browser to login (provider: #{provider}):\n")
    IO.puts(auth_url)

    {code, returned_state} =
      if manual do
        IO.puts(
          "\nAfter login, your browser will redirect to a localhost URL that may fail to load."
        )

        IO.puts("Copy the FULL URL from your browser address bar and paste it here.\n")

        callback_url = IO.gets("Paste callback URL: ") |> String.trim()
        uri = URI.parse(callback_url)
        params = URI.decode_query(uri.query || "")

        code = params["code"] || ""
        returned_state = params["state"] || ""

        if code == "" do
          IO.puts("Error: No authorization code found in URL")
          System.halt(1)
        end

        if returned_state != state do
          IO.puts("Error: State mismatch — possible CSRF attack")
          System.halt(1)
        end

        {code, returned_state}
      else
        IO.puts("\nWaiting for OAuth callback on port #{callback_port}...\n")

        case CallbackServer.wait_for_callback(port: callback_port, callback_path: callback_path) do
          {:ok, result} ->
            {result.code, result.state}

          {:error, reason} ->
            IO.puts("Error: #{reason}")
            System.halt(1)
        end
      end

    IO.puts("Exchanging code for tokens...")

    exchange_result =
      if provider == "codex" do
        CodexOAuth.exchange_code(code, returned_state, state, pkce)
      else
        OAuth.exchange_code_for_tokens(code, returned_state, state, pkce)
      end

    case exchange_result do
      {:ok, token_data} ->
        token_data = %{token_data | provider: provider}
        Manager.add_account(manager_name, token_data)
        IO.puts("\nLogin successful! Account: #{token_data.email}")
        IO.puts("Token expires: #{token_data.expires_at}")

      {:error, reason} ->
        IO.puts("Error: #{reason}")
        System.halt(1)
    end

    :ok
  end

  defp start_server(config_path) do
    # The Application module handles server startup
    # This is called when running as an escript or via mix
    Application.put_env(:auth2api_ex, :config_path, config_path)

    # Start the application
    {:ok, _} = Application.ensure_all_started(:auth2api_ex)

    # Keep the process alive
    Process.sleep(:infinity)
  end
end
