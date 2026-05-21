defmodule Auth2ApiEx.Auth.CallbackServer do
  @moduledoc """
  OAuth callback HTTP server.
  Listens on 127.0.0.1 for the OAuth redirect from the browser.

  Supports configurable port and callback path:
    - Anthropic: port 54545, path "/callback"
    - Codex:     port 1455,  path "/auth/callback"
  """

  require Logger

  @success_html """
  <!DOCTYPE html>
  <html><body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;text-align:center;padding-top:80px;background:#f8fafc;color:#0f172a">
  <h1 style="font-size:24px;font-weight:600;margin-bottom:8px">登录成功</h1>
  <p style="color:#475569;font-size:14px">您可以关闭此标签页并返回终端。</p>
  </body></html>
  """

  @doc """
  Start a temporary HTTP server and wait for the OAuth callback.

  Options:
    - :port — TCP port (default 54545)
    - :timeout_ms — timeout in ms (default 300_000 / 5 min)
    - :callback_path — the HTTP path to listen for (default "/callback")

  Returns {:ok, %{code: code, state: state}} or {:error, reason}.
  """
  @spec wait_for_callback(keyword()) :: {:ok, map()} | {:error, String.t()}
  def wait_for_callback(opts \\ []) do
    port = Keyword.get(opts, :port, 54545)
    timeout_ms = Keyword.get(opts, :timeout_ms, 300_000)
    callback_path = Keyword.get(opts, :callback_path, "/callback")

    parent = self()
    ref = make_ref()

    case :gen_tcp.listen(port, [
           :inet,
           {:ip, {127, 0, 0, 1}},
           {:backlog, 5},
           {:reuseaddr, true}
         ]) do
      {:ok, listen_socket} ->
        Logger.info("OAuth callback server listening on http://127.0.0.1:#{port}#{callback_path}")

        pid =
          spawn(fn ->
            accept_callback(listen_socket, parent, ref, callback_path)
          end)

        timer_ref = Process.send_after(self(), {:callback_timeout, ref}, timeout_ms)

        receive do
          {:callback_result, ^ref, result} ->
            Process.cancel_timer(timer_ref)
            :gen_tcp.close(listen_socket)
            if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :shutdown)
            result

          {:callback_timeout, ^ref} ->
            :gen_tcp.close(listen_socket)
            if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :shutdown)
            {:error, "OAuth callback timeout"}
        end

      {:error, reason} ->
        {:error, "Failed to start callback server on port #{port}: #{inspect(reason)}"}
    end
  end

  defp accept_callback(listen_socket, parent, ref, callback_path) do
    case :gen_tcp.accept(listen_socket, 60_000) do
      {:ok, socket} ->
        handle_callback_connection(socket, parent, ref, callback_path)
        :gen_tcp.close(socket)

      {:error, _} ->
        :ok
    end
  end

  defp handle_callback_connection(socket, parent, ref, callback_path) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, request} ->
        request_str = to_string(request)

        case parse_http_request(request_str) do
          {:ok, method, path, _headers} ->
            handle_request(socket, method, path, parent, ref, callback_path)

          :error ->
            send_response(socket, 400, "Bad Request")
        end

      {:error, _} ->
        :ok
    end
  end

  defp handle_request(socket, "GET", path, parent, ref, callback_path) do
    case {String.starts_with?(path, callback_path), path} do
      {true, ^callback_path} ->
        # Match exact callback path with no query
        send_response(socket, 400, "Missing code or state parameter")

      {true, _path} ->
        # callback_path followed by query string
        query = String.replace_prefix(path, callback_path, "")
        uri = URI.parse(callback_path <> query)
        params = URI.decode_query(uri.query || "")

        case params["error"] do
          error when is_binary(error) ->
            send_response(socket, 400, "OAuth error: #{error}")
            do_send(parent, {:callback_result, ref, {:error, "OAuth error: #{error}"}})

          _nil ->
            code = params["code"]
            state = params["state"]

            if code && state do
              send_response(socket, 302, "", [{"location", "/success"}])
              do_send(parent, {:callback_result, ref, {:ok, %{code: code, state: state}}})
            else
              send_response(socket, 400, "Missing code or state parameter")
            end
        end

      {false, "/success"} ->
        send_response(socket, 200, @success_html, [{"content-type", "text/html"}])

      _ ->
        send_response(socket, 404, "Not Found")
    end
  end

  defp parse_http_request(request) do
    case String.split(request, "\r\n", parts: 2) do
      [request_line | _rest] ->
        case String.split(request_line, " ") do
          [method, path, _version] -> {:ok, method, path, %{}}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp send_response(socket, status, body, extra_headers \\ []) do
    reason = status_reason(status)
    headers = [{"connection", "close"} | extra_headers]
    header_str = Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end) |> Enum.join("\r\n")

    response =
      case status do
        302 ->
          "HTTP/1.1 #{status} #{reason}\r\n#{header_str}\r\n\r\n"

        _ ->
          "HTTP/1.1 #{status} #{reason}\r\ncontent-length: #{byte_size(body)}\r\n#{header_str}\r\n\r\n#{body}"
      end

    :gen_tcp.send(socket, response)
  end

  defp status_reason(200), do: "OK"
  defp status_reason(302), do: "Found"
  defp status_reason(400), do: "Bad Request"
  defp status_reason(404), do: "Not Found"
  defp status_reason(_), do: "Unknown"

  defp do_send(pid, msg), do: Kernel.send(pid, msg)
end
