defmodule SefazNfeTest do
  use ExUnit.Case

  test "library module is defined" do
    assert {:module, SefazNfe} = Code.ensure_loaded(SefazNfe)
  end
end
