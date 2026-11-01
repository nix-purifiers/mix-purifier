defmodule Helper do
  @moduledoc """
  A path dependency with a Hex dependency of its own (telemetry), which the
  depending project's mix.lock locks.
  """

  def help do
    :telemetry.execute([:helper, :help], %{count: 1}, %{})
    "helped"
  end
end
