defmodule Usend.HTTP do
  @moduledoc false
  # Request core on top of OTP's :httpc, with retries.

  alias Usend.{Error, JSON}

  @spec request(Usend.t(), atom(), String.t(), term(), [{String.t(), String.t()}]) ::
          {:ok, term()} | {:error, Error.t()}
  def request(%Usend{} = client, method, path, body \\ nil, extra_headers \\ [], opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    payload = if is_nil(body), do: nil, else: JSON.encode(body)

    safe? =
      method in [:get, :delete, :put] or
        Enum.any?(extra_headers, fn {k, _} -> String.downcase(k) == "idempotency-key" end)

    attempt(client, method, path, payload, extra_headers, safe?, 0, opts[:raw] == true)
  end

  defp attempt(client, method, path, payload, extra_headers, safe?, n, raw?) do
    delay = min(8_000, 500 * Integer.pow(2, n))
    last? = n >= client.max_retries

    case do_request(client, method, path, payload, extra_headers) do
      {:ok, status, _headers, text} when status in 200..299 and raw? ->
        {:ok, text}

      {:ok, status, _headers, text} when status in 200..299 ->
        decode_success(text, status)

      {:ok, status, headers, text} ->
        error = decode_error(text, status)
        retry? = (status == 429 and error.name == "rate_limit_exceeded") or (safe? and status >= 500 and status != 501)

        if retry? and not last? do
          Process.sleep(retry_after(headers) || delay)
          attempt(client, method, path, payload, extra_headers, safe?, n + 1, raw?)
        else
          {:error, error}
        end

      {:error, reason} ->
        if safe? and not last? do
          Process.sleep(delay)
          attempt(client, method, path, payload, extra_headers, safe?, n + 1, raw?)
        else
          {:error, Error.new(format_reason(reason))}
        end
    end
  end

  defp do_request(client, method, path, payload, extra_headers) do
    url = String.to_charlist(client.base_url <> path)

    headers =
      [
        {"authorization", "Bearer " <> client.api_key},
        {"user-agent", "usend-elixir/" <> Usend.version()},
        {"accept", "application/json"}
      ] ++ Enum.map(extra_headers, fn {k, v} -> {String.downcase(k), v} end)

    headers = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    request =
      cond do
        payload != nil -> {url, headers, ~c"application/json", payload}
        method in [:post, :patch, :put] -> {url, headers, ~c"application/json", "{}"}
        true -> {url, headers}
      end

    http_opts = [timeout: client.timeout, connect_timeout: min(client.timeout, 10_000)] ++ ssl_opts(url)

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_vsn, status, _reason}, resp_headers, resp_body}} ->
        {:ok, status, resp_headers, to_string(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp ssl_opts(~c"https" ++ _) do
    [ssl: Usend.TLS.options()]
  end

  defp ssl_opts(_), do: []

  defp decode_success(text, status) do
    if String.trim(text) == "" do
      {:ok, %{}}
    else
      case JSON.decode(text) do
        {:ok, value} -> {:ok, value}
        {:error, _} -> {:error, Error.new("Invalid JSON in response", "application_error", status)}
      end
    end
  end

  defp decode_error(text, status) do
    case JSON.decode(text) do
      {:ok, %{"error" => err} = m} when is_binary(err) and not is_map_key(m, "name") ->
        # OAuth endpoints answer { error, error_description }
        Error.new(m["error_description"] || "HTTP #{status}", err, status)

      {:ok, %{} = m} ->
        Error.new(
          if(is_binary(m["message"]), do: m["message"], else: "HTTP #{status}"),
          if(is_binary(m["name"]), do: m["name"], else: "application_error"),
          status
        )

      _ ->
        Error.new("HTTP #{status}", "application_error", status)
    end
  end

  defp retry_after(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == "retry-after" do
        case Float.parse(String.trim(to_string(v))) do
          {secs, _} -> trunc(min(30.0, max(0.0, secs)) * 1000)
          :error -> nil
        end
      end
    end)
  end

  defp format_reason(%{__exception__: true} = e), do: Exception.message(e)
  defp format_reason(reason), do: inspect(reason)
end

defmodule Usend.TLS do
  @moduledoc false
  # Verified TLS for :httpc. OTP 25+ ships the CA store; older releases fall back to the system bundle.

  def options do
    base = [verify: :verify_peer, customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]]

    Code.ensure_loaded(:public_key)

    cond do
      function_exported?(:public_key, :cacerts_get, 0) ->
        [cacerts: :public_key.cacerts_get()] ++ base

      file = Enum.find(system_bundles(), &File.exists?/1) ->
        [cacertfile: String.to_charlist(file)] ++ base

      true ->
        base
    end
  end

  defp system_bundles do
    [
      "/etc/ssl/certs/ca-certificates.crt",
      "/etc/pki/tls/certs/ca-bundle.crt",
      "/etc/ssl/cert.pem",
      "/usr/local/etc/openssl/cert.pem"
    ]
  end
end
