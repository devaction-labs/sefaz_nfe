defmodule SefazNfe.CTeTransportTest do
  @moduledoc """
  `SefazNfe.CTe` through the stub transport: URL by UF and model, SOAP action,
  the compressed authorization body, the plain event bodies, QR code, procs,
  contingency routing and telemetry. Never opens a socket.

  `async: false` because swapping `:sefaz_nfe, :soap` mutates application
  environment every other test reads.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.CTe
  alias SefazNfe.CTe.Proc
  alias SefazNfe.CTeMap
  alias SefazNfe.CTeWire
  alias SefazNfe.Endpoints
  alias SefazNfe.Fixtures
  alias SefazNfe.SOAP.Envelope

  defmodule Stub do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(endpoint, body, _cert, opts) do
      body = IO.iodata_to_binary(body)
      send(:sefaz_nfe_cte_transport_test, {:posted, endpoint, body, opts})

      reply = Application.fetch_env!(:sefaz_nfe, :cte_test_reply)
      {:ok, reply.(body)}
    end
  end

  @doc false
  def handle_event([_, :operation, _], _measurements, metadata, test),
    do: send(test, {:operation, metadata})

  setup do
    previous = Application.get_env(:sefaz_nfe, :soap)
    Process.register(self(), :sefaz_nfe_cte_transport_test)
    Application.put_env(:sefaz_nfe, :soap, Stub)
    reply(fn body -> CTeWire.answer(CTeWire.sent_cte(body)) end)

    on_exit(fn ->
      Application.put_env(:sefaz_nfe, :soap, previous)
      Application.delete_env(:sefaz_nfe, :cte_test_reply)
    end)

    {:ok,
     base: %{cert: Fixtures.cert(), uf: "BA", environment: :homologation},
     event: %{
       cert: Fixtures.cert(),
       uf: "BA",
       environment: :homologation,
       tax_id: "00000000000191",
       ch_cte: CTeWire.key(57),
       timestamp: "2026-09-07T10:05:00-03:00"
     }}
  end

  defp reply(fun), do: Application.put_env(:sefaz_nfe, :cte_test_reply, fun)

  defp reply_event(opts \\ []) do
    reply(fn body -> body |> CTeWire.sent_plain() |> CTeWire.event_answer(opts) end)
  end

  defp action(opts) do
    {:ok, action} = Envelope.action(opts[:service])
    action
  end

  defp with_ide(map, changes), do: %{map | ide: Map.merge(map.ide, changes)}

  # -- authorize -------------------------------------------------------------

  describe "authorize/1, CT-e (model 57)" do
    test "builds, signs, adds the QR code, compresses and posts to the SVRS sync endpoint",
         %{base: base} do
      assert {:ok, result} = CTe.authorize(Map.put(base, :cte, CTeMap.cte()))

      assert_receive {:posted, url, envelope, opts}
      assert {:ok, ^url} = Endpoints.url("BA", :homologation, :cte_recepcao_sinc, 57)
      assert url =~ "cte-homologacao.svrs.rs.gov.br"

      assert opts[:service] == :cte_recepcao_sinc

      assert action(opts) ==
               "http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoSincV4/cteRecepcao"

      assert envelope =~
               ~s(<cteDadosMsg xmlns="http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoSincV4">)

      # The body is base64(gzip(CT-e)): no enviCTe, no XML declaration.
      sent = CTeWire.sent_cte(envelope)
      assert String.starts_with?(sent, ~s(<CTe xmlns="http://www.portalfiscal.inf.br/cte">))
      refute sent =~ "<?xml"
      refute sent =~ "enviCTe"

      assert result.signed_xml == sent
      assert sent =~ "<SignatureValue>"
    end

    test "the QR code is the on-line form, before the signature", %{base: base} do
      assert {:ok, result} = CTe.authorize(Map.put(base, :cte, CTeMap.cte()))
      key = result.ch_nfe

      qr = "https://dfe-portal.svrs.rs.gov.br/cte/qrCode?chCTe=#{key}&amp;tpAmb=2"
      assert result.signed_xml =~ "<infCTeSupl><qrCodCTe>#{qr}</qrCodCTe></infCTeSupl><Signature"
      refute result.signed_xml =~ "sign="

      assert {:ok, doc} = SefazNfe.XML.parse(result.signed_xml)
      assert SefazNfe.XML.text(doc, "qrCodCTe") =~ "tpAmb=2"
      assert SefazNfe.XML.text(doc, "qrCodCTe") =~ "&tpAmb=2"
    end

    test "SP uses its own portal for the QR code", %{base: base} do
      assert {:ok, result} =
               CTe.authorize(%{base | uf: "SP"} |> Map.put(:cte, CTeMap.cte()))

      assert result.signed_xml =~
               "https://homologacao.nfe.fazenda.sp.gov.br/CTeConsulta/qrCode?chCTe="
    end

    test "the answer becomes a result with the cteProc", %{base: base} do
      assert {:ok, result} = CTe.authorize(Map.put(base, :cte, CTeMap.cte()))

      assert result.status == :authorized
      assert result.c_stat == 100
      assert result.n_prot == "129260000000001"
      assert result.ch_nfe == CTeWire.built(:cte).access_key

      assert String.starts_with?(result.xml, ~s(<?xml version="1.0" encoding="UTF-8"?><cteProc))
      assert result.xml =~ ~s(<cteProc xmlns="http://www.portalfiscal.inf.br/cte" versao="4.00">)
      assert result.xml =~ "<protCTe"
      assert result.xml =~ result.signed_xml
      assert String.ends_with?(result.xml, "</cteProc>")
    end

    test "an :xml is signed and sent like a built map", %{base: base} do
      %{xml: xml} = CTeWire.built(:cte)

      assert {:ok, result} = CTe.authorize(Map.put(base, :xml, xml))
      assert_receive {:posted, _url, envelope, _opts}
      assert CTeWire.sent_cte(envelope) == result.signed_xml
      assert result.status == :authorized
    end

    test "an already signed :xml is not signed again", %{base: base} do
      %{xml: signed} = CTeWire.signed(:cte)

      assert {:ok, result} = CTe.authorize(Map.put(base, :xml, signed))
      assert result.signed_xml == signed
    end

    test "a rejection is a result without a cteProc", %{base: base} do
      reply(fn _body -> CTeWire.rejection(539, "Rejeicao: Duplicidade de CT-e") end)

      assert {:ok, result} = CTe.authorize(Map.put(base, :cte, CTeMap.cte()))
      assert result.status == :rejected
      assert result.c_stat == 539
      assert result.xml == nil
      assert result.signed_xml =~ "<SignatureValue>"
    end

    test "a rejection under protCTe keeps the key and is not archived", %{base: base} do
      reply(fn body ->
        body |> CTeWire.sent_cte() |> CTeWire.answer(c_stat: 539, x_motivo: "Duplicidade")
      end)

      assert {:ok, result} = CTe.authorize(Map.put(base, :cte, CTeMap.cte()))
      assert result.status == :rejected
      assert result.c_stat == 539
      assert String.length(result.ch_nfe) == 44
      assert result.xml == nil
    end

    test "678 is Consumo Indevido for CT-e: retryable", %{base: base} do
      reply(fn _body -> CTeWire.rejection(678, "Rejeicao: Consumo Indevido") end)

      assert {:ok, result} = CTe.authorize(Map.put(base, :cte, CTeMap.cte()))
      assert result.c_stat == 678
      assert result.status == :retryable
    end
  end

  describe "authorize/1, CT-e OS (model 67)" do
    test "goes to CTeRecepcaoOSV4 and the root CTeOS is what is signed", %{base: base} do
      reply(fn body -> body |> CTeWire.sent_cte() |> CTeWire.answer() end)

      assert {:ok, result} = CTe.authorize(Map.put(base, :cte, CTeMap.cte_os()))

      assert_receive {:posted, url, envelope, opts}
      assert {:ok, ^url} = Endpoints.url("BA", :homologation, :cte_recepcao_os, 67)

      assert opts[:service] == :cte_recepcao_os

      assert action(opts) ==
               "http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoOSV4/cteRecepcaoOS"

      assert envelope =~
               ~s(<cteDadosMsg xmlns="http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoOSV4">)

      sent = CTeWire.sent_cte(envelope)
      assert String.starts_with?(sent, "<CTeOS ")
      assert sent =~ ~r{</infCTeSupl><Signature .*</Signature></CTeOS>$}s

      assert result.status == :authorized
      assert result.xml =~ ~s(<cteOSProc xmlns="http://www.portalfiscal.inf.br/cte")
      assert String.ends_with?(result.xml, "</cteOSProc>")
    end

    test "the model comes from the XML, not from the map's builder alone", %{base: base} do
      %{xml: xml} = CTeWire.built(:cte_os)
      reply(fn body -> body |> CTeWire.sent_cte() |> CTeWire.answer() end)

      assert {:ok, _result} = CTe.authorize(Map.put(base, :xml, xml))
      assert_receive {:posted, _url, _envelope, opts}
      assert opts[:service] == :cte_recepcao_os
    end
  end

  describe "authorize/1, refusals before the network" do
    test "both :xml and :cte", %{base: base} do
      assert {:error, {:conflicting_keys, [:xml, :cte]}} =
               CTe.authorize(Map.merge(base, %{xml: "<CTe/>", cte: CTeMap.cte()}))

      refute_receive {:posted, _url, _envelope, _opts}
    end

    test "a map that does not build", %{base: base} do
      assert {:error, {:invalid_cte, [_ | _]}} = CTe.authorize(Map.put(base, :cte, %{ide: %{}}))
      refute_receive {:posted, _url, _envelope, _opts}
    end

    test "a model other than 57 and 67", %{base: base} do
      assert {:error, {:unsupported_model, 58}} =
               CTe.authorize(Map.put(base, :cte, %{ide: %{mod: 58}}))

      xml =
        ~s(<CTe xmlns="http://www.portalfiscal.inf.br/cte"><infCte><ide><mod>58</mod></ide></infCte></CTe>)

      assert {:error, {:unsupported_model, "58"}} = CTe.authorize(Map.put(base, :xml, xml))
      refute_receive {:posted, _url, _envelope, _opts}
    end

    test "tpAmb against the environment", %{base: base} do
      assert {:error, :environment_mismatch} =
               CTe.authorize(%{base | environment: :production} |> Map.put(:cte, CTeMap.cte()))

      refute_receive {:posted, _url, _envelope, _opts}
    end

    test "missing keys and an environment that is not one", %{base: base} do
      assert {:error, {:missing_keys, [:cert]}} =
               CTe.authorize(base |> Map.delete(:cert) |> Map.put(:cte, CTeMap.cte()))

      assert {:error, :invalid_environment} =
               CTe.authorize(%{base | environment: :prod} |> Map.put(:cte, CTeMap.cte()))

      assert {:error, {:missing_keys, [:xml]}} = CTe.authorize(base)
      refute_receive {:posted, _url, _envelope, _opts}
    end
  end

  describe "authorize/1, contingency (AD-005: the caller rebuilds with tpEmis)" do
    test "tpEmis 8 goes to SVC-SP for a UF that SVC-SP serves", %{base: base} do
      cte = with_ide(CTeMap.cte(), %{tp_emis: 8})

      assert {:ok, _result} = CTe.authorize(Map.put(base, :cte, cte))

      assert_receive {:posted, url, _envelope, _opts}

      assert {:ok, ^url} =
               Endpoints.contingency_url(:svc_sp, :homologation, :cte_recepcao_sinc, 57)

      refute url == elem(Endpoints.url("BA", :homologation, :cte_recepcao_sinc, 57), 1)
    end

    test "tpEmis 7 goes to SVC-RS for a UF that SVC-RS serves", %{base: base} do
      cte = with_ide(CTeMap.cte(), %{tp_emis: 7})

      assert {:ok, _result} = CTe.authorize(Map.put(%{base | uf: "SP"}, :cte, cte))

      assert_receive {:posted, url, _envelope, _opts}

      assert {:ok, ^url} =
               Endpoints.contingency_url(:svc_rs, :homologation, :cte_recepcao_sinc, 57)
    end

    test "CT-e OS takes the SVC too", %{base: base} do
      cte = with_ide(CTeMap.cte_os(), %{tp_emis: 8})
      reply(fn body -> body |> CTeWire.sent_cte() |> CTeWire.answer() end)

      assert {:ok, _result} = CTe.authorize(Map.put(base, :cte, cte))

      assert_receive {:posted, url, _envelope, opts}
      assert {:ok, ^url} = Endpoints.contingency_url(:svc_sp, :homologation, :cte_recepcao_os, 67)
      assert opts[:service] == :cte_recepcao_os
    end

    test "the wrong SVC for the UF is refused naming the right one", %{base: base} do
      assert {:error, {:wrong_contingency, "BA", :svc_sp}} =
               CTe.authorize(Map.put(base, :cte, with_ide(CTeMap.cte(), %{tp_emis: 7})))

      assert {:error, {:wrong_contingency, "SP", :svc_rs}} =
               CTe.authorize(
                 Map.put(%{base | uf: "SP"}, :cte, with_ide(CTeMap.cte(), %{tp_emis: 8}))
               )

      refute_receive {:posted, _url, _envelope, _opts}
    end

    test "3 (NFF), 4 (EPEC) and 5 (FS-DA) are not supported", %{base: base} do
      for tp_emis <- [3, 4, 5] do
        cte = with_ide(CTeMap.cte(), %{tp_emis: tp_emis})

        assert {:error, {:unsupported, {:tp_emis, tp}}} =
                 CTe.authorize(Map.put(base, :cte, cte))

        assert tp == to_string(tp_emis)
      end

      refute_receive {:posted, _url, _envelope, _opts}
    end

    test "nothing is inferred: tpEmis 1 stays on the origin authorizer", %{base: base} do
      assert {:ok, _result} = CTe.authorize(Map.put(base, :cte, CTeMap.cte()))
      assert_receive {:posted, url, _envelope, _opts}
      assert {:ok, ^url} = Endpoints.url("BA", :homologation, :cte_recepcao_sinc, 57)
    end
  end

  # -- consult and status ----------------------------------------------------

  describe "consult/1" do
    test "posts a plain consSitCTe to CTeConsultaV4", %{base: base} do
      key = CTeWire.key(57)
      reply(fn _body -> CTeWire.consult_answer(key) end)

      assert {:ok, result} = CTe.consult(Map.put(base, :ch_cte, key))

      assert_receive {:posted, url, envelope, opts}
      assert {:ok, ^url} = Endpoints.url("BA", :homologation, :cte_consulta, 57)
      assert opts[:service] == :cte_consulta
      assert action(opts) == "http://www.portalfiscal.inf.br/cte/wsdl/CTeConsultaV4/cteConsultaCT"

      assert envelope =~
               ~s(<cteDadosMsg xmlns="http://www.portalfiscal.inf.br/cte/wsdl/CTeConsultaV4">)

      assert CTeWire.sent_plain(envelope) ==
               ~s(<consSitCTe xmlns="http://www.portalfiscal.inf.br/cte" versao="4.00">) <>
                 ~s(<tpAmb>2</tpAmb><xServ>CONSULTAR</xServ><chCTe>#{key}</chCTe></consSitCTe>)

      assert result.status == :authorized
      assert result.ch_nfe == key
      assert result.n_prot == "129260000000001"
    end

    test "101 is cancelled and 110 denied", %{base: base} do
      key = CTeWire.key(57)

      for {c_stat, status} <- [{101, :cancelled}, {110, :denied}, {217, :rejected}] do
        reply(fn _body -> CTeWire.consult_answer(key, c_stat: c_stat) end)
        assert {:ok, result} = CTe.consult(Map.put(base, :ch_cte, key))
        assert result.status == status
      end
    end

    test "the model comes from the key: 67 is asked of the same CT-e authorizer", %{base: base} do
      key = CTeWire.key(67)
      reply(fn _body -> CTeWire.consult_answer(key) end)

      assert {:ok, _result} = CTe.consult(Map.put(base, :ch_cte, key))
      assert_receive {:posted, url, _envelope, _opts}
      assert {:ok, ^url} = Endpoints.url("BA", :homologation, :cte_consulta, 67)
    end

    test ":contingency asks the SVC, and only the one that serves the UF", %{base: base} do
      key = CTeWire.key(57)
      reply(fn _body -> CTeWire.consult_answer(key) end)

      assert {:ok, _result} =
               CTe.consult(base |> Map.put(:ch_cte, key) |> Map.put(:contingency, :svc_sp))

      assert_receive {:posted, url, _envelope, _opts}
      assert {:ok, ^url} = Endpoints.contingency_url(:svc_sp, :homologation, :cte_consulta, 57)

      assert {:error, {:wrong_contingency, "BA", :svc_sp}} =
               CTe.consult(base |> Map.put(:ch_cte, key) |> Map.put(:contingency, :svc_rs))

      assert {:error, {:invalid_contingency, :svc_an}} =
               CTe.consult(base |> Map.put(:ch_cte, key) |> Map.put(:contingency, :svc_an))

      refute_receive {:posted, _url, _envelope, _opts}
    end

    test "a bad key never reaches the network", %{base: base} do
      assert {:error, :invalid_ch_cte} = CTe.consult(Map.put(base, :ch_cte, "123"))

      assert {:error, {:unsupported_model, "55"}} =
               CTe.consult(
                 Map.put(
                   base,
                   :ch_cte,
                   String.replace(CTeWire.key(57), "57", "55", global: false)
                 )
               )

      assert {:error, {:missing_keys, [:ch_cte]}} = CTe.consult(base)
      refute_receive {:posted, _url, _envelope, _opts}
    end
  end

  describe "service_status/1" do
    test "keeps working and takes the contingency option", %{base: base} do
      reply(fn _body ->
        CTeWire.soap(
          "CTeStatusServicoV4",
          ~s(<retConsStatServCTe versao="4.00" xmlns="http://www.portalfiscal.inf.br/cte">) <>
            ~s(<tpAmb>2</tpAmb><verAplic>X</verAplic><cStat>107</cStat>) <>
            ~s(<xMotivo>Servico em Operacao</xMotivo><cUF>29</cUF></retConsStatServCTe>)
        )
      end)

      assert {:ok, %{status: :in_operation}} =
               CTe.service_status(Map.put(base, :contingency, :svc_sp))

      assert_receive {:posted, url, _envelope, _opts}

      assert {:ok, ^url} =
               Endpoints.contingency_url(:svc_sp, :homologation, :cte_status_servico, 57)
    end
  end

  # -- events ----------------------------------------------------------------

  describe "cancel/1" do
    test "posts the signed eventoCTe alone and plain to CTeRecepcaoEventoV4", %{event: event} do
      reply_event(c_stat: 135)

      opts =
        Map.merge(event, %{n_prot: "129260000000001", justification: "Erro de digitacao no valor"})

      assert {:ok, result} = CTe.cancel(opts)

      assert_receive {:posted, url, envelope, sent_opts}
      assert {:ok, ^url} = Endpoints.url("BA", :homologation, :cte_recepcao_evento, 57)
      assert sent_opts[:service] == :cte_recepcao_evento

      assert action(sent_opts) ==
               "http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoEventoV4/cteRecepcaoEvento"

      assert envelope =~
               ~s(<cteDadosMsg xmlns="http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoEventoV4">)

      sent = CTeWire.sent_plain(envelope)
      key = event.ch_cte

      assert String.starts_with?(
               sent,
               ~s(<eventoCTe xmlns="http://www.portalfiscal.inf.br/cte" versao="4.00">)
             )

      refute sent =~ "envEvento"
      refute sent =~ "idLote"
      refute sent =~ "<?xml"
      assert sent =~ ~s(<infEvento Id="ID110111#{key}001">)
      assert sent =~ "<cOrgao>29</cOrgao><tpAmb>2</tpAmb><CNPJ>00000000000191</CNPJ>"
      assert sent =~ "<chCTe>#{key}</chCTe><dhEvento>2026-09-07T10:05:00-03:00</dhEvento>"
      assert sent =~ "<tpEvento>110111</tpEvento><nSeqEvento>001</nSeqEvento>"
      assert sent =~ ~s(<detEvento versaoEvento="4.00"><evCancCTe>)

      assert sent =~
               "<evCancCTe><descEvento>Cancelamento</descEvento><nProt>129260000000001</nProt>" <>
                 "<xJust>Erro de digitacao no valor</xJust></evCancCTe>"

      assert sent =~ ~r{</infEvento><Signature .*</Signature></eventoCTe>$}s
      assert result.signed_xml == sent

      assert result.status == :authorized
      assert result.c_stat == 135
      assert result.ch_nfe == key

      assert result.xml =~
               ~s(<procEventoCTe xmlns="http://www.portalfiscal.inf.br/cte" versao="4.00">)

      assert result.xml =~ "<retEventoCTe"
    end

    test "a CPF author", %{event: event} do
      reply_event()

      opts =
        Map.merge(event, %{
          n_prot: "129260000000001",
          justification: "Erro de digitacao no valor",
          tax_id: "12345678909"
        })

      assert {:ok, _result} = CTe.cancel(opts)
      assert_receive {:posted, _url, envelope, _opts}
      assert CTeWire.sent_plain(envelope) =~ "<CPF>12345678909</CPF>"
    end

    test "the cancellation registers on the cteProc", %{base: base, event: event} do
      assert {:ok, authorized} = CTe.authorize(Map.put(base, :cte, CTeMap.cte()))
      key = authorized.ch_nfe
      reply_event(c_stat: 135, key: key)

      opts =
        Map.merge(event, %{
          ch_cte: key,
          n_prot: authorized.n_prot,
          justification: "Erro de digitacao no valor"
        })

      assert {:ok, cancelled} = CTe.cancel(opts)
      assert {:ok, registered} = Proc.cte_cancel_register(authorized.xml, cancelled.xml)
      assert registered =~ "<retEventoCTe"
      assert String.ends_with?(registered, "</cteProc>")
    end

    test "155 is accepted for a cancellation, 136 and 134 for any event", %{event: event} do
      opts =
        Map.merge(event, %{n_prot: "129260000000001", justification: "Erro de digitacao no valor"})

      for c_stat <- [134, 135, 136, 155] do
        reply_event(c_stat: c_stat)
        assert {:ok, result} = CTe.cancel(opts)
        assert result.status == :authorized
        assert result.xml =~ "<procEventoCTe"
      end
    end

    test "a rejected event has no procEventoCTe", %{event: event} do
      reply_event(c_stat: 494, x_motivo: "Rejeicao: Chave de Acesso inexistente")

      opts =
        Map.merge(event, %{n_prot: "129260000000001", justification: "Erro de digitacao no valor"})

      assert {:ok, result} = CTe.cancel(opts)
      assert result.status == :rejected
      assert result.xml == nil
      assert result.signed_xml =~ "<evCancCTe>"
    end

    test "refused before the network", %{event: event} do
      ok =
        Map.merge(event, %{n_prot: "129260000000001", justification: "Erro de digitacao no valor"})

      assert {:error, :justification_too_short} = CTe.cancel(%{ok | justification: "curto"})

      assert {:error, :justification_too_long} =
               CTe.cancel(%{ok | justification: String.duplicate("a", 256)})

      assert {:error, :invalid_n_prot} = CTe.cancel(%{ok | n_prot: "123"})
      assert {:error, :invalid_ch_cte} = CTe.cancel(%{ok | ch_cte: "1"})
      assert {:error, :invalid_tax_id} = CTe.cancel(%{ok | tax_id: "123"})
      assert {:error, :invalid_environment} = CTe.cancel(%{ok | environment: :prod})
      assert {:error, {:missing_keys, [:n_prot]}} = CTe.cancel(Map.delete(ok, :n_prot))
      refute_receive {:posted, _url, _envelope, _opts}
    end
  end

  describe "cce/1" do
    test "posts the structured corrections with the fixed xCondUso", %{event: event} do
      reply_event(c_stat: 135)

      corrections = [
        %{grupo_alterado: "ide", campo_alterado: "xObs", valor_alterado: "NOVO & TEXTO"},
        %{
          grupo_alterado: "infDoc",
          campo_alterado: "chave",
          valor_alterado: "123",
          nro_item_alterado: 2
        }
      ]

      assert {:ok, result} = CTe.cce(Map.merge(event, %{corrections: corrections, sequence: 2}))

      assert_receive {:posted, _url, envelope, _opts}
      sent = CTeWire.sent_plain(envelope)
      key = event.ch_cte

      assert sent =~ ~s(<infEvento Id="ID110110#{key}002">)
      assert sent =~ "<tpEvento>110110</tpEvento><nSeqEvento>002</nSeqEvento>"

      assert sent =~
               "<evCCeCTe><descEvento>Carta de Correcao</descEvento>" <>
                 "<infCorrecao><grupoAlterado>ide</grupoAlterado><campoAlterado>xObs</campoAlterado>" <>
                 "<valorAlterado>NOVO &amp; TEXTO</valorAlterado></infCorrecao>" <>
                 "<infCorrecao><grupoAlterado>infDoc</grupoAlterado><campoAlterado>chave</campoAlterado>" <>
                 "<valorAlterado>123</valorAlterado><nroItemAlterado>2</nroItemAlterado></infCorrecao>" <>
                 "<xCondUso>A Carta de Correcao e disciplinada pelo Art. 58-B do CONVENIO/SINIEF 06/89"

      assert result.status == :authorized
      assert result.xml =~ "<procEventoCTe"
    end

    test "invalid corrections never reach the network", %{event: event} do
      good = %{grupo_alterado: "ide", campo_alterado: "xObs", valor_alterado: "x"}

      assert {:error, {:invalid_corrections, :empty}} = CTe.cce(Map.put(event, :corrections, []))

      assert {:error, {:invalid_corrections, {1, {:missing, :valor_alterado}}}} =
               CTe.cce(Map.put(event, :corrections, [Map.delete(good, :valor_alterado)]))

      assert {:error, {:invalid_corrections, {2, {:too_long, :campo_alterado}}}} =
               CTe.cce(
                 Map.put(event, :corrections, [
                   good,
                   %{good | campo_alterado: String.duplicate("c", 21)}
                 ])
               )

      assert {:error, {:invalid_corrections, {1, {:invalid, :nro_item_alterado}}}} =
               CTe.cce(Map.put(event, :corrections, [Map.put(good, :nro_item_alterado, 100)]))

      assert {:error, {:invalid_corrections, {1, :not_a_map}}} =
               CTe.cce(Map.put(event, :corrections, ["ide"]))

      assert {:error, {:missing_keys, [:corrections]}} = CTe.cce(event)
      refute_receive {:posted, _url, _envelope, _opts}
    end

    test "a CT-e OS can be corrected too", %{event: event} do
      reply_event()
      correction = %{grupo_alterado: "ide", campo_alterado: "xObs", valor_alterado: "x"}

      assert {:ok, result} =
               CTe.cce(Map.merge(event, %{ch_cte: CTeWire.key(67), corrections: [correction]}))

      assert result.status == :authorized
    end
  end

  describe "delivery events (model 57)" do
    test "delivery_proof/1 sends 110180 with the computed hash", %{event: event} do
      reply_event()
      image = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3>>

      opts =
        Map.merge(event, %{
          n_prot: "129260000000001",
          dh_entrega: "2026-09-07T09:30:00-03:00",
          n_doc: "1234567",
          x_nome: "MARIA DA SILVA",
          image: image,
          latitude: -12.971598,
          longitude: -38.501,
          ch_nfes: [String.duplicate("3", 44)]
        })

      assert {:ok, result} = CTe.delivery_proof(opts)

      assert_receive {:posted, _url, envelope, _opts}
      sent = CTeWire.sent_plain(envelope)
      expected = :sha |> :crypto.hash(event.ch_cte <> Base.encode64(image)) |> Base.encode64()

      assert sent =~ ~s(<infEvento Id="ID110180#{event.ch_cte}001">)

      assert sent =~
               "<evCECTe><descEvento>Comprovante de Entrega do CT-e</descEvento>" <>
                 "<nProt>129260000000001</nProt><dhEntrega>2026-09-07T09:30:00-03:00</dhEntrega>" <>
                 "<nDoc>1234567</nDoc><xNome>MARIA DA SILVA</xNome>" <>
                 "<latitude>-12.971598</latitude><longitude>-38.501000</longitude>" <>
                 "<hashEntrega>#{expected}</hashEntrega>" <>
                 "<dhHashEntrega>2026-09-07T09:30:00-03:00</dhHashEntrega>" <>
                 "<infEntrega><chNFe>#{String.duplicate("3", 44)}</chNFe></infEntrega></evCECTe>"

      assert String.length(expected) == 28
      assert result.status == :authorized
    end

    test "cancel_delivery_proof/1 sends 110181", %{event: event} do
      reply_event()

      assert {:ok, _result} =
               CTe.cancel_delivery_proof(
                 Map.merge(event, %{n_prot: "129260000000001", n_prot_ce: "329260000000042"})
               )

      assert_receive {:posted, _url, envelope, _opts}

      assert CTeWire.sent_plain(envelope) =~
               "<evCancCECTe><descEvento>Cancelamento do Comprovante de Entrega do CT-e</descEvento>" <>
                 "<nProt>129260000000001</nProt><nProtCE>329260000000042</nProtCE></evCancCECTe>"
    end

    test "delivery_failure/1 sends 110190, the hash group only with an image", %{event: event} do
      reply_event()

      base =
        Map.merge(event, %{
          n_prot: "129260000000001",
          dh_tentativa_entrega: "2026-09-07T09:30:00-03:00",
          tp_motivo: 4,
          x_just_motivo: "Estabelecimento fechado no horario",
          n_tentativa: 1
        })

      assert {:ok, _result} = CTe.delivery_failure(base)
      assert_receive {:posted, _url, envelope, _opts}
      sent = CTeWire.sent_plain(envelope)

      assert sent =~
               "<evIECTe><descEvento>Insucesso na Entrega do CT-e</descEvento>" <>
                 "<nProt>129260000000001</nProt>" <>
                 "<dhTentativaEntrega>2026-09-07T09:30:00-03:00</dhTentativaEntrega>" <>
                 "<nTentativa>001</nTentativa><tpMotivo>4</tpMotivo>" <>
                 "<xJustMotivo>Estabelecimento fechado no horario</xJustMotivo></evIECTe>"

      assert {:ok, _result} = CTe.delivery_failure(Map.put(base, :image, "foto"))
      assert_receive {:posted, _url, envelope, _opts}
      sent = CTeWire.sent_plain(envelope)
      expected = :sha |> :crypto.hash(event.ch_cte <> Base.encode64("foto")) |> Base.encode64()
      assert sent =~ "<hashTentativaEntrega>#{expected}</hashTentativaEntrega>"
      assert sent =~ "<dhHashTentativaEntrega>2026-09-07T09:30:00-03:00</dhHashTentativaEntrega>"
    end

    test "cancel_delivery_failure/1 sends 110191", %{event: event} do
      reply_event()

      assert {:ok, _result} =
               CTe.cancel_delivery_failure(
                 Map.merge(event, %{n_prot: "129260000000001", n_prot_ie: "329260000000043"})
               )

      assert_receive {:posted, _url, envelope, _opts}

      assert CTeWire.sent_plain(envelope) =~
               "<evCancIECTe><descEvento>Cancelamento do Insucesso de Entrega do CT-e</descEvento>" <>
                 "<nProt>129260000000001</nProt><nProtIE>329260000000043</nProtIE></evCancIECTe>"
    end

    test "they are model 57 only", %{event: event} do
      os = %{event | ch_cte: CTeWire.key(67)}

      assert {:error, {:unsupported_for_model, 67}} =
               CTe.delivery_proof(
                 Map.merge(os, %{
                   n_prot: "129260000000001",
                   dh_entrega: "2026-09-07T09:30:00-03:00",
                   n_doc: "12",
                   x_nome: "AB",
                   image: "x"
                 })
               )

      assert {:error, {:unsupported_for_model, 67}} =
               CTe.cancel_delivery_proof(
                 Map.merge(os, %{n_prot: "129260000000001", n_prot_ce: "329260000000042"})
               )

      assert {:error, {:unsupported_for_model, 67}} =
               CTe.delivery_failure(
                 Map.merge(os, %{
                   n_prot: "129260000000001",
                   dh_tentativa_entrega: "2026-09-07T09:30:00-03:00",
                   tp_motivo: 1
                 })
               )

      assert {:error, {:unsupported_for_model, 67}} =
               CTe.cancel_delivery_failure(
                 Map.merge(os, %{n_prot: "129260000000001", n_prot_ie: "329260000000043"})
               )

      refute_receive {:posted, _url, _envelope, _opts}
    end

    test "motive and image are validated", %{event: event} do
      failure =
        Map.merge(event, %{
          n_prot: "129260000000001",
          dh_tentativa_entrega: "2026-09-07T09:30:00-03:00",
          tp_motivo: 4
        })

      assert {:error, :invalid_x_just_motivo} = CTe.delivery_failure(failure)

      assert {:error, :invalid_x_just_motivo} =
               CTe.delivery_failure(Map.put(failure, :x_just_motivo, "curto"))

      assert {:error, :invalid_tp_motivo} = CTe.delivery_failure(%{failure | tp_motivo: 5})

      proof =
        Map.merge(event, %{
          n_prot: "129260000000001",
          dh_entrega: "2026-09-07T09:30:00-03:00",
          n_doc: "12",
          x_nome: "AB",
          image: ""
        })

      assert {:error, :invalid_image} = CTe.delivery_proof(proof)

      assert {:error, :invalid_n_prot} =
               CTe.cancel_delivery_proof(Map.merge(event, %{n_prot: "1", n_prot_ce: "2"}))

      refute_receive {:posted, _url, _envelope, _opts}
    end
  end

  describe "events and contingency" do
    test "an event takes the SVC the caller names", %{event: event} do
      reply_event()

      opts =
        Map.merge(event, %{
          n_prot: "129260000000001",
          justification: "Erro de digitacao no valor",
          contingency: :svc_sp
        })

      assert {:ok, _result} = CTe.cancel(opts)
      assert_receive {:posted, url, _envelope, _opts}

      assert {:ok, ^url} =
               Endpoints.contingency_url(:svc_sp, :homologation, :cte_recepcao_evento, 57)

      assert {:error, {:wrong_contingency, "BA", :svc_sp}} =
               CTe.cancel(%{opts | contingency: :svc_rs})

      refute_receive {:posted, _url, _envelope, _opts}
    end
  end

  # -- telemetry -------------------------------------------------------------

  describe "telemetry" do
    setup do
      id = {__MODULE__, System.unique_integer()}
      :telemetry.attach(id, [:sefaz_nfe, :operation, :stop], &__MODULE__.handle_event/4, self())
      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "cte_authorize carries the model, the UF and the SVC", %{base: base} do
      assert {:ok, _} = CTe.authorize(Map.put(base, :cte, CTeMap.cte()))

      assert_receive {:operation,
                      %{
                        operation: :cte_authorize,
                        model: 57,
                        uf: "BA",
                        contingency: nil,
                        outcome: :ok,
                        status: :authorized,
                        c_stat: 100
                      }}

      assert {:ok, _} = CTe.authorize(Map.put(base, :cte, with_ide(CTeMap.cte(), %{tp_emis: 8})))
      assert_receive {:operation, %{operation: :cte_authorize, contingency: :svc_sp}}

      reply(fn body -> body |> CTeWire.sent_cte() |> CTeWire.answer() end)
      assert {:ok, _} = CTe.authorize(Map.put(base, :cte, CTeMap.cte_os()))
      assert_receive {:operation, %{operation: :cte_authorize, model: 67}}

      %{xml: xml} = CTeWire.built(:cte)
      assert {:ok, _} = CTe.authorize(Map.put(base, :xml, xml))
      assert_receive {:operation, %{operation: :cte_authorize, model: 57}}
    end

    test "every other operation has its own atom and the key's model", %{base: base, event: event} do
      key = CTeWire.key(57)
      reply(fn _body -> CTeWire.consult_answer(key) end)
      assert {:ok, _} = CTe.consult(Map.put(base, :ch_cte, key))
      assert_receive {:operation, %{operation: :cte_consult, model: 57, c_stat: 100}}

      reply_event()

      cancel =
        Map.merge(event, %{n_prot: "129260000000001", justification: "Erro de digitacao no valor"})

      assert {:ok, _} = CTe.cancel(cancel)
      assert_receive {:operation, %{operation: :cte_cancel, model: 57, c_stat: 135}}

      correction = %{grupo_alterado: "ide", campo_alterado: "xObs", valor_alterado: "x"}

      assert {:ok, _} =
               CTe.cce(Map.merge(event, %{ch_cte: CTeWire.key(67), corrections: [correction]}))

      assert_receive {:operation, %{operation: :cte_cce, model: 67}}

      assert {:ok, _} =
               CTe.cancel_delivery_proof(
                 Map.merge(event, %{n_prot: "129260000000001", n_prot_ce: "329260000000042"})
               )

      assert_receive {:operation, %{operation: :cte_cancel_delivery_proof, model: 57}}

      assert {:ok, _} =
               CTe.cancel_delivery_failure(
                 Map.merge(event, %{n_prot: "129260000000001", n_prot_ie: "329260000000043"})
               )

      assert_receive {:operation, %{operation: :cte_cancel_delivery_failure, model: 57}}

      proof =
        Map.merge(event, %{
          n_prot: "129260000000001",
          dh_entrega: "2026-09-07T09:30:00-03:00",
          n_doc: "12",
          x_nome: "AB",
          image: "x"
        })

      assert {:ok, _} = CTe.delivery_proof(proof)
      assert_receive {:operation, %{operation: :cte_delivery_proof, model: 57}}

      failure =
        Map.merge(event, %{
          n_prot: "129260000000001",
          dh_tentativa_entrega: "2026-09-07T09:30:00-03:00",
          tp_motivo: 1
        })

      assert {:ok, _} = CTe.delivery_failure(failure)
      assert_receive {:operation, %{operation: :cte_delivery_failure, model: 57}}
    end

    test "a refusal before the network is still a span with its outcome", %{event: event} do
      opts =
        Map.merge(event, %{n_prot: "129260000000001", justification: "Erro de digitacao no valor"})

      assert {:error, :invalid_ch_cte} = CTe.cancel(%{opts | ch_cte: "1"})

      assert_receive {:operation,
                      %{operation: :cte_cancel, model: nil, outcome: :invalid_ch_cte, c_stat: nil}}
    end
  end
end
