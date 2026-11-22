defmodule SefazNfe.CircuitBreakerTest do
  @moduledoc """
  `async: false` throughout: the breaker is one shared ETS table, and the SOAP
  cases also swap the configured client.

  The breaker is keyed by the authorizer host, not by UF.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.CircuitBreaker

  @svrs "https://cte.svrs.rs.gov.br:443"
  @ba "https://nfe.sefaz.ba.gov.br:443"
  @an "https://www1.nfe.fazenda.gov.br:443"

  setup do
    CircuitBreaker.reset()
    on_exit(&CircuitBreaker.reset/0)
  end

  test "a fresh host is closed" do
    assert :ok = CircuitBreaker.check(@svrs)
  end

  test "it opens only at the threshold, not on the first failure" do
    for _below_threshold <- 1..4 do
      CircuitBreaker.record_failure(@svrs)
      assert :ok = CircuitBreaker.check(@svrs)
    end

    CircuitBreaker.record_failure(@svrs)
    assert {:error, {:circuit_open, @svrs}} = CircuitBreaker.check(@svrs)
  end

  test "one host going down leaves the others alone" do
    for _each <- 1..5, do: CircuitBreaker.record_failure(@svrs)

    assert {:error, {:circuit_open, @svrs}} = CircuitBreaker.check(@svrs)
    assert :ok = CircuitBreaker.check(@ba)
    assert :ok = CircuitBreaker.check(@an)
  end

  test "a success closes the breaker and forgets the count" do
    for _each <- 1..4, do: CircuitBreaker.record_failure(@svrs)
    CircuitBreaker.record_success(@svrs)

    for _each <- 1..4 do
      CircuitBreaker.record_failure(@svrs)
      assert :ok = CircuitBreaker.check(@svrs)
    end
  end

  test "the cooldown lets a trial call through" do
    Application.put_env(:sefaz_nfe, :circuit_cooldown, Duration.new!(microsecond: {1, 6}))
    on_exit(fn -> Application.delete_env(:sefaz_nfe, :circuit_cooldown) end)

    for _each <- 1..5, do: CircuitBreaker.record_failure(@svrs)

    assert :ok = CircuitBreaker.check(@svrs)
  end

  describe "through SOAP.isolated_call/4" do
    @svrs_url "https://cte.svrs.rs.gov.br/ws/CTeStatusServicoV4/CTeStatusServicoV4.asmx"
    @ba_url "https://nfe.sefaz.ba.gov.br/webservices/NFeStatusServico4/NFeStatusServico4.asmx"

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
                 SefazNfe.SOAP.isolated_call(@svrs_url, "<x/>", cert, uf: "SP")
      end

      assert {:error, {:circuit_open, @svrs}} =
               SefazNfe.SOAP.isolated_call(@svrs_url, "<x/>", cert, uf: "SP")
    end

    test "a SEFAZ rejection is an answer, not a transport failure", %{cert: cert} do
      Application.put_env(:sefaz_nfe, :soap, Rejecting)

      for _each <- 1..10 do
        assert {:ok, _body} = SefazNfe.SOAP.isolated_call(@svrs_url, "<x/>", cert, uf: "SP")
      end

      assert :ok = CircuitBreaker.check(@svrs)
    end

    test "every UF routed to SVRS shares its breaker, BA's own server is untouched",
         %{cert: cert} do
      Application.put_env(:sefaz_nfe, :soap, Unreachable)

      # Five different UFs, one failure each, all through SVRS.
      for uf <- ~w(BA AM PA PI SC) do
        assert {:error, :unreachable} =
                 SefazNfe.SOAP.isolated_call(@svrs_url, "<x/>", cert, uf: uf)
      end

      for uf <- ~w(BA MA GO) do
        assert {:error, {:circuit_open, @svrs}} =
                 SefazNfe.SOAP.isolated_call(@svrs_url, "<x/>", cert, uf: uf)
      end

      assert :ok = CircuitBreaker.check(@ba)

      assert {:error, :unreachable} =
               SefazNfe.SOAP.isolated_call(@ba_url, "<x/>", cert, uf: "BA")
    end

    test "the key ignores path and case but not the port", %{cert: cert} do
      Application.put_env(:sefaz_nfe, :soap, Unreachable)

      for path <- ~w(/a /b /c /d /e) do
        SefazNfe.SOAP.isolated_call("HTTPS://CTE.SVRS.RS.GOV.BR" <> path, "<x/>", cert, uf: "SP")
      end

      assert {:error, {:circuit_open, @svrs}} = CircuitBreaker.check(@svrs)
      assert :ok = CircuitBreaker.check("https://cte.svrs.rs.gov.br:8443")
    end
  end
end
