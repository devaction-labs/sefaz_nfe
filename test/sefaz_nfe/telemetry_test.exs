defmodule SefazNfe.TelemetryTest do
  @moduledoc """
  The operation span, the SOAP span's extra metadata and the breaker events.

  `async: false`: it swaps `:sefaz_nfe, :soap` and shares the breaker's ETS table.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.CircuitBreaker
  alias SefazNfe.NFeBuilder

  @cnpj "00000000000191"
  @sp_host "https://homologacao.nfe.fazenda.sp.gov.br:443"

  defmodule Stub do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(_endpoint, _body, _cert, _opts) do
      case Application.fetch_env!(:sefaz_nfe, :telemetry_test_reply) do
        {:error, _reason} = error -> error
        {:status, c_stat} -> {:ok, status(c_stat)}
        :authorized -> {:ok, authorized()}
      end
    end

    defp status(c_stat) do
      ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
        ~s(<retConsStatServ xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">) <>
        ~s(<tpAmb>2</tpAmb><cStat>#{c_stat}</cStat><xMotivo>x</xMotivo>) <>
        ~s(</retConsStatServ></soap:Body></soap:Envelope>)
    end

    defp authorized do
      ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
        ~s(<retEnviNFe xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">) <>
        ~s(<cStat>104</cStat><xMotivo>Lote processado</xMotivo>) <>
        ~s(<protNFe versao="4.00"><infProt><chNFe>35260100000000000191550010000000011000000017</chNFe>) <>
        ~s(<nProt>135260000000001</nProt><cStat>100</cStat>) <>
        ~s(<xMotivo>Autorizado o uso da NF-e</xMotivo></infProt></protNFe>) <>
        ~s(</retEnviNFe></soap:Body></soap:Envelope>)
    end
  end

  setup do
    previous = Application.get_env(:sefaz_nfe, :soap)
    Application.put_env(:sefaz_nfe, :soap, Stub)
    Application.put_env(:sefaz_nfe, :telemetry_test_reply, {:status, 107})
    CircuitBreaker.reset()

    handler = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach_many(handler, SefazNfe.Telemetry.events(), &__MODULE__.forward/4, test)

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.put_env(:sefaz_nfe, :soap, previous)
      Application.delete_env(:sefaz_nfe, :telemetry_test_reply)
      CircuitBreaker.reset()
    end)

    %{cert: SefazNfe.Fixtures.cert()}
  end

  def forward(event, measurements, metadata, test) do
    send(test, {:telemetry, event, measurements, metadata})
  end

  defp status_opts(cert, extra \\ %{}) do
    Map.merge(%{cert: cert, uf: "sp", environment: :homologation}, extra)
  end

  describe "operation span" do
    test "a stubbed authorize carries status and cStat", %{cert: cert} do
      Application.put_env(:sefaz_nfe, :telemetry_test_reply, :authorized)
      %{xml: xml, access_key: key} = NFeBuilder.build(tax_id: @cnpj)

      assert {:ok, _result} =
               SefazNfe.authorize(%{
                 xml: xml,
                 cert: cert,
                 uf: "SP",
                 environment: :homologation,
                 csc: "SECRET-CSC-VALUE",
                 csc_id: "000001"
               })

      assert_receive {:telemetry, [:sefaz_nfe, :operation, :start], %{system_time: _}, start}
      assert_receive {:telemetry, [:sefaz_nfe, :operation, :stop], %{duration: _}, stop}

      assert %{operation: :authorize, uf: "SP", environment: :homologation, model: 55} = start
      assert start.contingency == nil
      assert %{outcome: :ok, status: :authorized, c_stat: 100} = stop

      assert_receive {:telemetry, [:sefaz_nfe, :soap, :stop], _, soap}
      assert %{environment: :homologation, model: 55, contingency: nil, uf: "SP"} = soap

      for metadata <- [start, stop, soap] do
        flat = inspect(metadata, limit: :infinity, printable_limit: :infinity)

        for secret <- [key, @cnpj, "SECRET-CSC-VALUE", "<NFe", "<infNFe"] do
          refute flat =~ secret
        end

        refute Map.has_key?(metadata, :cert)
        refute Map.has_key?(metadata, :xml)
        refute Map.has_key?(metadata, :ch_nfe)
      end
    end

    test "tpEmis 6 is reported as the SVC-AN contingency", %{cert: cert} do
      Application.put_env(:sefaz_nfe, :telemetry_test_reply, :authorized)

      %{xml: xml} =
        NFeBuilder.build(
          tp_emis: 6,
          dh_cont: "2026-01-01T10:00:00-03:00",
          x_just: "SEFAZ fora do ar"
        )

      SefazNfe.authorize(%{xml: xml, cert: cert, uf: "SP", environment: :homologation})

      assert_receive {:telemetry, [:sefaz_nfe, :operation, :start], _, %{contingency: :svc_an}}
    end

    test "a SEFAZ rejection is an :ok outcome with a rejected status", %{cert: cert} do
      Application.put_env(:sefaz_nfe, :telemetry_test_reply, {:status, 539})

      assert {:ok, _} = SefazNfe.service_status(status_opts(cert))

      assert_receive {:telemetry, [:sefaz_nfe, :operation, :stop], _,
                      %{operation: :service_status, outcome: :ok, status: :rejected, c_stat: 539}}
    end

    test "a refusal before the network still emits start and stop", %{cert: cert} do
      assert {:error, :invalid_tax_id} =
               SefazNfe.cancel(%{
                 ch_nfe: String.duplicate("1", 20) <> "55" <> String.duplicate("1", 22),
                 n_prot: "1",
                 justification: String.duplicate("x", 20),
                 tax_id: "123",
                 cert: cert,
                 uf: "SP",
                 environment: :production
               })

      assert_receive {:telemetry, [:sefaz_nfe, :operation, :start], _,
                      %{operation: :cancel, uf: "SP", environment: :production, model: 55}}

      assert_receive {:telemetry, [:sefaz_nfe, :operation, :stop], _,
                      %{outcome: :invalid_tax_id, status: nil, c_stat: nil}}

      refute_received {:telemetry, [:sefaz_nfe, :soap, :start], _, _}
    end

    test "missing keys are an outcome too, with no UF to report" do
      assert {:error, {:missing_keys, _}} = SefazNfe.service_status(%{})

      assert_receive {:telemetry, [:sefaz_nfe, :operation, :stop], _,
                      %{operation: :service_status, uf: nil, outcome: :missing_keys}}
    end

    test "a transport error is its tag", %{cert: cert} do
      Application.put_env(:sefaz_nfe, :telemetry_test_reply, {:error, :unreachable})

      assert {:error, :unreachable} = SefazNfe.service_status(status_opts(cert))

      assert_receive {:telemetry, [:sefaz_nfe, :operation, :stop], _,
                      %{outcome: :unreachable, status: nil, c_stat: nil}}
    end

    test "Ambiente Nacional operations report AN", %{cert: cert} do
      assert {:error, :invalid_ch_nfe} =
               SefazNfe.manifest(:awareness, %{
                 ch_nfe: "1",
                 tax_id: @cnpj,
                 cert: cert,
                 environment: :homologation
               })

      assert_receive {:telemetry, [:sefaz_nfe, :operation, :start], _,
                      %{operation: :manifest, uf: "AN", model: 55}}
    end
  end

  describe "SOAP span" do
    test "carries environment, model and contingency", %{cert: cert} do
      assert {:ok, _} =
               SefazNfe.service_status(status_opts(cert, %{uf: "BA", model: 65}))

      assert_receive {:telemetry, [:sefaz_nfe, :soap, :start], _, start}
      assert %{environment: :homologation, model: 65, contingency: nil, service: _} = start
      assert_receive {:telemetry, [:sefaz_nfe, :soap, :stop], _, %{outcome: :ok}}
    end
  end

  describe "circuit breaker events" do
    test "open, rejected and close" do
      for _each <- 1..4, do: CircuitBreaker.record_failure(@sp_host)
      refute_received {:telemetry, [:sefaz_nfe, :circuit_breaker, :open], _, _}

      CircuitBreaker.record_failure(@sp_host)

      assert_receive {:telemetry, [:sefaz_nfe, :circuit_breaker, :open], %{count: 1},
                      %{host: @sp_host}}

      assert {:error, {:circuit_open, @sp_host}} = CircuitBreaker.check(@sp_host)

      assert_receive {:telemetry, [:sefaz_nfe, :circuit_breaker, :rejected], %{count: 1},
                      %{host: @sp_host}}

      CircuitBreaker.record_success(@sp_host)

      assert_receive {:telemetry, [:sefaz_nfe, :circuit_breaker, :close], %{count: 1},
                      %{host: @sp_host}}
    end

    test "a success on a breaker that never opened emits no close" do
      CircuitBreaker.record_failure(@sp_host)
      CircuitBreaker.record_success(@sp_host)

      refute_received {:telemetry, [:sefaz_nfe, :circuit_breaker, :close], _, _}
    end

    test "an open breaker refuses an operation with the :circuit_open outcome", %{cert: cert} do
      for _each <- 1..5, do: CircuitBreaker.record_failure(@sp_host)

      assert {:error, {:circuit_open, @sp_host}} =
               SefazNfe.service_status(status_opts(cert, %{uf: "SP"}))

      assert_receive {:telemetry, [:sefaz_nfe, :operation, :stop], _, %{outcome: :circuit_open}}

      assert_receive {:telemetry, [:sefaz_nfe, :circuit_breaker, :rejected], _, %{host: @sp_host}}
    end

    test "the SOAP span carries the host of the endpoint", %{cert: cert} do
      Application.put_env(:sefaz_nfe, :telemetry_test_reply, {:status, 107})

      assert {:ok, _status} = SefazNfe.service_status(status_opts(cert))

      assert_receive {:telemetry, [:sefaz_nfe, :soap, :start], _, %{host: @sp_host, uf: "SP"}}
      assert_receive {:telemetry, [:sefaz_nfe, :soap, :stop], _, %{host: @sp_host, uf: "SP"}}
    end
  end
end
