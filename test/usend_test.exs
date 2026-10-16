defmodule UsendTest do
  use ExUnit.Case, async: true

  @secret_raw "super-secret-key-bytes"
  @secret "whsec_" <> Base.encode64(@secret_raw)

  defp sign(id, ts, body),
    do: :crypto.mac(:hmac, :sha256, @secret_raw, "#{id}.#{ts}.#{body}") |> Base.encode64()

  test "json round trip" do
    {:ok, v} = Usend.JSON.decode(~s({"a":[1,2.5,-3e2,"x\\n\\u00e9\\ud83d\\ude00"],"b":null,"c":true,"d":{}}))
    assert v["a"] == [1, 2.5, -300.0, "x\né😀"]
    assert v["b"] == nil and v["c"] == true and v["d"] == %{}
    assert {:ok, ^v} = v |> Usend.JSON.encode() |> Usend.JSON.decode()
    assert Usend.JSON.encode(%{from: "a\"b"}) == ~s({"from":"a\\"b"})
    assert {:error, _} = Usend.JSON.decode(~s({"a":))
    assert {:error, _} = Usend.JSON.decode("[1] x")
  end

  test "smtp_config" do
    c = Usend.new("us_k")
    assert %{host: "smtp.usend.et", port: 465, username: "usend", password: "us_k", ssl: true, starttls: false} = Usend.smtp_config(c)
    assert %{host: "smtp.example.com", starttls: true} = Usend.smtp_config(Usend.new("us_k", base_url: "https://api.example.com/"), port: 587)
    assert %{host: "mx.me"} = Usend.smtp_config("us_k", host: "mx.me")
    assert_raise Usend.Error, fn -> Usend.smtp_config(c, port: 25) end
  end

  test "query strings and encoding" do
    assert Usend.qs(%{limit: 5, after: nil}) == "?limit=5"
    assert Usend.qs(%{}) == ""
    assert Usend.enc("a b/c") == "a%20b%2Fc"
  end

  test "webhook verify" do
    body = ~s({"type":"email.delivered"})
    ts = Integer.to_string(System.os_time(:second))
    headers = %{"Webhook-Id" => "msg_1", "Webhook-Timestamp" => ts, "Webhook-Signature" => "v1,AAAA v1," <> sign("msg_1", ts, body)}
    assert {:ok, %{"type" => "email.delivered"}} = Usend.Webhook.verify(body, headers, @secret)

    bad = Map.put(headers, "Webhook-Signature", "v1," <> sign("msg_1", ts, body <> " "))
    assert {:error, %Usend.Error{name: "invalid_webhook"}} = Usend.Webhook.verify(body, bad, @secret)

    old = Integer.to_string(System.os_time(:second) - 3600)
    stale = [{"webhook-id", "msg_1"}, {"webhook-timestamp", old}, {"webhook-signature", "v1," <> sign("msg_1", old, body)}]
    assert {:error, %Usend.Error{name: "invalid_webhook"}} = Usend.Webhook.verify(body, stale, @secret)
    assert {:error, %Usend.Error{name: "invalid_webhook"}} = Usend.Webhook.verify(body, %{}, @secret)
  end

  # A one-connection-at-a-time HTTP stand-in for the API; nothing leaves the machine.
  defp mock_api(parent) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      loop = fn loop ->
        {:ok, sock} = :gen_tcp.accept(listen)
        {:ok, data} = :gen_tcp.recv(sock, 0, 2000)
        send(parent, {:request, data})
        body = ~s({"id":"l1"})

        :gen_tcp.send(
          sock,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
        )

        :gen_tcp.close(sock)
        loop.(loop)
      end

      loop.(loop)
    end)

    "http://127.0.0.1:#{port}"
  end

  test "short links" do
    client = Usend.new("us_test", base_url: mock_api(self()))

    assert {:ok, %{"id" => "l1"}} = Usend.create_short_link(client, %{target_url: "https://example.com", code: "abc"})
    assert_receive {:request, req}
    assert req =~ "POST /short-links HTTP/1.1"
    assert String.downcase(req) =~ "authorization: bearer us_test"
    assert req =~ ~s("code":"abc")

    assert {:ok, _} = Usend.short_link_stats(client, "l 1", %{days: 7})
    assert_receive {:request, req}
    assert req =~ "GET /short-links/l%201/stats?days=7 HTTP/1.1"

    assert {:ok, _} = Usend.update_short_link(client, "l1", %{disabled: true, expires_at: nil})
    assert_receive {:request, req}
    assert req =~ "PATCH /short-links/l1 HTTP/1.1"
    assert req =~ ~s("expires_at":null)

    assert {:ok, _} = Usend.delete_short_link(client, "l1")
    assert_receive {:request, req}
    assert req =~ "DELETE /short-links/l1 HTTP/1.1"
  end
end
