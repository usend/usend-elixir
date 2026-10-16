defmodule Usend.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/usend/usend-elixir"

  def project do
    [
      app: :usend,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: [],
      description: "The official Elixir SDK for usend, the email API for developers. No dependencies.",
      package: package(),
      source_url: @source_url,
      homepage_url: "https://usend.et/docs"
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :public_key, :ssl, :inets]]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Docs" => "https://usend.et/docs", "GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
