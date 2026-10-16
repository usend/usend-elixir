defmodule Usend do
  @moduledoc """
  Elixir client for [usend](https://usend.et), the email API for developers. No dependencies: HTTP goes through
  OTP's `:httpc` and JSON through the small built-in `Usend.JSON`.

      client = Usend.new(System.fetch_env!("USEND_API_KEY"))

      {:ok, %{"id" => id}} =
        Usend.send_email(client, %{
          from: "Acme <hello@acme.com>",
          to: ["ann@example.com"],
          subject: "Hello",
          html: "<p>It works!</p>"
        })

  Every function returns `{:ok, decoded_json}` or `{:error, %Usend.Error{}}`. Responses are maps with string keys.
  List functions take an optional query map (`Usend.list_emails(client, %{limit: 20})`).

  ## Functions

    * emails: `send_email/3`, `get_email/2`, `list_emails/2`, `update_email/3`, `cancel_email/2`, `email_events/2`,
      `list_email_attachments/2`, `get_email_attachment/3`, `send_batch/3`
    * received (inbound) emails: `list_received/2`, `get_received/2`
    * `create_*`, `list_*`, `get_*`, `update_*`, `delete_*` for `template`, `domain`, `contact`, `topic`,
      `short_link` (plus `short_link_stats/3`), `broadcast`, `webhook`; `create_*`, `list_*`, `delete_*` for `api_key`, `suppression`;
      `create_segment`, `list_segments`, `get_segment`, `delete_segment`
    * `publish_template/2`, `duplicate_template/2`, `verify_domain/2`, `auto_configure_domain/3`,
      `send_broadcast/3`, `test_broadcast/3`, `list_webhook_deliveries/3`, `replay_webhook_delivery/3`
    * contacts: `list_contact_segments/2`, `add_contact_to_segment/3`, `remove_contact_from_segment/3`,
      `list_contact_topics/2`, `update_contact_topics/3`
    * events, automations, inboxes, logs, stats, OAuth and more: see the README
    * `smtp_config/2`, `Usend.Webhook.verify/4`

  Rate-limited requests (`429 rate_limit_exceeded`) are retried honouring `retry-after`; idempotent requests
  (GET, DELETE, or a POST with an idempotency key) are also retried on 5xx and network errors.
  """

  alias Usend.HTTP

  @version "1.3.0"
  @default_base_url "https://api.usend.et"

  defstruct [:api_key, base_url: @default_base_url, max_retries: 2, timeout: 30_000]

  @type t :: %__MODULE__{api_key: String.t(), base_url: String.t(), max_retries: non_neg_integer(), timeout: pos_integer()}
  @type result :: {:ok, term()} | {:error, Usend.Error.t()}

  @doc false
  def version, do: @version

  @doc """
  Builds a client. The key defaults to the `USEND_API_KEY` environment variable.

  Options: `:base_url` (default `USEND_BASE_URL` or `https://api.usend.et`), `:max_retries` (default 2),
  `:timeout` in milliseconds (default 30000).
  """
  @spec new(String.t() | nil, keyword()) :: t()
  def new(api_key \\ nil, opts \\ []) do
    key = non_empty(api_key) || System.get_env("USEND_API_KEY")

    if is_nil(key) or key == "" do
      raise Usend.Error,
        message: "Missing API key. Pass it to Usend.new(\"us_...\") or set USEND_API_KEY.",
        name: "missing_api_key"
    end

    base = non_empty(opts[:base_url]) || non_empty(System.get_env("USEND_BASE_URL")) || @default_base_url

    %__MODULE__{
      api_key: key,
      base_url: String.trim_trailing(base, "/"),
      max_retries: Keyword.get(opts, :max_retries, 2),
      timeout: Keyword.get(opts, :timeout, 30_000)
    }
  end

  @doc "A fresh random idempotency key."
  @spec new_idempotency_key() :: String.t()
  def new_idempotency_key do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  # ---- SMTP ----

  @doc """
  SMTP settings for sending through usend; the API key is the password. Accepts a client or an API key.

  Options: `:port` (465 implicit TLS, or 587 STARTTLS; default 465), `:host`, `:base_url` (used with a bare key).
  The host is `smtp.usend.et`; for a self-hosted platform pass `:host`, set `USEND_SMTP_HOST`, or use a base URL
  (`https://api.x.com` gives `smtp.x.com`).

  Returns `%{host:, port:, username: "usend", password:, ssl: boolean, starttls: boolean}`.
  Raises `Usend.Error` for an unsupported port.
  """
  @spec smtp_config(t() | String.t() | nil, keyword()) :: map()
  def smtp_config(client_or_key \\ nil, opts \\ [])

  def smtp_config(%__MODULE__{} = client, opts),
    do: smtp_config(client.api_key, Keyword.put_new(opts, :base_url, client.base_url))

  def smtp_config(key, opts) do
    key = non_empty(key) || System.get_env("USEND_API_KEY")
    port = Keyword.get(opts, :port, 465)

    if is_nil(key) or key == "" do
      raise Usend.Error,
        message: "Missing API key. Pass it to Usend.smtp_config(\"us_...\") or set USEND_API_KEY.",
        name: "missing_api_key"
    end

    if port not in [465, 587] do
      raise Usend.Error, message: "usend accepts SMTP on port 465 (TLS) or 587 (STARTTLS).", name: "invalid_port"
    end

    host =
      non_empty(opts[:host]) || non_empty(System.get_env("USEND_SMTP_HOST")) || smtp_host_for(opts[:base_url])

    %{host: host, port: port, username: "usend", password: key, ssl: port == 465, starttls: port == 587}
  end

  defp smtp_host_for(nil), do: "smtp.usend.et"

  defp smtp_host_for(base_url) do
    case URI.parse(base_url).host do
      "api." <> rest -> "smtp." <> rest
      _ -> "smtp.usend.et"
    end
  end

  # ---- emails ----

  @doc """
  Sends an email. Options: `:idempotency_key` (a repeated key returns the first result instead of sending twice).
  """
  @spec send_email(t(), map(), keyword()) :: result()
  def send_email(%__MODULE__{} = client, params, opts \\ []),
    do: HTTP.request(client, :post, "/emails", params, idem(opts))

  @spec get_email(t(), String.t()) :: result()
  def get_email(client, id), do: HTTP.request(client, :get, "/emails/#{enc(id)}")

  @spec list_emails(t(), map() | keyword()) :: result()
  def list_emails(client, query \\ %{}), do: HTTP.request(client, :get, "/emails" <> qs(query))

  @doc "Reschedules a scheduled email."
  @spec update_email(t(), String.t(), String.t()) :: result()
  def update_email(client, id, scheduled_at),
    do: HTTP.request(client, :patch, "/emails/#{enc(id)}", %{scheduled_at: scheduled_at})

  @spec cancel_email(t(), String.t()) :: result()
  def cancel_email(client, id), do: HTTP.request(client, :post, "/emails/#{enc(id)}/cancel")

  @doc "The email's events (a list), oldest first."
  @spec email_events(t(), String.t()) :: result()
  def email_events(client, id), do: HTTP.request(client, :get, "/emails/#{enc(id)}/events")

  @spec list_email_attachments(t(), String.t()) :: result()
  def list_email_attachments(client, email_id), do: HTTP.request(client, :get, "/emails/#{enc(email_id)}/attachments")

  @spec get_email_attachment(t(), String.t(), String.t()) :: result()
  def get_email_attachment(client, email_id, id),
    do: HTTP.request(client, :get, "/emails/#{enc(email_id)}/attachments/#{enc(id)}")

  @doc "Sends up to 100 emails. Options: `:idempotency_key`, `:validation` (`\"strict\"` or `\"permissive\"`)."
  @spec send_batch(t(), [map()], keyword()) :: result()
  def send_batch(%__MODULE__{} = client, emails, opts \\ []) when is_list(emails) do
    headers = idem(opts) ++ if(opts[:validation], do: [{"x-batch-validation", opts[:validation]}], else: [])
    HTTP.request(client, :post, "/emails/batch", emails, headers)
  end

  # ---- received (inbound) ----

  @spec list_received(t(), map() | keyword()) :: result()
  def list_received(client, query \\ %{}), do: HTTP.request(client, :get, "/inbound/emails" <> qs(query))

  @spec get_received(t(), String.t()) :: result()
  def get_received(client, id), do: HTTP.request(client, :get, "/inbound/emails/#{enc(id)}")

  # ---- collections ----

  @collections [
    {"template", "templates", "/templates", [:create, :list, :get, :update, :delete]},
    {"domain", "domains", "/domains", [:create, :list, :get, :update, :delete]},
    {"contact", "contacts", "/contacts", [:create, :list, :get, :update, :delete]},
    {"topic", "topics", "/topics", [:create, :list, :get, :update, :delete]},
    {"short_link", "short_links", "/short-links", [:create, :list, :get, :update, :delete]},
    {"broadcast", "broadcasts", "/broadcasts", [:create, :list, :get, :update, :delete]},
    {"webhook", "webhooks", "/webhooks", [:create, :list, :get, :update, :delete]},
    {"api_key", "api_keys", "/api-keys", [:create, :list, :delete]},
    {"segment", "segments", "/segments", [:create, :list, :get, :delete]},
    {"suppression", "suppressions", "/suppressions", [:create, :list, :delete]}
  ]

  for {one, many, path, ops} <- @collections do
    if :create in ops do
      @doc false
      def unquote(:"create_#{one}")(%__MODULE__{} = client, params),
        do: HTTP.request(client, :post, unquote(path), params)
    end

    if :list in ops do
      @doc false
      def unquote(:"list_#{many}")(%__MODULE__{} = client, query \\ %{}),
        do: HTTP.request(client, :get, unquote(path) <> qs(query))
    end

    if :get in ops do
      @doc false
      def unquote(:"get_#{one}")(%__MODULE__{} = client, id),
        do: HTTP.request(client, :get, unquote(path) <> "/" <> enc(id))
    end

    if :update in ops do
      @doc false
      def unquote(:"update_#{one}")(%__MODULE__{} = client, id, params),
        do: HTTP.request(client, :patch, unquote(path) <> "/" <> enc(id), params)
    end

    if :delete in ops do
      @doc false
      def unquote(:"delete_#{one}")(%__MODULE__{} = client, id),
        do: HTTP.request(client, :delete, unquote(path) <> "/" <> enc(id))
    end
  end

  # ---- short links ----

  @doc """
  Click statistics of a short link for the last `days` days (1 to 365, default 30):
  `Usend.short_link_stats(client, id, %{days: 7})`.
  """
  @spec short_link_stats(t(), String.t(), map() | keyword()) :: result()
  def short_link_stats(client, id, query \\ %{}),
    do: HTTP.request(client, :get, "/short-links/#{enc(id)}/stats" <> qs(query))

  # ---- templates ----

  @doc "Publishes the template's draft (only published versions send)."
  @spec publish_template(t(), String.t()) :: result()
  def publish_template(client, id_or_alias), do: HTTP.request(client, :post, "/templates/#{enc(id_or_alias)}/publish")

  @spec duplicate_template(t(), String.t()) :: result()
  def duplicate_template(client, id_or_alias),
    do: HTTP.request(client, :post, "/templates/#{enc(id_or_alias)}/duplicate")

  # ---- domains ----

  @spec verify_domain(t(), String.t()) :: result()
  def verify_domain(client, id), do: HTTP.request(client, :post, "/domains/#{enc(id)}/verify")

  @doc "Publishes the domain's DNS records at Cloudflare with a one-time API token (never stored)."
  @spec auto_configure_domain(t(), String.t(), String.t()) :: result()
  def auto_configure_domain(client, id, api_token),
    do: HTTP.request(client, :post, "/domains/#{enc(id)}/auto-configure", %{provider: "cloudflare", api_token: api_token})

  # ---- contacts ----

  @spec list_contact_segments(t(), String.t()) :: result()
  def list_contact_segments(client, id_or_email),
    do: HTTP.request(client, :get, "/contacts/#{enc(id_or_email)}/segments")

  @spec add_contact_to_segment(t(), String.t(), String.t()) :: result()
  def add_contact_to_segment(client, id_or_email, segment_id),
    do: HTTP.request(client, :post, "/contacts/#{enc(id_or_email)}/segments/#{enc(segment_id)}")

  @spec remove_contact_from_segment(t(), String.t(), String.t()) :: result()
  def remove_contact_from_segment(client, id_or_email, segment_id),
    do: HTTP.request(client, :delete, "/contacts/#{enc(id_or_email)}/segments/#{enc(segment_id)}")

  @doc "The contact's topic subscriptions (a list)."
  @spec list_contact_topics(t(), String.t()) :: result()
  def list_contact_topics(client, id_or_email), do: HTTP.request(client, :get, "/contacts/#{enc(id_or_email)}/topics")

  @doc ~s(`params` is `%{topics: [%{id: "...", subscription: "opt_in" | "opt_out"}]}`.)
  @spec update_contact_topics(t(), String.t(), map()) :: result()
  def update_contact_topics(client, id_or_email, params),
    do: HTTP.request(client, :patch, "/contacts/#{enc(id_or_email)}/topics", params)

  # ---- broadcasts ----

  @doc "Sends a broadcast now, or at `:scheduled_at` when given."
  @spec send_broadcast(t(), String.t(), keyword()) :: result()
  def send_broadcast(client, id, opts \\ []) do
    body = if opts[:scheduled_at], do: %{scheduled_at: opts[:scheduled_at]}, else: %{}
    HTTP.request(client, :post, "/broadcasts/#{enc(id)}/send", body)
  end

  @spec test_broadcast(t(), String.t(), String.t()) :: result()
  def test_broadcast(client, id, to), do: HTTP.request(client, :post, "/broadcasts/#{enc(id)}/test", %{to: to})

  # ---- webhooks ----

  @spec list_webhook_deliveries(t(), String.t(), map() | keyword()) :: result()
  def list_webhook_deliveries(client, id, query \\ %{}),
    do: HTTP.request(client, :get, "/webhooks/#{enc(id)}/deliveries" <> qs(query))

  @spec replay_webhook_delivery(t(), String.t(), String.t()) :: result()
  def replay_webhook_delivery(client, id, delivery_id),
    do: HTTP.request(client, :post, "/webhooks/#{enc(id)}/deliveries/#{enc(delivery_id)}/replay")

  # ---- inboxes, events, automations, logs and more ----

  def create_contact_property(client, params), do: HTTP.request(client, :post, "/contact-properties", params)

  def list_contact_properties(client, query \\ %{}), do: HTTP.request(client, :get, "/contact-properties" <> qs(query))

  def get_contact_property(client, id), do: HTTP.request(client, :get, "/contact-properties/" <> enc(id))

  def update_contact_property(client, id, params), do: HTTP.request(client, :patch, "/contact-properties/" <> enc(id), params)

  def delete_contact_property(client, id), do: HTTP.request(client, :delete, "/contact-properties/" <> enc(id))

  def create_event(client, params), do: HTTP.request(client, :post, "/events", params)

  def list_events(client, query \\ %{}), do: HTTP.request(client, :get, "/events" <> qs(query))

  def get_event(client, id), do: HTTP.request(client, :get, "/events/" <> enc(id))

  def update_event(client, id, params), do: HTTP.request(client, :patch, "/events/" <> enc(id), params)

  def delete_event(client, id), do: HTTP.request(client, :delete, "/events/" <> enc(id))

  def create_automation(client, params), do: HTTP.request(client, :post, "/automations", params)

  def list_automations(client, query \\ %{}), do: HTTP.request(client, :get, "/automations" <> qs(query))

  def get_automation(client, id), do: HTTP.request(client, :get, "/automations/" <> enc(id))

  def update_automation(client, id, params), do: HTTP.request(client, :patch, "/automations/" <> enc(id), params)

  def delete_automation(client, id), do: HTTP.request(client, :delete, "/automations/" <> enc(id))

  def create_inbox(client, params), do: HTTP.request(client, :post, "/inboxes", params)

  def list_inboxes(client, query \\ %{}), do: HTTP.request(client, :get, "/inboxes" <> qs(query))

  def get_inbox(client, id), do: HTTP.request(client, :get, "/inboxes/" <> enc(id))

  def update_inbox(client, id, params), do: HTTP.request(client, :patch, "/inboxes/" <> enc(id), params)

  def delete_inbox(client, id), do: HTTP.request(client, :delete, "/inboxes/" <> enc(id))

  def email_metrics(client, query \\ %{}), do: HTTP.request(client, :get, "/emails/metrics" <> qs(query))

  def share_email(client, id, params), do: HTTP.request(client, :post, "/emails/#{enc(id)}/share", params)

  def send_test_email(client, params), do: HTTP.request(client, :post, "/emails/test", params)

  def email_insights(client, id), do: HTTP.request(client, :get, "/emails/#{enc(id)}/insights")

  def create_domain_claim(client, params), do: HTTP.request(client, :post, "/domains/claim", params)

  def get_domain_claim(client, id), do: HTTP.request(client, :get, "/domains/claim/#{enc(id)}")

  def verify_domain_claim(client, id), do: HTTP.request(client, :post, "/domains/claim/#{enc(id)}/verify")

  def domain_insights(client, id), do: HTTP.request(client, :get, "/domains/#{enc(id)}/insights")

  def dmarc_check(client, params), do: HTTP.request(client, :post, "/tools/dmarc-check", params)

  def list_logs(client, query \\ %{}), do: HTTP.request(client, :get, "/logs" <> qs(query))

  def get_log(client, id), do: HTTP.request(client, :get, "/logs/#{enc(id)}")

  def list_log_user_agents(client), do: HTTP.request(client, :get, "/logs/user-agents")

  def update_api_key(client, id, params), do: HTTP.request(client, :patch, "/api-keys/#{enc(id)}", params)

  def update_segment(client, id, params), do: HTTP.request(client, :patch, "/segments/#{enc(id)}", params)

  def list_segment_contacts(client, id, query \\ %{}), do: HTTP.request(client, :get, "/segments/#{enc(id)}/contacts" <> qs(query))

  def segment_metrics(client, id), do: HTTP.request(client, :get, "/segments/#{enc(id)}/metrics")

  def contact_stats(client), do: HTTP.request(client, :get, "/contacts/stats")

  def import_contacts(client, params), do: HTTP.request(client, :post, "/contacts/import", params)

  def create_contact_import(client, params), do: HTTP.request(client, :post, "/contacts/imports", params)

  def list_contact_imports(client, query \\ %{}), do: HTTP.request(client, :get, "/contacts/imports" <> qs(query))

  def get_contact_import(client, id), do: HTTP.request(client, :get, "/contacts/imports/#{enc(id)}")

  def cancel_broadcast(client, id), do: HTTP.request(client, :post, "/broadcasts/#{enc(id)}/cancel")

  def duplicate_broadcast(client, id), do: HTTP.request(client, :post, "/broadcasts/#{enc(id)}/duplicate")

  def broadcast_clicked_links(client, id), do: HTTP.request(client, :get, "/broadcasts/#{enc(id)}/clicked-links")

  def broadcast_performance(client, id), do: HTTP.request(client, :get, "/broadcasts/#{enc(id)}/performance")

  def list_template_versions(client, id, query \\ %{}), do: HTTP.request(client, :get, "/templates/#{enc(id)}/versions" <> qs(query))

  def get_template_version(client, id, version_id), do: HTTP.request(client, :get, "/templates/#{enc(id)}/versions/#{enc(version_id)}")

  def restore_template_version(client, id, version_id), do: HTTP.request(client, :post, "/templates/#{enc(id)}/versions/#{enc(version_id)}/restore")

  def send_event(client, params), do: HTTP.request(client, :post, "/events/send", params)

  def duplicate_automation(client, id), do: HTTP.request(client, :post, "/automations/#{enc(id)}/duplicate")

  def stop_automation(client, id), do: HTTP.request(client, :post, "/automations/#{enc(id)}/stop")

  def list_automation_runs(client, id, query \\ %{}), do: HTTP.request(client, :get, "/automations/#{enc(id)}/runs" <> qs(query))

  def get_automation_run(client, id, run_id), do: HTTP.request(client, :get, "/automations/#{enc(id)}/runs/#{enc(run_id)}")

  def list_webhook_events(client, query \\ %{}), do: HTTP.request(client, :get, "/webhooks/events" <> qs(query))

  def get_webhook_event(client, id), do: HTTP.request(client, :get, "/webhooks/events/#{enc(id)}")

  def replay_webhook_event(client, id), do: HTTP.request(client, :post, "/webhooks/events/#{enc(id)}/replay")

  def list_webhook_event_attempts(client, id, query \\ %{}), do: HTTP.request(client, :get, "/webhooks/events/#{enc(id)}/attempts" <> qs(query))

  def rotate_webhook_secret(client, id), do: HTTP.request(client, :post, "/webhooks/#{enc(id)}/rotate-secret")

  def get_suppression(client, id), do: HTTP.request(client, :get, "/suppressions/#{enc(id)}")

  def batch_create_suppressions(client, params), do: HTTP.request(client, :post, "/suppressions/batch", params)

  def batch_delete_suppressions(client, params), do: HTTP.request(client, :delete, "/suppressions/batch", params)

  def oauth_metadata(client), do: HTTP.request(client, :get, "/.well-known/oauth-authorization-server")

  def oauth_register(client, params), do: HTTP.request(client, :post, "/oauth/register", params)

  def oauth_token(client, params), do: HTTP.request(client, :post, "/oauth/token", params)

  def oauth_revoke(client, params), do: HTTP.request(client, :post, "/oauth/revoke", params)

  def create_inbox_label(client, id, params), do: HTTP.request(client, :post, "/inboxes/#{enc(id)}/labels", params)

  def list_inbox_labels(client, id, query \\ %{}), do: HTTP.request(client, :get, "/inboxes/#{enc(id)}/labels" <> qs(query))

  def get_inbox_label(client, id, label_id), do: HTTP.request(client, :get, "/inboxes/#{enc(id)}/labels/#{enc(label_id)}")

  def update_inbox_label(client, id, label_id, params), do: HTTP.request(client, :patch, "/inboxes/#{enc(id)}/labels/#{enc(label_id)}", params)

  def delete_inbox_label(client, id, label_id), do: HTTP.request(client, :delete, "/inboxes/#{enc(id)}/labels/#{enc(label_id)}")

  def list_inbox_threads(client, id, query \\ %{}), do: HTTP.request(client, :get, "/inboxes/#{enc(id)}/threads" <> qs(query))

  def get_inbox_thread(client, id, thread_id), do: HTTP.request(client, :get, "/inboxes/#{enc(id)}/threads/#{enc(thread_id)}")

  def update_inbox_thread(client, id, thread_id, params), do: HTTP.request(client, :patch, "/inboxes/#{enc(id)}/threads/#{enc(thread_id)}", params)

  def delete_inbox_thread(client, id, thread_id), do: HTTP.request(client, :delete, "/inboxes/#{enc(id)}/threads/#{enc(thread_id)}")

  def list_inbox_thread_emails(client, id, thread_id, query \\ %{}), do: HTTP.request(client, :get, "/inboxes/#{enc(id)}/threads/#{enc(thread_id)}/emails" <> qs(query))

  def get_inbox_thread_email(client, id, thread_id, email_id), do: HTTP.request(client, :get, "/inboxes/#{enc(id)}/threads/#{enc(thread_id)}/emails/#{enc(email_id)}")

  def reply_inbox_email(client, id, thread_id, email_id, params), do: HTTP.request(client, :post, "/inboxes/#{enc(id)}/threads/#{enc(thread_id)}/emails/#{enc(email_id)}/reply", params)

  def forward_inbox_email(client, id, thread_id, email_id, params), do: HTTP.request(client, :post, "/inboxes/#{enc(id)}/threads/#{enc(thread_id)}/emails/#{enc(email_id)}/forward", params)

  def create_inbox_draft(client, id, params), do: HTTP.request(client, :post, "/inboxes/#{enc(id)}/drafts", params)

  def list_inbox_drafts(client, id, query \\ %{}), do: HTTP.request(client, :get, "/inboxes/#{enc(id)}/drafts" <> qs(query))

  def get_inbox_draft(client, id, draft_id), do: HTTP.request(client, :get, "/inboxes/#{enc(id)}/drafts/#{enc(draft_id)}")

  def update_inbox_draft(client, id, draft_id, params), do: HTTP.request(client, :patch, "/inboxes/#{enc(id)}/drafts/#{enc(draft_id)}", params)

  def delete_inbox_draft(client, id, draft_id), do: HTTP.request(client, :delete, "/inboxes/#{enc(id)}/drafts/#{enc(draft_id)}")

  def send_inbox_draft(client, id, draft_id), do: HTTP.request(client, :post, "/inboxes/#{enc(id)}/drafts/#{enc(draft_id)}/send")

  # ---- stats, downloads and broadcast recipients ----

  @doc "Sending statistics: `totals` and a `daily` series. Query: `days`."
  @spec stats(t(), map() | keyword()) :: result()
  def stats(client, query \\ %{}), do: HTTP.request(client, :get, "/stats" <> qs(query))

  @doc "The raw RFC 822 message of a received email, as a binary."
  @spec get_received_raw(t(), String.t()) :: {:ok, binary()} | {:error, Usend.Error.t()}
  def get_received_raw(client, id),
    do: HTTP.request(client, :get, "/inbound/emails/#{enc(id)}/raw", nil, [], raw: true)

  @doc "The bytes of a received email's attachment, as a binary."
  @spec get_received_attachment(t(), String.t(), String.t()) :: {:ok, binary()} | {:error, Usend.Error.t()}
  def get_received_attachment(client, id, attachment_id),
    do: HTTP.request(client, :get, "/inbound/emails/#{enc(id)}/attachments/#{enc(attachment_id)}", nil, [], raw: true)

  @doc """
  Recipients of a broadcast who had an event. `type` is required: one of sent, delivered, opened, clicked, bounced,
  complained, unsubscribed, suppressed. Rows are `%{"id", "contact_id", "email"}` plus `count` (opened, clicked),
  `bounce_type` (bounced) and `clicked_links` (clicked). Extra query: `limit`, `after`, `before`, `email`, `bounce_type`.
  """
  @spec list_broadcast_recipients(t(), String.t(), String.t(), map() | keyword()) :: result()
  def list_broadcast_recipients(client, id, type, query \\ %{}) do
    q = query |> Map.new() |> Map.put(:type, type)
    HTTP.request(client, :get, "/broadcasts/#{enc(id)}/recipients" <> qs(q))
  end

  # ---- helpers ----

  defp idem(opts) do
    case opts[:idempotency_key] do
      key when is_binary(key) and key != "" -> [{"Idempotency-Key", key}]
      _ -> []
    end
  end

  @doc false
  def enc(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  @doc false
  def qs(query) do
    pairs = for {k, v} <- query, not is_nil(v), do: "#{enc(k)}=#{enc(v)}"
    if pairs == [], do: "", else: "?" <> Enum.join(pairs, "&")
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(v), do: v
end
