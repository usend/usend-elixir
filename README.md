# usend for Elixir

The official Elixir SDK for [usend](https://usend.et), the email API for developers. Elixir 1.14 or newer, no
dependencies: HTTP goes through OTP's `:httpc` (`:inets` and `:ssl`) and JSON through a small built-in encoder and
decoder (`Usend.JSON`), so it behaves the same on every supported Elixir (the standard `JSON` module only exists from
Elixir 1.18).

> Status: written against the API contract but not yet compiled or tested. Please report problems.

## Install

```elixir
def deps do
  [{:usend, "~> 1.0"}]
end
```

## Quick start

```elixir
client = Usend.new(System.fetch_env!("USEND_API_KEY"))

{:ok, %{"id" => id}} =
  Usend.send_email(client, %{
    from: "Acme <hello@acme.com>",
    to: ["ann@example.com"],
    subject: "Your login code",
    html: "<p>Your code is <b>482913</b></p>"
  })
```

Every function returns `{:ok, decoded_json}` (maps with string keys) or `{:error, %Usend.Error{}}`.

- The key defaults to `USEND_API_KEY`; the base URL to `USEND_BASE_URL` or `https://api.usend.et`
  (`Usend.new(key, base_url: "https://api.example.com", max_retries: 3, timeout: 10_000)`).
- Functions: `send_email`, `get_email`, `list_emails`, `update_email`, `cancel_email`, `email_events`, `send_batch`,
  `list_received`, `get_received`, and `create_`/`list_`/`get_`/`update_`/`delete_` for `template`, `domain`,
  `contact`, `topic`, `broadcast`, `webhook` (plus `api_key`, `segment`, `suppression` with the operations the API
  has), with extras such as `publish_template`, `verify_domain`, `auto_configure_domain`, `send_broadcast`,
  `list_webhook_deliveries`, `replay_webhook_delivery`, `add_contact_to_segment`. See the `Usend` module docs.
  List functions take an optional query map: `Usend.list_emails(client, %{limit: 20})`.
- Idempotency: `Usend.send_email(client, email, idempotency_key: Usend.new_idempotency_key())`.
- Retries: `429 rate_limit_exceeded` honours `retry-after`; idempotent requests (GET, DELETE, or a POST with an
  idempotency key) are also retried on 5xx and network errors. Quota errors are never retried.
- TLS is verified with OTP's CA store (OTP 25+) or the system CA bundle.

## SMTP

The API key is the SMTP password: host `smtp.usend.et`, port 465 (implicit TLS) or 587 (STARTTLS), username `usend`.

```elixir
smtp = Usend.smtp_config(client)               # or Usend.smtp_config(client, port: 587)
# %{host: "smtp.usend.et", port: 465, username: "usend", password: "us_...", ssl: true, starttls: false}

# Swoosh
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  relay: smtp.host, port: smtp.port, username: smtp.username, password: smtp.password,
  ssl: smtp.ssl, tls: if(smtp.starttls, do: :always, else: :never), auth: :always
```

For a self-hosted platform the host comes from the `:host` option, `USEND_SMTP_HOST`, or the base URL
(`https://api.x.com` gives `smtp.x.com`).

## Webhooks

Verify a delivery with the raw body and the request headers. In Phoenix, cache the raw body (a custom `body_reader`
for `Plug.Parsers`) because verification needs the exact bytes.

```elixir
case Usend.Webhook.verify(raw_body, conn.req_headers, System.fetch_env!("USEND_WEBHOOK_SECRET")) do
  {:ok, event} -> handle(event)
  {:error, %Usend.Error{}} -> send_resp(conn, 400, "invalid signature")
end
```

Header names are matched case-insensitively; the default timestamp tolerance is 300 seconds
(`verify(payload, headers, secret, tolerance)`).

## Errors

`%Usend.Error{status_code, name, message}` carries the API's `name` (such as `validation_error`, `not_found`,
`rate_limit_exceeded`); `status_code` is `nil` and `name` is `"application_error"` for network failures, and
`name` is `"invalid_webhook"` for a bad signature.

```elixir
case Usend.get_domain(client, id) do
  {:ok, domain} -> domain
  {:error, %Usend.Error{status_code: 404}} -> nil
end
```

## More resources

`create_`/`list_`/`get_`/`update_`/`delete_` also exist for `event`, `automation`, `inbox` and `contact_property`.
Others: `send_event` (returns 202), `duplicate_automation`, `stop_automation`, `list_automation_runs`,
`get_automation_run`, inbox labels, threads and drafts (`create_inbox_label`, `list_inbox_threads`,
`reply_inbox_email`, `forward_inbox_email`, `create_inbox_draft`, `send_inbox_draft`, ...), `list_logs`, `get_log`,
`dmarc_check`, `oauth_metadata`/`oauth_register`/`oauth_token`/`oauth_revoke` (an OAuth access token `usa_...` can be
passed as the key), `email_metrics`, `share_email`, `send_test_email`, `email_insights`, domain claims and
`domain_insights`, template versions, `update_segment`, `list_segment_contacts`, `segment_metrics`, `contact_stats`,
`import_contacts`, `create_contact_import`, `list_contact_imports`, `cancel_broadcast`, `duplicate_broadcast`,
`broadcast_performance`, `broadcast_clicked_links`, webhook events and `rotate_webhook_secret`,
`batch_create_suppressions`, `batch_delete_suppressions` and `stats/2`.

`Usend.list_broadcast_recipients(client, id, type)` requires a `type` (sent, delivered, opened, clicked, bounced,
complained, unsubscribed, suppressed) and returns rows with `id`, `contact_id`, `email` and optionally `count`,
`bounce_type`, `clicked_links`. `Usend.get_received_raw/2` and `get_received_attachment/3` return binaries.
`batch_delete_suppressions` sends a DELETE with a body, which needs a recent OTP.

Not covered: session-only endpoints (organization, billing, members), the `/audiences` routes and `/emails/receiving`
aliases. Docs: https://usend.et/docs
