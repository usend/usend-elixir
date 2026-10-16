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
end
