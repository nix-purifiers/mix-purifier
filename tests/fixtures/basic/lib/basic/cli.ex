defmodule Basic.CLI do
  @moduledoc "The escript's entry point: prints the event JSON for each argument."

  def main(args), do: Enum.each(args, &IO.puts(Basic.event_json(&1)))
end
