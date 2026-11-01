defmodule Shouter.MixProject do
  use Mix.Project

  def project do
    [
      app: :shouter,
      version: "0.3.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      deps: [{:greeter, in_umbrella: true}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
