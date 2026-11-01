defmodule MixPurifierPublishFixture do
  @moduledoc """
  The package and documentation that the publish check builds with Nix and
  sends to a local Hex API.
  """

  @doc "Encodes a value as JSON."
  def encode(value), do: Jason.encode!(value)
end
