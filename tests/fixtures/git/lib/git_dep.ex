defmodule GitDep do
  @moduledoc """
  Adds two decimals and encodes the sum as JSON, so the fixture exercises a
  git dependency (decimal) beside a Hex package (jason).
  """

  def sum_json(a, b) do
    Jason.encode!(%{sum: Decimal.to_string(Decimal.add(a, b))})
  end
end
