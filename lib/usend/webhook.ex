defmodule Usend.Webhook do
  @moduledoc """
  Verifies usend webhook deliveries (Standard Webhooks signatures).

      case Usend.Webhook.verify(raw_body, conn.req_headers, secret) do
        {:ok, event} -> handle(event)
        {:error, %Usend.Error{}} -> send_resp(conn, 400, "invalid")
      end

  Pass the raw request body exactly as received (in Phoenix, cache it in a custom `Plug.Parsers` body reader).
  """

  alias Usend.{Error, JSON}

  @doc """
  Verifies a delivery. `headers` is a map or a list of `{name, value}` tuples (names are matched case-insensitively),
  `secret` is the endpoint's signing secret (`whsec_...`) and `tolerance` the allowed clock difference in seconds.
  Returns `{:ok, event}` (the decoded body) or `{:error, %Usend.Error{name: "invalid_webhook"}}`.
  """
  @spec verify(binary(), map() | [{binary(), binary()}], binary(), non_neg_integer()) ::
          {:ok, map()} | {:error, Error.t()}
  def verify(payload, headers, secret, tolerance \\ 300) when is_binary(payload) and is_binary(secret) do
    h = Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

    with {:ok, id, ts, sigs} <- fetch_headers(h),
         {:ok, t} <- parse_ts(ts),
         :ok <- check_tolerance(t, tolerance),
         {:ok, key} <- decode_secret(secret),
         :ok <- check_signature(sigs, expected(key, id, ts, payload)) do
      case JSON.decode(payload) do
        {:ok, event} -> {:ok, event}
        {:error, _} -> invalid("Webhook payload is not valid JSON")
      end
    end
  end

  defp fetch_headers(%{"webhook-id" => id, "webhook-timestamp" => ts, "webhook-signature" => sigs}),
    do: {:ok, id, ts, sigs}

  defp fetch_headers(_), do: invalid("Missing webhook-id, webhook-timestamp or webhook-signature header")

  defp parse_ts(ts) do
    case Integer.parse(String.trim(ts)) do
      {t, ""} -> {:ok, t}
      _ -> invalid("Invalid webhook timestamp")
    end
  end

  defp check_tolerance(t, tolerance) do
    if abs(System.os_time(:second) - t) > tolerance,
      do: invalid("Webhook timestamp is too old or too new"),
      else: :ok
  end

  defp decode_secret(secret) do
    raw = String.replace_prefix(secret, "whsec_", "")

    case Base.decode64(raw) do
      {:ok, key} -> {:ok, key}
      :error -> invalid("Invalid webhook secret")
    end
  end

  defp expected(key, id, ts, payload) do
    :crypto.mac(:hmac, :sha256, key, "#{id}.#{ts}.#{payload}") |> Base.encode64()
  end

  defp check_signature(sigs, expected) do
    ok? =
      sigs
      |> String.split(" ", trim: true)
      |> Enum.reduce(false, fn part, acc ->
        case String.split(part, ",", parts: 2) do
          ["v1", sig] -> secure_compare(sig, expected) or acc
          _ -> acc
        end
      end)

    if ok?, do: :ok, else: invalid("Invalid webhook signature")
  end

  # Constant-time comparison (:crypto.hash_equals/2 needs OTP 25).
  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    import Bitwise

    a
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(b))
    |> Enum.reduce(0, fn {x, y}, acc -> acc ||| bxor(x, y) end)
    |> Kernel.==(0)
  end

  defp secure_compare(_, _), do: false

  defp invalid(message), do: {:error, Error.new(message, "invalid_webhook")}
end
