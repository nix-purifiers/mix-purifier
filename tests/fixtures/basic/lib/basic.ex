defmodule Basic do
  @moduledoc """
  Encodes a telemetry event as JSON, so the fixture exercises an Elixir
  dependency (jason) and an Erlang dependency built with rebar3 (telemetry).
  """

  def event_json(name) do
    :telemetry.execute([:basic, :event], %{count: 1}, %{name: name})
    Jason.encode!(%{event: name})
  end
end
