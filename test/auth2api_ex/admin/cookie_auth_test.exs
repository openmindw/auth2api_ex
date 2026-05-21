defmodule Auth2ApiEx.Auth.CookieAuthTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  describe "authorize/2" do
    test "full flow: get org -> get code -> exchange -> token" do
      Auth2ApiEx.MockHttpClient
      |> expect(:get, fn url, opts ->
        assert url =~ "claude.ai/api/organizations"
        assert {"cookie", "sessionKey=sk-session-123"} in opts[:headers]

        {:ok,
         %{
           status: 200,
           body: [
             %{"uuid" => "org-abc", "name" => "My Org", "capabilities" => ["chat"]}
           ]
         }}
      end)
      |> expect(:post, fn url, opts ->
        assert url =~ "claude.ai/v1/oauth/org-abc/authorize"
        assert {"cookie", "sessionKey=sk-session-123"} in opts[:headers]

        {:ok,
         %{
           status: 302,
           headers: [
             {"location",
              "https://platform.claude.com/oauth/code/callback?code=auth-code-xyz&state=abc"}
           ]
         }}
      end)
      |> expect(:post, fn url, opts ->
        assert url =~ "/v1/oauth/token"
        body = Jason.decode!(opts[:body])
        assert body["code"] == "auth-code-xyz"
        assert body["grant_type"] == "authorization_code"

        {:ok,
         %{
           status: 200,
           body: %{
             "access_token" => "sk-ant-new-token",
             "refresh_token" => "rt-refresh",
             "expires_in" => 3600,
             "account" => %{"uuid" => "acct-1", "email_address" => "user@test.com"}
           }
         }}
      end)

      assert {:ok, token} =
               Auth2ApiEx.Auth.CookieAuth.authorize("sk-session-123",
                 http_client: Auth2ApiEx.MockHttpClient
               )

      assert token.access_token == "sk-ant-new-token"
      assert token.email == "user@test.com"
      assert token.account_uuid == "acct-1"
    end

    test "returns error when organizations request fails" do
      Auth2ApiEx.MockHttpClient
      |> expect(:get, fn _url, _opts ->
        {:ok, %{status: 403, body: "Forbidden"}}
      end)

      assert {:error, msg} =
               Auth2ApiEx.Auth.CookieAuth.authorize("bad-key", http_client: Auth2ApiEx.MockHttpClient)

      assert msg =~ "organizations"
    end

    test "selects team org over personal when available" do
      parent = self()

      Auth2ApiEx.MockHttpClient
      |> expect(:get, fn _url, _opts ->
        {:ok,
         %{
           status: 200,
           body: [
             %{"uuid" => "org-personal", "name" => "Personal", "capabilities" => ["chat"]},
             %{
               "uuid" => "org-team",
               "name" => "Team",
               "raven_type" => "team",
               "capabilities" => ["chat", "team"]
             }
           ]
         }}
      end)
      |> expect(:post, fn url, _opts ->
        send(parent, {:authorize_url, url})

        {:ok,
         %{
           status: 302,
           headers: [
             {"location",
              "https://platform.claude.com/oauth/code/callback?code=auth-code-xyz&state=abc"}
           ]
         }}
      end)
      |> expect(:post, fn _url, _opts ->
        {:ok,
         %{
           status: 200,
           body: %{
             "access_token" => "tok",
             "refresh_token" => "rt",
             "expires_in" => 3600,
             "account" => %{"uuid" => "a", "email_address" => "t@t.com"}
           }
         }}
      end)

      assert {:ok, _token} =
               Auth2ApiEx.Auth.CookieAuth.authorize("sk-key", http_client: Auth2ApiEx.MockHttpClient)

      assert_receive {:authorize_url, url}
      assert url =~ "/org-team/authorize"
    end
  end
end
