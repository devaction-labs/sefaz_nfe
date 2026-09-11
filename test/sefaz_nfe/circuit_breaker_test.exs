defmodule SefazNfe.CircuitBreakerTest do
  @moduledoc """
  `async: false` throughout: the breaker is one shared ETS table, and the SOAP
  cases also swap the configured client.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.CircuitBreaker

  setup do
    CircuitBreaker.reset()
    on_exit(&CircuitBreaker.reset/0)
  end

  test "a fresh UF is closed" do
    assert :ok = CircuitBreaker.check("SP")
  end

  test "it opens only at the threshold, not on the first failure" do
    for _below_threshold <- 1..4 do
      CircuitBreaker.record_failure("SP")
      assert :ok = CircuitBreaker.check("SP")
    end

    CircuitBreaker.record_failure("SP")
    assert {:error, {:circuit_open, "SP"}} = CircuitBreaker.check("SP")
  end

  test "one UF going down leaves the others alone" do
    for _each <- 1..5, do: CircuitBreaker.record_failure("SP")

    assert {:error, {:circuit_open, "SP"}} = CircuitBreaker.check("SP")
    assert :ok = CircuitBreaker.check("MG")
    assert :ok = CircuitBreaker.check("AN")
  end

  test "a success closes the breaker and forgets the count" do
    for _each <- 1..4, do: CircuitBreaker.record_failure("SP")
    CircuitBreaker.record_success("SP")

    for _each <- 1..4 do
      CircuitBreaker.record_failure("SP")
      assert :ok = CircuitBreaker.check("SP")
    end
  end

  test "the cooldown lets a trial call through" do
    Application.put_env(:sefaz_nfe, :circuit_cooldown, Duration.new!(microsecond: {1, 6}))
    on_exit(fn -> Application.delete_env(:sefaz_nfe, :circuit_cooldown) end)

    for _each <- 1..5, do: CircuitBreaker.record_failure("SP")

    assert :ok = CircuitBreaker.check("SP")
  end

  describe "through SOAP.isolated_call/4" do
    setup do
      previous = Application.get_env(:sefaz_nfe, :soap)
      on_exit(fn -> Application.put_env(:sefaz_nfe, :soap, previous) end)
      %{cert: SefazNfe.Fixtures.cert()}
    end

    defmodule Unreachable do
      @moduledoc false
      @behaviour SefazNfe.SOAP
      @impl SefazNfe.SOAP
      def call(_endpoint, _body, _cert, _opts), do: {:error, :unreachable}
    end

    defmodule Rejecting do
      @moduledoc false
      @behaviour SefazNfe.SOAP
      @impl SefazNfe.SOAP
      def call(_endpoint, _body, _cert, _opts),
        do: {:ok, "<retEnviNFe><cStat>204</cStat></retEnviNFe>"}
    end

    test "transport failures trip the breaker and then fail fast", %{cert: cert} do
      Application.put_env(:sefaz_nfe, :soap, Unreachable)

      for _each <- 1..5 do
        assert {:error, :unreachable} =
                 SefazNfe.SOAP.isolated_call("https://x.test", "<x/>", cert, uf: "SP")
      end

      assert {:error, {:circuit_open, "SP"}} =
               SefazNfe.SOAP.isolated_call("https://x.test", "<x/>", cert, uf: "SP")
    end

    test "a SEFAZ rejection is an answer, not a transport failure", %{cert: cert} do
      Application.put_env(:sefaz_nfe, :soap, Rejecting)

      for _each <- 1..10 do
        assert {:ok, _body} =
                 SefazNfe.SOAP.isolated_call("https://x.test", "<x/>", cert, uf: "SP")
      end

      assert :ok = CircuitBreaker.check("SP")
    end

    test "a tripped UF does not block another", %{cert: cert} do
      Application.put_env(:sefaz_nfe, :soap, Unreachable)

      for _each <- 1..5,
          do: SefazNfe.SOAP.isolated_call("https://x.test", "<x/>", cert, uf: "SP")

      assert {:error, {:circuit_open, "SP"}} =
               SefazNfe.SOAP.isolated_call("https://x.test", "<x/>", cert, uf: "SP")

      assert {:error, :unreachable} =
               SefazNfe.SOAP.isolated_call("https://x.test", "<x/>", cert, uf: "MG")
    end
  end
end
