defmodule UpdateFixture.MixProject do
  use Mix.Project

  def project do
    [
      app: :update_fixture,
      version: "0.7.0",
      elixir: "~> 1.15",
      deps: [{:jason, "~> 1.4"}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
