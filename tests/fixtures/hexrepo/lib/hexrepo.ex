defmodule Hexrepo do
  @moduledoc """
  Uses jason from a Hex repository other than hexpm. The repository named
  `mirror` serves hexpm's files from repo.hex.pm under another name, the way
  a self-hosted repository serves its own.
  """

  def encode(value), do: Jason.encode!(value)
end
