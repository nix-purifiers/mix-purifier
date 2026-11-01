defmodule Shouter do
  @moduledoc "Shouts a greeting from its sibling umbrella application."

  def shout(name), do: String.upcase(Greeter.greet(name))
end
