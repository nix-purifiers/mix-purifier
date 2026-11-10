defmodule Greeter.MixProject do
  use Mix.Project

  def project do
    [
      app: :greeter,
      version: "0.3.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      deps: [{:jason, "~> 1.4"}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
