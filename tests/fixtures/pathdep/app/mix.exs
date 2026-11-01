defmodule PathdepApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :pathdep_app,
      version: "0.4.0",
      elixir: "~> 1.15",
      deps: [{:helper, path: "../helper"}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
