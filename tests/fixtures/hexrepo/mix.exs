defmodule Hexrepo.MixProject do
  use Mix.Project

  def project do
    [
      app: :hexrepo,
      version: "0.5.0",
      elixir: "~> 1.15",
      deps: [{:jason, "~> 1.4", repo: "mirror"}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
