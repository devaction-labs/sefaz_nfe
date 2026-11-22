defmodule SefazNfe.CStatTest do
  use ExUnit.Case, async: true

  alias SefazNfe.CStat

  @classes %{
    authorized: [100, 102, 124, 135, 136, 150, 155],
    denied: [110, 301, 302, 303],
    cancelled: [101, 151],
    in_operation: [107],
    batch_received: [103],
    batch_processed: [104, 128],
    processing: [105],
    retryable: [108, 109, 656, 999],
    rejected: [1, 99, 106, 111, 199, 200, 204, 225, 300, 304, 452, 655, 657, 998]
  }

  for {status, codes} <- @classes, code <- codes do
    test "#{code} is #{status}" do
      assert CStat.classify(unquote(code)) == unquote(status)
    end
  end

  test "an unknown 1xx is rejected, not silently accepted" do
    assert CStat.classify(199) == :rejected
    assert CStat.classify(137) == :rejected
  end
end
