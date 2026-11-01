defmodule Helper.MixProject do
  use Mix.Project

  def project do
    [
      app: :helper,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: [{:telemetry, "~> 1.2"}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
