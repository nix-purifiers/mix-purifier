defmodule UpdateFixture do
  @moduledoc """
  Pins jason at 1.4.0, older than mix.exs allows, for the update check:
  `mix-purifier update jason` moves it forward.
  """

  def encode(value), do: Jason.encode!(value)
end
