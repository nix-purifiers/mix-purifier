defmodule Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.3.0",
      start_permanent: Mix.env() == :prod,
      deps: [],
      releases: [
        umbrella: [applications: [greeter: :permanent, shouter: :permanent]]
      ]
    ]
  end
end
