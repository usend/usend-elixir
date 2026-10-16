defmodule Usend.Error do
  @moduledoc """
  An error from the usend API: HTTP `status_code`, error `name` and `message` (the API's
  `{ statusCode, name, message }` shape). Network failures have `status_code: nil` and
  `name: "application_error"`; a bad webhook signature has `name: "invalid_webhook"`.
  """

  defexception [:status_code, :name, :message]

  @type t :: %__MODULE__{status_code: integer() | nil, name: String.t(), message: String.t()}

  @doc false
  def new(message, name \\ "application_error", status_code \\ nil) do
    %__MODULE__{message: message, name: name, status_code: status_code}
  end
end
