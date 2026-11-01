defmodule GitDepTest do
  use ExUnit.Case

  test "adds decimals from the git dependency and encodes the sum with jason" do
    assert GitDep.sum_json(Decimal.new("1.5"), Decimal.new("2.25")) == ~s({"sum":"3.75"})
  end
end
