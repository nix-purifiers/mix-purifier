defmodule Greeter do
  @moduledoc "Greets by name, as JSON, with a Hex dependency (jason)."

  def greet(name), do: Jason.encode!(%{greeting: "Hello, #{name}"})
end
