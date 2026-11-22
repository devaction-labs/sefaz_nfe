defmodule SefazNfe.CTeMDFeWiringTest do
  @moduledoc """
  `SefazNfe.CTe.service_status/1` and `SefazNfe.MDFe.service_status/1` through
  the stub transport: envelope, endpoint, parse, telemetry. Never opens a socket.

  `async: false` because swapping `:sefaz_nfe, :soap` mutates application
  environment every other test reads.
  """

  use ExUnit.Case, async: false

  defmodule Stub do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(endpoint, body, _cert, opts) do
      send(:sefaz_nfe_cte_mdfe_wiring_test, {:posted, endpoint, body, opts})

      {:ok, reply(endpoint)}
    end

    defp reply(endpoint) do
      if endpoint =~ "mdfe" do
        wrap("MDFeStatusServico", "mdfe", "retConsStatServMDFe", "3.00", "")
      else
        wrap("CTeStatusServicoV4", "cte", "retConsStatServCTe", "4.00", "<cUF>29</cUF>")
      end
    end

    defp wrap(service, family, ret, version, extra) do
      ~s(<?xml version="1.0" encoding="utf-8"?>) <>
        ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
        ~s(<#{family}ResultMsg xmlns="http://www.portalfiscal.inf.br/#{family}/wsdl/#{service}">) <>
        ~s(<#{ret} versao="#{version}" xmlns="http://www.portalfiscal.inf.br/#{family}">) <>
        ~s(<tpAmb>2</tpAmb><verAplic>RS20260101</verAplic><cStat>107</cStat>) <>
        ~s(<xMotivo>Servico em Operacao</xMotivo>#{extra}) <>
        ~s(</#{ret}></#{family}ResultMsg></soap:Body></soap:Envelope>)
    end
  end

  @doc false
  def handle_event([_, :operation, _], _measurements, metadata, test),
    do: send(test, {:operation, metadata})

  def handle_event([_, :soap, _], _measurements, metadata, test),
    do: send(test, {:soap, metadata})

  setup do
    previous = Application.get_env(:sefaz_nfe, :soap)
    Process.register(self(), :sefaz_nfe_cte_mdfe_wiring_test)
    Application.put_env(:sefaz_nfe, :soap, Stub)

    on_exit(fn -> Application.put_env(:sefaz_nfe, :soap, previous) end)

    {:ok, base: %{cert: SefazNfe.Fixtures.cert(), uf: "BA", environment: :homologation}}
  end

  describe "SefazNfe.CTe.service_status/1" do
    test "BA goes to SVRS and the answer parses without the NF-e namespace", %{base: base} do
      assert {:ok, result} = SefazNfe.CTe.service_status(base)

      assert result.c_stat == 107
      assert result.status == :in_operation
      assert result.x_motivo == "Servico em Operacao"

      assert_receive {:posted, url, envelope, _opts}

      assert url ==
               "https://cte-homologacao.svrs.rs.gov.br/ws/CTeStatusServicoV4/CTeStatusServicoV4.asmx"

      assert envelope =~
               ~s(<cteDadosMsg xmlns="http://www.portalfiscal.inf.br/cte/wsdl/CTeStatusServicoV4">)

      assert envelope =~
               ~s(<consStatServCTe xmlns="http://www.portalfiscal.inf.br/cte" versao="4.00">)

      assert envelope =~ "<cUF>29</cUF>"
      assert envelope =~ "<tpAmb>2</tpAmb>"
      assert envelope =~ "<xServ>STATUS</xServ>"
    end

    test "PE goes to SVSP in production", %{base: base} do
      assert {:ok, _} = SefazNfe.CTe.service_status(%{base | uf: "PE", environment: :production})

      assert_receive {:posted, url, envelope, _opts}
      assert url == "https://nfe.fazenda.sp.gov.br/CTeWS/WS/CTeStatusServicoV4.asmx"
      assert envelope =~ "<cUF>26</cUF>"
      assert envelope =~ "<tpAmb>1</tpAmb>"
    end

    test "another model never reaches the transport", %{base: base} do
      assert {:error, {:unsupported_model, 58}} =
               SefazNfe.CTe.service_status(Map.put(base, :model, 58))

      refute_receive {:posted, _url, _envelope, _opts}
    end

    test "missing and invalid options are refused before the network", %{base: base} do
      assert {:error, {:missing_keys, [:uf]}} = SefazNfe.CTe.service_status(Map.delete(base, :uf))

      assert {:error, :invalid_environment} =
               SefazNfe.CTe.service_status(%{base | environment: :prod})

      assert {:error, {:unknown_endpoint, "XX", :cte_status_servico}} =
               SefazNfe.CTe.service_status(%{base | uf: "XX"})

      refute_receive {:posted, _url, _envelope, _opts}
    end
  end

  describe "SefazNfe.MDFe.service_status/1" do
    test "every UF goes to SVRS", %{base: base} do
      assert {:ok, result} = SefazNfe.MDFe.service_status(base)

      assert result.c_stat == 107
      assert result.status == :in_operation

      assert_receive {:posted, url, envelope, _opts}

      assert url ==
               "https://mdfe-homologacao.svrs.rs.gov.br/ws/MDFeStatusServico/MDFeStatusServico.asmx"

      assert envelope =~
               ~s(<mdfeDadosMsg xmlns="http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeStatusServico">)

      assert envelope =~
               ~s(<consStatServMDFe xmlns="http://www.portalfiscal.inf.br/mdfe" versao="3.00">)

      refute envelope =~ "<cUF>"
      assert envelope =~ "<xServ>STATUS</xServ>"
    end

    test "production URL", %{base: base} do
      assert {:ok, _} = SefazNfe.MDFe.service_status(%{base | uf: "SP", environment: :production})

      assert_receive {:posted, url, envelope, _opts}
      assert url == "https://mdfe.svrs.rs.gov.br/ws/MDFeStatusServico/MDFeStatusServico.asmx"
      assert envelope =~ "<tpAmb>1</tpAmb>"
    end

    test "missing options are refused before the network", %{base: base} do
      assert {:error, {:missing_keys, [:cert]}} =
               SefazNfe.MDFe.service_status(Map.delete(base, :cert))

      refute_receive {:posted, _url, _envelope, _opts}
    end
  end

  describe "telemetry" do
    setup do
      id = {__MODULE__, System.unique_integer()}

      :telemetry.attach_many(
        id,
        [[:sefaz_nfe, :operation, :stop], [:sefaz_nfe, :soap, :stop]],
        &__MODULE__.handle_event/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "cte_service_status carries model 57 and the UF", %{base: base} do
      assert {:ok, _} = SefazNfe.CTe.service_status(base)

      assert_receive {:operation,
                      %{
                        operation: :cte_service_status,
                        model: 57,
                        uf: "BA",
                        outcome: :ok,
                        c_stat: 107
                      }}
    end

    test "the SOAP span names the service and the model", %{base: base} do
      assert {:ok, _} = SefazNfe.CTe.service_status(Map.put(base, :model, 67))

      assert_receive {:soap, %{service: :cte_status_servico, model: 67, uf: "BA"}}
      assert_receive {:operation, %{operation: :cte_service_status, model: 67}}

      assert {:ok, _} = SefazNfe.MDFe.service_status(base)
      assert_receive {:soap, %{service: :mdfe_status_servico, model: 58}}
    end

    test "mdfe_service_status carries model 58", %{base: base} do
      assert {:ok, _} = SefazNfe.MDFe.service_status(base)

      assert_receive {:operation,
                      %{operation: :mdfe_service_status, model: 58, outcome: :ok, c_stat: 107}}
    end
  end

  test "NF-e service_status is unchanged by the shared transport", %{base: base} do
    assert {:ok, _} = SefazNfe.service_status(%{base | uf: "SP"})

    assert_receive {:posted, url, _envelope, _opts}
    assert url == "https://homologacao.nfe.fazenda.sp.gov.br/ws/nfestatusservico4.asmx"
  end
end
