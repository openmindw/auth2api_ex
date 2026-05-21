defmodule Auth2ApiEx.Auth.ReqHttpClient do
  @moduledoc false

  @behaviour Auth2ApiEx.Auth.HttpClient

  @impl true
  def get(url, opts) do
    headers = Keyword.get(opts, :headers, [])

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{} = response} ->
        {:ok, %{status: response.status, body: response.body, headers: response.headers}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @impl true
  def post(url, opts) do
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body)

    case Req.post(url, headers: headers, body: body) do
      {:ok, %Req.Response{} = response} ->
        {:ok, %{status: response.status, body: response.body, headers: response.headers}}

      {:error, exception} ->
        {:error, exception}
    end
  end
end
