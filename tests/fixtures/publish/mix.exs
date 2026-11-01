defmodule MixPurifierPublishFixture.MixProject do
  use Mix.Project

  def project do
    [
      app: :mix_purifier_publish_fixture,
      version: "0.6.0",
      elixir: "~> 1.15",
      description: "A fixture that mix-purifier's checks publish to a local Hex API.",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/nix-purifiers/mix-purifier"}
      ],
      deps: [
        {:jason, "~> 1.4"},
        {:ex_doc, "~> 0.34", only: :dev, runtime: false}
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
