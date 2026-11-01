defmodule GitDep.MixProject do
  use Mix.Project

  def project do
    [
      app: :git_dep,
      version: "0.2.0",
      elixir: "~> 1.15",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:decimal, git: "https://github.com/ericmj/decimal.git", tag: "v2.3.0", override: true},
      {:jason, "~> 1.4"}
    ]
  end
end
