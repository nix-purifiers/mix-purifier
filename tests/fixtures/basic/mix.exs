defmodule Basic.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :basic,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"}
    ]
  end
end
