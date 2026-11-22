defmodule SefazNfe.MDFeTransportTest do
  @moduledoc """
  `SefazNfe.MDFe`: authorize, consult, pending and the four events through a
  stub transport that records the URL and the body and answers with what the
  XSDs say SEFAZ answers (`retMDFe`, `retConsSitMDFe`, `retConsMDFeNaoEnc`,
  `retEventoMDFe`). Never opens a socket.

  `async: false` because `:sefaz_nfe, :soap` is global application environment.
  The XSD checks need `xmllint` and `SEFAZ_NFE_MDFE_PL_PATH` and are skipped
  without them.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.Builder
  alias SefazNfe.CStat
  alias SefazNfe.Endpoints
  alias SefazNfe.Fixtures
  alias SefazNfe.MDFe
  alias SefazNfe.MDFe.Pending
  alias SefazNfe.MDFe.QRCode
  alias SefazNfe.MDFeMap
  alias SefazNfe.Proc
  alias SefazNfe.Result
  alias SefazNfe.SOAP.Envelope
  alias SefazNfe.XML

  @mdfe_pl System.get_env("SEFAZ_NFE_MDFE_PL_PATH")
  @skip_pl if(
             System.find_executable("xmllint") != nil and is_binary(@mdfe_pl) and
               File.exists?(Path.join(@mdfe_pl || "", "mdfe_v3.00.xsd")),
             do: false,
             else: "SEFAZ_NFE_MDFE_PL_PATH or xmllint is not available"
           )

  @ns "http://www.portalfiscal.inf.br/mdfe"
  @n_prot "929260000000001"
  @tax_id "12345678000195"
  @homologation "https://mdfe-homologacao.svrs.rs.gov.br/ws"
  @qr "https://dfe-portal.svrs.rs.gov.br/mdfe/qrCode"

  defmodule Stub do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(endpoint, body, _cert, opts) do
      body = IO.iodata_to_binary(body)
      send(:sefaz_nfe_mdfe_transport_test, {:posted, endpoint, body, opts})
      reply = Application.fetch_env!(:sefaz_nfe, :mdfe_transport_reply)
      {:ok, reply.(endpoint, body)}
    end
  end

  setup do
    previous = Application.get_env(:sefaz_nfe, :soap)
    Process.register(self(), :sefaz_nfe_mdfe_transport_test)
    Application.put_env(:sefaz_nfe, :soap, Stub)
    reply(fn _endpoint, body -> default_reply(body) end)

    on_exit(fn ->
      Application.put_env(:sefaz_nfe, :soap, previous)
      Application.delete_env(:sefaz_nfe, :mdfe_transport_reply)
    end)

    {:ok, base: %{cert: Fixtures.cert(), uf: "BA", environment: :homologation}}
  end

  defp reply(fun), do: Application.put_env(:sefaz_nfe, :mdfe_transport_reply, fun)

  # Helpers ------------------------------------------------------------------

  defp build(overrides \\ %{}) do
    {:ok, built} =
      overrides |> Enum.reduce(MDFeMap.mdfe(), &put_override/2) |> Builder.build_mdfe()

    built
  end

  defp put_override({path, value}, map), do: put_in(map, path, value)

  # What is inside `mdfeDadosMsg`.
  defp message(body) do
    [_all, inner] = Regex.run(~r{<mdfeDadosMsg[^>]*>(.*)</mdfeDadosMsg>}s, body)
    inner
  end

  defp sent_mdfe(body), do: body |> message() |> Base.decode64!() |> :zlib.gunzip()

  defp soap(service, inner) do
    ~s(<?xml version="1.0" encoding="utf-8"?>) <>
      ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
      ~s(<#{service}Result xmlns="#{@ns}/wsdl/#{service}">#{inner}</#{service}Result>) <>
      ~s(</soap:Body></soap:Envelope>)
  end

  defp prot_mdfe(key, digest, c_stat, motivo) do
    ~s(<protMDFe versao="3.00"><infProt Id="ID#{@n_prot}"><tpAmb>2</tpAmb>) <>
      ~s(<verAplic>RS20260101</verAplic><chMDFe>#{key}</chMDFe>) <>
      ~s(<dhRecbto>2026-09-07T10:01:00-03:00</dhRecbto><nProt>#{@n_prot}</nProt>) <>
      ~s(<digVal>#{digest}</digVal><cStat>#{c_stat}</cStat><xMotivo>#{motivo}</xMotivo>) <>
      ~s(</infProt></protMDFe>)
  end

  defp ret_mdfe(key, digest) do
    ~s(<retMDFe versao="3.00" xmlns="#{@ns}"><tpAmb>2</tpAmb><cUF>29</cUF>) <>
      ~s(<verAplic>RS20260101</verAplic><cStat>100</cStat>) <>
      ~s(<xMotivo>Autorizado o uso do MDF-e</xMotivo>) <>
      prot_mdfe(key, digest, 100, "Autorizado o uso do MDF-e") <> ~s(</retMDFe>)
  end

  defp ret_event(key, tp_evento, c_stat, motivo) do
    ~s(<retEventoMDFe versao="3.00" xmlns="#{@ns}"><infEvento Id="ID#{@n_prot}">) <>
      ~s(<tpAmb>2</tpAmb><verAplic>RS20260101</verAplic><cOrgao>29</cOrgao>) <>
      ~s(<cStat>#{c_stat}</cStat><xMotivo>#{motivo}</xMotivo><chMDFe>#{key}</chMDFe>) <>
      ~s(<tpEvento>#{tp_evento}</tpEvento><xEvento>Evento</xEvento>) <>
      ~s(<nSeqEvento>1</nSeqEvento><dhRegEvento>2026-09-07T11:00:00-03:00</dhRegEvento>) <>
      ~s(<nProt>#{@n_prot}</nProt></infEvento></retEventoMDFe>)
  end

  # Answers an authorization from what was posted, a send or an event.
  defp default_reply(body) do
    case message(body) do
      "<eventoMDFe" <> _ = event ->
        event_reply(event, 135, "Evento registrado e vinculado a MDF-e")

      _gzip ->
        authorization_reply(sent_mdfe(body))
    end
  end

  defp authorization_reply(mdfe) do
    [_all, key] = Regex.run(~r/<infMDFe[^>]*Id="MDFe(\d{44})"/, mdfe)
    [_all, digest] = Regex.run(~r{<DigestValue>([^<]*)</DigestValue>}, mdfe)
    soap("MDFeRecepcaoSinc", ret_mdfe(key, digest))
  end

  defp event_reply(event, c_stat, motivo) do
    [_all, key] = Regex.run(~r/<chMDFe>(\d{44})<\/chMDFe>/, event)
    [_all, tp_evento] = Regex.run(~r/<tpEvento>(\d{6})<\/tpEvento>/, event)
    soap("MDFeRecepcaoEvento", ret_event(key, tp_evento, c_stat, motivo))
  end

  defp event_opts(%{ch_mdfe: key} = base, extra) do
    Map.merge(
      base,
      Map.merge(
        %{ch_mdfe: key, n_prot: @n_prot, tax_id: @tax_id, timestamp: "2026-09-07T11:00:00-03:00"},
        extra
      )
    )
  end

  # authorize/1 --------------------------------------------------------------

  describe "authorize/1" do
    test "sends base64(gzip(MDFe)) to MDFeRecepcaoSinc and returns the mdfeProc", %{base: base} do
      %{xml: xml, access_key: key} = build()

      assert {:ok, result} = MDFe.authorize(Map.put(base, :xml, xml))

      assert_receive {:posted, url, body, opts}
      assert url == "#{@homologation}/MDFeRecepcaoSinc/MDFeRecepcaoSinc.asmx"
      assert opts[:service] == :mdfe_recepcao_sinc

      assert Envelope.action(:mdfe_recepcao_sinc) ==
               {:ok, "#{@ns}/wsdl/MDFeRecepcaoSinc/mdfeRecepcao"}

      assert body =~ ~s(<mdfeDadosMsg xmlns="#{@ns}/wsdl/MDFeRecepcaoSinc">)

      sent = sent_mdfe(body)
      assert String.starts_with?(sent, ~s(<MDFe xmlns="#{@ns}">))
      refute sent =~ "<?xml"
      refute sent =~ "enviMDFe"
      assert sent =~ "<Signature"
      assert sent =~ ~s(<Reference URI="#MDFe#{key}">)
      assert result.signed_xml == sent

      assert result.status == :authorized
      assert result.c_stat == 100
      assert result.ch_nfe == key
      assert result.n_prot == @n_prot
      assert result.dh_recbto == "2026-09-07T10:01:00-03:00"

      assert String.starts_with?(result.xml, ~s(<?xml version="1.0" encoding="UTF-8"?><mdfeProc))
      assert result.xml =~ ~s(<mdfeProc xmlns="#{@ns}" versao="3.00">)
      assert result.xml =~ sent
      assert result.xml =~ "<protMDFe versao=\"3.00\"><infProt"
      assert String.ends_with?(result.xml, "</protMDFe></mdfeProc>")
      assert {:ok, _doc} = XML.parse(result.xml)
    end

    test "a map is built, signed and sent; a signed document is not signed again", %{base: base} do
      assert {:ok, from_map} = MDFe.authorize(Map.put(base, :mdfe, MDFeMap.mdfe()))
      assert_receive {:posted, _url, _body, _opts}

      assert {:ok, again} = MDFe.authorize(Map.put(base, :xml, from_map.signed_xml))
      assert_receive {:posted, _url, body, _opts}
      assert sent_mdfe(body) == from_map.signed_xml
      assert again.signed_xml == from_map.signed_xml
      assert length(Regex.scan(~r/<Signature[ >]/, again.signed_xml)) == 1
    end

    test "production goes to the production SVRS address", %{base: base} do
      %{xml: xml} = build(%{[:ide, :tp_amb] => 1})

      assert {:ok, _result} =
               MDFe.authorize(%{base | environment: :production, uf: "SP"} |> Map.put(:xml, xml))

      assert_receive {:posted, url, body, _opts}
      assert url == "https://mdfe.svrs.rs.gov.br/ws/MDFeRecepcaoSinc/MDFeRecepcaoSinc.asmx"
      assert sent_mdfe(body) =~ "&amp;tpAmb=1</qrCodMDFe>"
    end

    test "the QR code is spliced between infMDFe and Signature", %{base: base} do
      %{xml: xml, access_key: key} = build()
      assert {:ok, result} = MDFe.authorize(Map.put(base, :xml, xml))

      assert result.signed_xml =~
               "</infMDFe><infMDFeSupl><qrCodMDFe>#{@qr}?chMDFe=#{key}&amp;tpAmb=2" <>
                 "</qrCodMDFe></infMDFeSupl><Signature"

      assert {:ok, doc} = XML.parse(result.signed_xml)
      assert XML.text(doc, "qrCodMDFe") == "#{@qr}?chMDFe=#{key}&tpAmb=2"
    end

    test "an infMDFeSupl the host wrote is kept", %{base: base} do
      %{xml: xml} = build()
      supl = "<infMDFeSupl><qrCodMDFe>mine</qrCodMDFe></infMDFeSupl>"
      xml = String.replace(xml, "</infMDFe>", "</infMDFe>" <> supl)

      assert {:ok, result} = MDFe.authorize(Map.put(base, :xml, xml))
      assert result.signed_xml =~ "</infMDFe>" <> supl <> "<Signature"
    end

    test "contingency (tpEmis 2) signs the key into the QR code", %{base: base} do
      %{xml: xml, access_key: key} = build(%{[:ide, :tp_emis] => 2})
      assert {:ok, result} = MDFe.authorize(Map.put(base, :xml, xml))

      assert {:ok, doc} = XML.parse(result.signed_xml)
      qr = XML.text(doc, "qrCodMDFe")
      prefix = "#{@qr}?chMDFe=#{key}&tpAmb=2&sign="
      assert String.starts_with?(qr, prefix)

      signature = qr |> String.replace_prefix(prefix, "") |> Base.decode64!()
      assert verifies?(key, signature)
      refute verifies?(key <> "0", signature)
    end

    test "any other tpEmis never reaches the network", %{base: base} do
      %{xml: xml} = build()
      three = String.replace(xml, "<tpEmis>1</tpEmis>", "<tpEmis>3</tpEmis>")

      assert {:error, {:unsupported, {:tp_emis, "3"}}} =
               MDFe.authorize(Map.put(base, :xml, three))

      refute_receive {:posted, _url, _body, _opts}
    end

    test "a rejection is a result: no mdfeProc, the signed bytes are still returned", %{
      base: base
    } do
      reply(fn _endpoint, _body ->
        soap(
          "MDFeRecepcaoSinc",
          ~s(<retMDFe versao="3.00" xmlns="#{@ns}"><tpAmb>2</tpAmb><cUF>29</cUF>) <>
            ~s(<verAplic>RS20260101</verAplic><cStat>539</cStat>) <>
            ~s(<xMotivo>Rejeicao: Duplicidade de MDF-e</xMotivo></retMDFe>)
        )
      end)

      assert {:ok, result} = MDFe.authorize(Map.put(base, :mdfe, MDFeMap.mdfe()))
      assert result.status == :rejected
      assert result.c_stat == 539
      assert result.x_motivo == "Rejeicao: Duplicidade de MDF-e"
      assert result.xml == nil
      assert result.signed_xml =~ "<Signature"
    end

    test "a rejection inside protMDFe is read from infProt", %{base: base} do
      reply(fn _endpoint, body ->
        mdfe = sent_mdfe(body)
        [_all, key] = Regex.run(~r/Id="MDFe(\d{44})"/, mdfe)

        soap(
          "MDFeRecepcaoSinc",
          ~s(<retMDFe versao="3.00" xmlns="#{@ns}"><tpAmb>2</tpAmb><cUF>29</cUF>) <>
            ~s(<verAplic>RS20260101</verAplic><cStat>104</cStat><xMotivo>Lote processado</xMotivo>) <>
            prot_mdfe(key, "x", 204, "Rejeicao: Duplicidade") <> ~s(</retMDFe>)
        )
      end)

      assert {:ok, result} = MDFe.authorize(Map.put(base, :mdfe, MDFeMap.mdfe()))
      assert {result.status, result.c_stat, result.xml} == {:rejected, 204, nil}
    end

    test "refused before the network", %{base: base} do
      %{xml: xml} = build()
      production = %{base | environment: :production}

      assert {:error, :environment_mismatch} = MDFe.authorize(Map.put(production, :xml, xml))

      assert {:error, {:conflicting_keys, [:xml, :mdfe]}} =
               MDFe.authorize(Map.merge(base, %{xml: xml, mdfe: %{}}))

      assert {:error, {:invalid_mdfe, [_ | _]}} = MDFe.authorize(Map.put(base, :mdfe, %{}))
      assert {:error, {:missing_keys, [:xml]}} = MDFe.authorize(base)

      assert {:error, :invalid_environment} =
               MDFe.authorize(Map.merge(base, %{environment: :prod, xml: xml}))

      nfe = String.replace(xml, "<mod>58</mod>", "<mod>57</mod>")
      assert {:error, {:unsupported_model, "57"}} = MDFe.authorize(Map.put(base, :xml, nfe))

      refute_receive {:posted, _url, _body, _opts}
    end

    test "a transport failure is an error", %{base: base} do
      Application.put_env(:sefaz_nfe, :soap, __MODULE__.Down)

      assert {:error, :timeout} = MDFe.authorize(Map.put(base, :mdfe, MDFeMap.mdfe()))
    end
  end

  defmodule Down do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(_endpoint, _body, _cert, _opts), do: {:error, :timeout}
  end

  defp verifies?(text, signature) do
    {:OTPCertificate, tbs, _algorithm, _signature} =
      :public_key.pkix_decode_cert(Fixtures.cert().der, :otp)

    public_key = tbs |> elem(7) |> elem(2)

    :public_key.verify(text, :sha, signature, public_key)
  end

  # consult/1 ----------------------------------------------------------------

  describe "consult/1" do
    setup do
      %{access_key: key} = build()
      {:ok, key: key}
    end

    defp ret_cons_sit(key, c_stat, motivo, extra) do
      soap(
        "MDFeConsulta",
        ~s(<retConsSitMDFe versao="3.00" xmlns="#{@ns}"><tpAmb>2</tpAmb>) <>
          ~s(<verAplic>RS20260101</verAplic><cStat>#{c_stat}</cStat><xMotivo>#{motivo}</xMotivo>) <>
          ~s(<cUF>29</cUF>) <>
          prot_mdfe(key, "dig", 100, "Autorizado o uso do MDF-e") <>
          extra <>
          ~s(</retConsSitMDFe>)
      )
    end

    test "consSitMDFe 3.00 to MDFeConsulta", %{base: base, key: key} do
      reply(fn _endpoint, _body -> ret_cons_sit(key, 100, "Autorizado o uso do MDF-e", "") end)

      assert {:ok, result} = MDFe.consult(Map.put(base, :ch_mdfe, key))

      assert_receive {:posted, url, body, opts}
      assert url == "#{@homologation}/MDFeConsulta/MDFeConsulta.asmx"
      assert opts[:service] == :mdfe_consulta
      assert body =~ ~s(<mdfeDadosMsg xmlns="#{@ns}/wsdl/MDFeConsulta">)

      assert message(body) ==
               ~s(<consSitMDFe xmlns="#{@ns}" versao="3.00"><tpAmb>2</tpAmb>) <>
                 ~s(<xServ>CONSULTAR</xServ><chMDFe>#{key}</chMDFe></consSitMDFe>)

      assert {result.status, result.c_stat, result.ch_nfe, result.n_prot} ==
               {:authorized, 100, key, @n_prot}
    end

    test "the situation is the top cStat, not the original protocol's", %{base: base, key: key} do
      for {c_stat, status} <- [{101, :cancelled}, {132, :closed}] do
        reply(fn _endpoint, _body -> ret_cons_sit(key, c_stat, "Situacao", "") end)

        assert {:ok, result} = MDFe.consult(Map.put(base, :ch_mdfe, key))
        assert result.c_stat == c_stat
        assert result.status == status
        assert result.n_prot == @n_prot
      end
    end

    test "217 (not found) is a rejection result", %{base: base, key: key} do
      reply(fn _endpoint, _body ->
        soap(
          "MDFeConsulta",
          ~s(<retConsSitMDFe versao="3.00" xmlns="#{@ns}"><tpAmb>2</tpAmb>) <>
            ~s(<verAplic>RS20260101</verAplic><cStat>217</cStat>) <>
            ~s(<xMotivo>Rejeicao: MDF-e nao consta na base de dados da SEFAZ</xMotivo>) <>
            ~s(<cUF>29</cUF></retConsSitMDFe>)
        )
      end)

      assert {:ok, %Result{status: :rejected, c_stat: 217, n_prot: nil}} =
               MDFe.consult(Map.put(base, :ch_mdfe, key))
    end

    test "a key that is not an MDF-e key never reaches the network", %{base: base, key: key} do
      nfe_key = String.replace(key, ~r/^(\d{20})58/, "\\155")

      assert {:error, :invalid_ch_mdfe} = MDFe.consult(Map.put(base, :ch_mdfe, nfe_key))
      assert {:error, :invalid_ch_mdfe} = MDFe.consult(Map.put(base, :ch_mdfe, "123"))
      assert {:error, {:missing_keys, [:ch_mdfe]}} = MDFe.consult(base)
      refute_receive {:posted, _url, _body, _opts}
    end
  end

  # pending/1 ----------------------------------------------------------------

  describe "pending/1" do
    defp ret_pending(c_stat, motivo, documents) do
      items =
        Enum.map_join(documents, fn {key, prot} ->
          ~s(<infMDFe><chMDFe>#{key}</chMDFe><nProt>#{prot}</nProt></infMDFe>)
        end)

      soap(
        "MDFeConsNaoEnc",
        ~s(<retConsMDFeNaoEnc versao="3.00" xmlns="#{@ns}"><tpAmb>2</tpAmb>) <>
          ~s(<verAplic>RS20260101</verAplic><cStat>#{c_stat}</cStat>) <>
          ~s(<xMotivo>#{motivo}</xMotivo><cUF>29</cUF>#{items}</retConsMDFeNaoEnc>)
      )
    end

    test "the request, for a CNPJ", %{base: base} do
      reply(fn _endpoint, _body -> ret_pending(112, "Nenhum documento localizado", []) end)

      assert {:ok, _pending} = MDFe.pending(Map.put(base, :tax_id, @tax_id))

      assert_receive {:posted, url, body, opts}
      assert url == "#{@homologation}/MDFeConsNaoEnc/MDFeConsNaoEnc.asmx"
      assert opts[:service] == :mdfe_consulta_nao_enc
      assert body =~ ~s(<mdfeDadosMsg xmlns="#{@ns}/wsdl/MDFeConsNaoEnc">)

      assert message(body) ==
               ~s(<consMDFeNaoEnc xmlns="#{@ns}" versao="3.00"><tpAmb>2</tpAmb>) <>
                 ~s(<xServ>CONSULTAR NÃO ENCERRADOS</xServ><CNPJ>#{@tax_id}</CNPJ></consMDFeNaoEnc>)
    end

    test "a CPF is sent as CPF", %{base: base} do
      reply(fn _endpoint, _body -> ret_pending(112, "Nenhum documento localizado", []) end)
      assert {:ok, _pending} = MDFe.pending(Map.put(base, :tax_id, "12345678909"))
      assert_receive {:posted, _url, body, _opts}
      assert message(body) =~ "<CPF>12345678909</CPF></consMDFeNaoEnc>"
    end

    test "no documents", %{base: base} do
      reply(fn _endpoint, _body -> ret_pending(112, "Nenhum documento localizado", []) end)

      assert {:ok, %Pending{c_stat: 112, x_motivo: "Nenhum documento localizado", documents: []}} =
               MDFe.pending(Map.put(base, :tax_id, @tax_id))
    end

    test "one document", %{base: base} do
      %{access_key: key} = build()
      reply(fn _endpoint, _body -> ret_pending(111, "Consulta realizada", [{key, @n_prot}]) end)

      assert {:ok, %Pending{c_stat: 111, documents: [%{ch_mdfe: ^key, n_prot: @n_prot}]}} =
               MDFe.pending(Map.put(base, :tax_id, @tax_id))
    end

    test "several documents, in order", %{base: base} do
      keys = for n <- 1..3, do: String.replace(build().access_key, ~r/.$/, to_string(n))
      pairs = Enum.map(keys, &{&1, @n_prot})
      reply(fn _endpoint, _body -> ret_pending(111, "Consulta realizada", pairs) end)

      assert {:ok, %Pending{documents: documents}} = MDFe.pending(Map.put(base, :tax_id, @tax_id))
      assert Enum.map(documents, & &1.ch_mdfe) == keys
      assert Enum.all?(documents, &(&1.n_prot == @n_prot))
    end

    test "a rejection is a result with no documents", %{base: base} do
      reply(fn _endpoint, _body -> ret_pending(999, "Erro nao catalogado", []) end)

      assert {:ok, %Pending{c_stat: 999, documents: []}} =
               MDFe.pending(Map.put(base, :tax_id, @tax_id))
    end

    test "a SOAP fault is an error", %{base: base} do
      reply(fn _endpoint, _body ->
        ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
          ~s(<soap:Fault><soap:Reason><soap:Text>boom</soap:Text></soap:Reason></soap:Fault>) <>
          ~s(</soap:Body></soap:Envelope>)
      end)

      assert {:error, {:soap_fault, "boom"}} = MDFe.pending(Map.put(base, :tax_id, @tax_id))
    end

    test "refused before the network", %{base: base} do
      assert {:error, :invalid_tax_id} = MDFe.pending(Map.put(base, :tax_id, "123"))
      assert {:error, {:missing_keys, [:tax_id]}} = MDFe.pending(base)
      refute_receive {:posted, _url, _body, _opts}
    end
  end

  # events -------------------------------------------------------------------

  describe "events" do
    setup %{base: base} do
      %{access_key: key} = build()
      {:ok, base: Map.put(base, :ch_mdfe, key), key: key}
    end

    test "cancel (110111), plain XML signed on infEvento", %{base: base, key: key} do
      opts = event_opts(base, %{justification: "Erro na emissao do manifesto"})
      assert {:ok, result} = MDFe.cancel(opts)

      assert_receive {:posted, url, body, opts}
      assert url == "#{@homologation}/MDFeRecepcaoEvento/MDFeRecepcaoEvento.asmx"
      assert opts[:service] == :mdfe_recepcao_evento
      assert body =~ ~s(<mdfeDadosMsg xmlns="#{@ns}/wsdl/MDFeRecepcaoEvento"><eventoMDFe)

      sent = message(body)
      assert result.signed_xml == sent
      refute sent =~ "<?xml"
      refute sent =~ "envEvento"

      assert sent =~ ~s(<eventoMDFe xmlns="#{@ns}" versao="3.00">)
      assert sent =~ ~s(<infEvento Id="ID110111#{key}01">)
      assert sent =~ "<cOrgao>29</cOrgao><tpAmb>2</tpAmb><CNPJ>#{@tax_id}</CNPJ>"
      assert sent =~ "<chMDFe>#{key}</chMDFe><dhEvento>2026-09-07T11:00:00-03:00</dhEvento>"
      assert sent =~ "<tpEvento>110111</tpEvento><nSeqEvento>1</nSeqEvento>"

      assert sent =~
               ~s(<detEvento versaoEvento="3.00"><evCancMDFe><descEvento>Cancelamento</descEvento>) <>
                 ~s(<nProt>#{@n_prot}</nProt><xJust>Erro na emissao do manifesto</xJust></evCancMDFe></detEvento>)

      assert sent =~ ~s(<Reference URI="#ID110111#{key}01">)
      assert sent =~ "</infEvento><Signature"

      assert {result.status, result.c_stat, result.ch_nfe} == {:authorized, 135, key}
      assert result.xml =~ ~s(<procEventoMDFe xmlns="#{@ns}" versao="3.00"><eventoMDFe)
      assert result.xml =~ sent
      assert String.ends_with?(result.xml, "</retEventoMDFe></procEventoMDFe>")
    end

    test "close (110112): encerramento", %{base: base, key: key} do
      opts = event_opts(base, %{c_uf: "35", c_mun: "3550308", dt_enc: ~D[2026-09-09]})
      assert {:ok, result} = MDFe.close(opts)

      assert_receive {:posted, _url, body, _opts}
      sent = message(body)
      assert sent =~ ~s(<infEvento Id="ID110112#{key}01">)

      assert sent =~
               ~s(<detEvento versaoEvento="3.00"><evEncMDFe><descEvento>Encerramento</descEvento>) <>
                 ~s(<nProt>#{@n_prot}</nProt><dtEnc>2026-09-09</dtEnc><cUF>35</cUF>) <>
                 ~s(<cMun>3550308</cMun></evEncMDFe></detEvento>)

      assert result.status == :authorized
      assert result.xml =~ "<procEventoMDFe"
    end

    test "close takes IBGE codes as integers, as the builder does", %{base: base} do
      opts = event_opts(base, %{c_uf: 35, c_mun: 3_550_308, dt_enc: ~D[2026-09-09]})
      assert {:ok, %{status: :authorized}} = MDFe.close(opts)

      assert_receive {:posted, _url, body, _opts}
      assert message(body) =~ ~s(<cUF>35</cUF><cMun>3550308</cMun>)
    end

    test "close takes a date string and the third party flag", %{base: base} do
      opts =
        event_opts(base, %{
          c_uf: "35",
          c_mun: "3550308",
          dt_enc: "2026-09-09",
          ind_enc_por_terceiro: true
        })

      assert {:ok, _result} = MDFe.close(opts)
      assert_receive {:posted, _url, body, _opts}

      assert message(body) =~
               "<dtEnc>2026-09-09</dtEnc><cUF>35</cUF><cMun>3550308</cMun>" <>
                 "<indEncPorTerceiro>1</indEncPorTerceiro></evEncMDFe>"
    end

    test "include_driver (110114) with a sequence, an author CPF and no protocol", %{
      base: base,
      key: key
    } do
      opts =
        event_opts(base, %{
          x_nome: "JOSE & FILHOS",
          cpf: "12345678909",
          sequence: 2,
          tax_id: "12345678909"
        })

      assert {:ok, result} = MDFe.include_driver(opts)

      assert_receive {:posted, _url, body, _opts}
      sent = message(body)
      assert sent =~ ~s(<infEvento Id="ID110114#{key}02">)
      assert sent =~ "<CPF>12345678909</CPF><chMDFe>"
      assert sent =~ "<tpEvento>110114</tpEvento><nSeqEvento>2</nSeqEvento>"

      assert sent =~
               ~s(<detEvento versaoEvento="3.00"><evIncCondutorMDFe>) <>
                 ~s(<descEvento>Inclusao Condutor</descEvento><condutor>) <>
                 ~s(<xNome>JOSE &amp; FILHOS</xNome><CPF>12345678909</CPF></condutor>) <>
                 ~s(</evIncCondutorMDFe></detEvento>)

      refute sent =~ "<nProt>"
      assert result.status == :authorized
    end

    test "include_dfe (110115) with several documents", %{base: base, key: key} do
      nfe = "29260900000000000272550010000012341123456786"

      opts =
        event_opts(base, %{
          c_mun_carrega: "2927408",
          x_mun_carrega: "SALVADOR",
          documents: [
            %{c_mun_descarga: "3550308", x_mun_descarga: "SAO PAULO", ch_nfe: nfe},
            %{c_mun_descarga: "3304557", x_mun_descarga: "RIO DE JANEIRO", ch_nfe: nfe}
          ]
        })

      assert {:ok, result} = MDFe.include_dfe(opts)

      assert_receive {:posted, _url, body, _opts}
      sent = message(body)
      assert sent =~ ~s(<infEvento Id="ID110115#{key}01">)

      assert sent =~
               ~s(<evIncDFeMDFe><descEvento>Inclusao DF-e</descEvento><nProt>#{@n_prot}</nProt>) <>
                 ~s(<cMunCarrega>2927408</cMunCarrega><xMunCarrega>SALVADOR</xMunCarrega>) <>
                 ~s(<infDoc><cMunDescarga>3550308</cMunDescarga><xMunDescarga>SAO PAULO</xMunDescarga>) <>
                 ~s(<chNFe>#{nfe}</chNFe></infDoc><infDoc><cMunDescarga>3304557</cMunDescarga>)

      assert result.status == :authorized
    end

    test "a rejected event has no procEventoMDFe", %{base: base} do
      reply(fn _endpoint, body ->
        event_reply(message(body), 218, "Rejeicao: MDF-e ja esta cancelado")
      end)

      assert {:ok, result} =
               MDFe.cancel(event_opts(base, %{justification: "Erro na emissao do manifesto"}))

      assert {result.status, result.c_stat, result.xml} == {:rejected, 218, nil}
      assert result.signed_xml =~ "<Signature"
    end

    test "136 (registered, not linked) is accepted and archived", %{base: base} do
      reply(fn _endpoint, body -> event_reply(message(body), 136, "Evento registrado") end)

      assert {:ok, result} =
               MDFe.cancel(event_opts(base, %{justification: "Erro na emissao do manifesto"}))

      assert result.c_stat == 136
      assert result.xml =~ "<procEventoMDFe"
    end

    test "inputs refused before the network", %{base: base, key: key} do
      cancel = event_opts(base, %{justification: "Erro na emissao do manifesto"})

      assert {:error, :justification_too_short} = MDFe.cancel(%{cancel | justification: "curto"})

      assert {:error, :justification_too_long} =
               MDFe.cancel(%{cancel | justification: String.duplicate("x", 256)})

      assert {:error, :invalid_n_prot} = MDFe.cancel(%{cancel | n_prot: "1"})
      assert {:error, :invalid_tax_id} = MDFe.cancel(%{cancel | tax_id: "1"})

      assert {:error, :invalid_ch_mdfe} =
               MDFe.cancel(%{cancel | ch_mdfe: String.slice(key, 1..-1//1)})

      assert {:error, :invalid_environment} = MDFe.cancel(%{cancel | environment: :x})
      assert {:error, {:missing_keys, [:n_prot]}} = MDFe.cancel(Map.delete(cancel, :n_prot))

      close = event_opts(base, %{c_uf: "35", c_mun: "3550308", dt_enc: "2026-09-09"})
      assert {:error, :invalid_dt_enc} = MDFe.close(%{close | dt_enc: "09/09/2026"})
      assert {:error, :invalid_c_mun} = MDFe.close(%{close | c_mun: "355"})
      assert {:error, :invalid_c_uf} = MDFe.close(%{close | c_uf: 351})
      assert {:error, :invalid_c_uf} = MDFe.close(%{close | c_uf: -35})

      # A CPF given as an integer loses its leading zero and is refused by length.
      driver_int = event_opts(base, %{x_nome: "JOSE", cpf: 3_631_716_575})
      assert {:error, :invalid_cpf} = MDFe.include_driver(driver_int)

      driver = event_opts(base, %{x_nome: "JOSE", cpf: "12345678909"})
      assert {:error, :invalid_cpf} = MDFe.include_driver(%{driver | cpf: "123"})
      assert {:error, :invalid_x_nome} = MDFe.include_driver(%{driver | x_nome: "J"})

      dfe =
        event_opts(base, %{c_mun_carrega: "2927408", x_mun_carrega: "SALVADOR", documents: []})

      assert {:error, :invalid_documents} = MDFe.include_dfe(dfe)
      assert {:error, :invalid_documents} = MDFe.include_dfe(%{dfe | documents: [%{ch_nfe: "1"}]})

      assert {:error, :invalid_ch_nfe} =
               MDFe.include_dfe(%{
                 dfe
                 | documents: [%{c_mun_descarga: "3550308", x_mun_descarga: "SP", ch_nfe: "1"}]
               })

      refute_receive {:posted, _url, _body, _opts}
    end
  end

  # procs --------------------------------------------------------------------

  describe "SefazNfe.Proc MDF-e functions" do
    setup %{base: base} do
      %{xml: xml, access_key: key} = build()
      {:ok, auth} = MDFe.authorize(Map.put(base, :xml, xml))
      {:ok, auth: auth, key: key, base: base}
    end

    test "mdfe_proc/2 splices the signed bytes and the protocol verbatim", %{auth: auth, key: key} do
      digest = Regex.run(~r{<DigestValue>([^<]*)</DigestValue>}, auth.signed_xml) |> List.last()
      response = soap("MDFeRecepcaoSinc", ret_mdfe(key, digest))

      assert {:ok, proc} = Proc.mdfe_proc(auth.signed_xml, response)
      assert proc == auth.xml
      assert proc =~ prot_mdfe(key, digest, 100, "Autorizado o uso do MDF-e")
    end

    test "mdfe_proc/2 refuses what is not an authorization of this document", %{
      auth: auth,
      key: key
    } do
      digest = Regex.run(~r{<DigestValue>([^<]*)</DigestValue>}, auth.signed_xml) |> List.last()
      other_key = String.replace(key, ~r/.$/, "9")

      assert {:error, :no_protocol} = Proc.mdfe_proc(auth.signed_xml, soap("X", "<retMDFe/>"))

      assert {:error, :key_mismatch} =
               Proc.mdfe_proc(auth.signed_xml, soap("X", prot_mdfe(other_key, digest, 100, "ok")))

      assert {:error, :digest_mismatch} =
               Proc.mdfe_proc(auth.signed_xml, soap("X", prot_mdfe(key, "other", 100, "ok")))

      assert {:error, {:not_accepted, 204}} =
               Proc.mdfe_proc(auth.signed_xml, soap("X", prot_mdfe(key, digest, 204, "dup")))

      assert {:error, :no_inf_mdfe} = Proc.mdfe_proc("<NFe><infNFe Id=\"NFe1\"/></NFe>", "")
      assert {:error, {:xml, :malformed}} = Proc.mdfe_proc("<a", "")
    end

    test "a protocol without digVal is accepted by key alone", %{auth: auth, key: key} do
      response =
        soap("X", String.replace(prot_mdfe(key, "d", 100, "ok"), "<digVal>d</digVal>", ""))

      assert {:ok, _proc} = Proc.mdfe_proc(auth.signed_xml, response)
    end

    test "mdfe_event_proc/2 matches key and event, and refuses a different one", %{
      base: base,
      key: key
    } do
      assert {:ok, cancel} =
               MDFe.cancel(
                 event_opts(Map.put(base, :ch_mdfe, key), %{
                   justification: "Erro na emissao do manifesto"
                 })
               )

      assert_receive {:posted, _url, _body, _opts}
      assert_receive {:posted, _url, _body, _opts}

      assert {:error, :key_mismatch} =
               Proc.mdfe_event_proc(
                 cancel.signed_xml,
                 soap("X", ret_event(key, "110112", 135, "ok"))
               )

      assert {:error, :no_event_return} =
               Proc.mdfe_event_proc(cancel.signed_xml, soap("X", "<a/>"))

      assert {:error, {:not_accepted, 218}} =
               Proc.mdfe_event_proc(
                 cancel.signed_xml,
                 soap("X", ret_event(key, "110111", 218, "no"))
               )

      assert {:error, :no_event} = Proc.mdfe_event_proc("<a/>", "")
      # 132 is the encerramento's alone.
      assert {:error, {:not_accepted, 132}} =
               Proc.mdfe_event_proc(
                 cancel.signed_xml,
                 soap("X", ret_event(key, "110111", 132, "no"))
               )
    end

    test "mdfe_cancel_register/2 appends the retEventoMDFe once", %{auth: auth, key: key} do
      ret = ret_event(key, "110111", 135, "Evento registrado")
      event = soap("MDFeRecepcaoEvento", ret)

      assert {:ok, registered} = Proc.mdfe_cancel_register(auth.xml, event)
      assert String.ends_with?(registered, "</protMDFe>" <> ret <> "</mdfeProc>")
      assert String.starts_with?(registered, String.trim_trailing(auth.xml, "</mdfeProc>"))
      assert {:ok, _doc} = XML.parse(registered)

      assert {:ok, ^registered} = Proc.mdfe_cancel_register(registered, event)
    end

    test "mdfe_close_register/2 appends the encerramento, and 132 counts for it", %{
      auth: auth,
      key: key
    } do
      for c_stat <- [135, 132] do
        ret = ret_event(key, "110112", c_stat, "Encerramento")
        assert {:ok, closed} = Proc.mdfe_close_register(auth.xml, soap("X", ret))
        assert String.ends_with?(closed, ret <> "</mdfeProc>")
      end
    end

    test "the registers say why they refuse", %{auth: auth, key: key} do
      cancel = soap("X", ret_event(key, "110111", 135, "ok"))
      close = soap("X", ret_event(key, "110112", 135, "ok"))
      other = soap("X", ret_event(String.replace(key, ~r/.$/, "9"), "110111", 135, "ok"))

      assert {:error, {:not_a_closure, "110111"}} = Proc.mdfe_close_register(auth.xml, cancel)

      assert {:error, {:not_a_cancellation, "110112"}} =
               Proc.mdfe_cancel_register(auth.xml, close)

      assert {:error, :key_mismatch} = Proc.mdfe_cancel_register(auth.xml, other)
      assert {:error, :no_event_return} = Proc.mdfe_cancel_register(auth.xml, "<a/>")

      assert {:error, {:not_accepted, 218}} =
               Proc.mdfe_cancel_register(auth.xml, soap("X", ret_event(key, "110111", 218, "no")))

      assert {:error, :no_protocol} = Proc.mdfe_cancel_register("<mdfeProc/>", cancel)

      assert {:error, :not_an_mdfe_proc} =
               Proc.mdfe_cancel_register(
                 auth.signed_xml <> ~s(<protMDFe versao="3.00"></protMDFe>),
                 cancel
               )
    end
  end

  # QR code, endpoints, cStat, telemetry --------------------------------------

  describe "QRCode and the QR address" do
    test "the QR code text, normal and contingency" do
      key = String.duplicate("1", 44)
      assert QRCode.qr_code(@qr, key, "1", nil) == "#{@qr}?chMDFe=#{key}&tpAmb=1"
      assert QRCode.qr_code(@qr, key, "2", "abc=") == "#{@qr}?chMDFe=#{key}&tpAmb=2&sign=abc="
    end

    test "put_supl/3 needs a signed document with a valid Id" do
      cert = Fixtures.cert()
      assert {:error, {:mdfe, :not_signed}} = QRCode.put_supl(build().xml, cert, :homologation)

      assert {:error, {:mdfe, :invalid_id}} =
               QRCode.put_supl("<MDFe><a/></MDFe>", cert, :homologation)
    end

    test "the address is data in the snapshot, per environment" do
      assert {:ok, @qr} = Endpoints.mdfe_qr_code_url(:homologation)
      assert {:ok, @qr} = Endpoints.mdfe_qr_code_url(:production)
      assert {:error, {:invalid_environment, :x}} = Endpoints.mdfe_qr_code_url(:x)
    end
  end

  describe "CStat for MDF-e" do
    test "the codes the transport relies on" do
      assert CStat.classify(100) == :authorized
      assert CStat.classify(101) == :cancelled
      assert CStat.classify(132) == :closed
      assert CStat.classify(135) == :authorized
      assert CStat.classify(136) == :authorized
      assert CStat.classify(107) == :in_operation
      assert CStat.classify(539) == :rejected
    end
  end

  describe "telemetry" do
    @doc false
    def handle_event(_event, _measurements, metadata, test),
      do: send(test, {:operation, metadata})

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

    test "every MDF-e operation is model 58 with its own atom", %{base: base} do
      %{access_key: key} = build()
      with_key = Map.put(base, :ch_mdfe, key)

      calls = [
        {:mdfe_authorize, fn -> MDFe.authorize(Map.put(base, :mdfe, MDFeMap.mdfe())) end},
        {:mdfe_consult, fn -> MDFe.consult(with_key) end},
        {:mdfe_pending, fn -> MDFe.pending(Map.put(base, :tax_id, @tax_id)) end},
        {:mdfe_cancel,
         fn ->
           MDFe.cancel(event_opts(with_key, %{justification: "Erro na emissao do manifesto"}))
         end},
        {:mdfe_close,
         fn ->
           MDFe.close(event_opts(with_key, %{c_uf: "35", c_mun: "3550308", dt_enc: "2026-09-09"}))
         end},
        {:mdfe_include_driver,
         fn ->
           MDFe.include_driver(event_opts(with_key, %{x_nome: "JOSE", cpf: "12345678909"}))
         end},
        {:mdfe_include_dfe,
         fn ->
           MDFe.include_dfe(
             event_opts(with_key, %{
               c_mun_carrega: "2927408",
               x_mun_carrega: "SALVADOR",
               documents: [
                 %{
                   c_mun_descarga: "3550308",
                   x_mun_descarga: "SP",
                   ch_nfe: String.duplicate("1", 44)
                 }
               ]
             })
           )
         end}
      ]

      reply(fn _endpoint, body ->
        case message(body) do
          "<consSitMDFe" <> _ -> ret_cons_sit(key, 100, "Autorizado", "")
          "<consMDFeNaoEnc" <> _ -> ret_pending(112, "Nenhum", [])
          _other -> default_reply(body)
        end
      end)

      for {operation, call} <- calls do
        call.()

        assert_receive {:operation, %{operation: ^operation, model: 58, uf: "BA", outcome: :ok}}
        assert_receive {:operation, %{service: _service, model: 58}}
      end
    end

    test "a refused call still emits its span", %{base: base} do
      assert {:error, :invalid_tax_id} = MDFe.pending(Map.put(base, :tax_id, "1"))

      assert_receive {:operation,
                      %{operation: :mdfe_pending, model: 58, outcome: :invalid_tax_id}}
    end
  end

  # XSDs ---------------------------------------------------------------------

  describe "against the real PL_MDFe_300b schemas (xmllint)" do
    @tag skip: @skip_pl
    test "the sent MDF-e, normal and contingency, with its infMDFeSupl", %{base: base} do
      for tp_emis <- [1, 2] do
        {:ok, built} = Builder.build_mdfe(put_in(MDFeMap.mdfe(), [:ide, :tp_emis], tp_emis))
        assert {:ok, result} = MDFe.authorize(Map.put(base, :xml, built.xml))
        assert xmllint("mdfe_v3.00.xsd", result.signed_xml) == :ok
      end
    end

    @tag skip: @skip_pl
    test "xmllint does refuse a malformed QR code (the check is not vacuous)", %{base: base} do
      assert {:ok, result} = MDFe.authorize(Map.put(base, :mdfe, MDFeMap.mdfe()))
      broken = String.replace(result.signed_xml, "?chMDFe=", "?chave=")

      assert xmllint("mdfe_v3.00.xsd", broken) =~ "qrCodMDFe"
    end

    @tag skip: @skip_pl
    test "the four events, whole and detEvento", %{base: base} do
      %{access_key: key} = build()
      base = Map.put(base, :ch_mdfe, key)
      nfe = "29260900000000000272550010000012341123456786"

      events = [
        {"evCancMDFe_v3.00.xsd", &MDFe.cancel/1,
         %{justification: "Erro na emissao do manifesto"}},
        {"evEncMDFe_v3.00.xsd", &MDFe.close/1,
         %{c_uf: "35", c_mun: "3550308", dt_enc: ~D[2026-09-09], ind_enc_por_terceiro: true}},
        {"evIncCondutorMDFe_v3.00.xsd", &MDFe.include_driver/1,
         %{x_nome: "JOSE DA SILVA", cpf: "12345678909", sequence: 2}},
        {"evInclusaoDFeMDFe_v3.00.xsd", &MDFe.include_dfe/1,
         %{
           c_mun_carrega: "2927408",
           x_mun_carrega: "SALVADOR",
           documents: [
             %{c_mun_descarga: "3550308", x_mun_descarga: "SAO PAULO", ch_nfe: nfe},
             %{c_mun_descarga: "3304557", x_mun_descarga: "RIO DE JANEIRO", ch_nfe: nfe}
           ]
         }}
      ]

      for {schema, send, extra} <- events do
        assert {:ok, result} = send.(event_opts(base, extra))
        assert xmllint("eventoMDFe_v3.00.xsd", result.signed_xml) == :ok

        [_all, detail] = Regex.run(~r{<detEvento[^>]*>(.*)</detEvento>}s, result.signed_xml)
        fragment = String.replace(detail, ~r/^<(\w+)/, ~s(<\\1 xmlns="#{@ns}"), global: false)
        assert xmllint(schema, fragment) == :ok

        assert xmllint("procEventoMDFe_v3.00.xsd", result.xml) == :ok
      end
    end

    @tag skip: @skip_pl
    test "the mdfeProc is valid against procMDFe", %{base: base} do
      assert {:ok, result} = MDFe.authorize(Map.put(base, :mdfe, MDFeMap.mdfe()))
      assert xmllint("procMDFe_v3.00.xsd", result.xml) == :ok
    end

    @tag skip: @skip_pl
    test "the requests", %{base: base} do
      %{access_key: key} = build()
      reply(fn _endpoint, _body -> ret_pending(112, "Nenhum", []) end)

      assert {:ok, _} = MDFe.pending(Map.put(base, :tax_id, @tax_id))
      assert_receive {:posted, _url, pending, _opts}
      assert xmllint("consMDFeNaoEnc_v3.00.xsd", message(pending)) == :ok

      assert {:ok, _} = MDFe.pending(Map.put(base, :tax_id, "12345678909"))
      assert_receive {:posted, _url, cpf, _opts}
      assert xmllint("consMDFeNaoEnc_v3.00.xsd", message(cpf)) == :ok

      reply(fn _endpoint, _body -> ret_cons_sit(key, 100, "ok", "") end)
      assert {:ok, _} = MDFe.consult(Map.put(base, :ch_mdfe, key))
      assert_receive {:posted, _url, consult, _opts}
      assert xmllint("consSitMDFe_v3.00.xsd", message(consult)) == :ok
    end

    @tag skip: @skip_pl
    test "the fixture answers are valid against their XSDs" do
      %{access_key: key} = build()
      inner = fn xml -> Regex.run(~r{(<ret\w+ .*</ret\w+>)}s, xml) |> List.last() end

      assert xmllint("retMDFe_v3.00.xsd", inner.(soap("X", ret_mdfe(key, "ZGln")))) == :ok

      assert xmllint("retConsSitMDFe_v3.00.xsd", inner.(ret_cons_sit(key, 132, "Encerrado", ""))) ==
               :ok

      assert xmllint(
               "retConsMDFeNaoEnc_v3.00.xsd",
               inner.(ret_pending(111, "ok", [{key, @n_prot}]))
             ) == :ok

      assert xmllint(
               "retEventoMDFe_v3.00.xsd",
               inner.(soap("X", ret_event(key, "110111", 135, "ok")))
             ) == :ok
    end
  end

  defp xmllint(schema, xml) do
    file =
      Path.join(System.tmp_dir!(), "mdfe_transport_#{System.unique_integer([:positive])}.xml")

    File.write!(file, xml)

    try do
      case System.cmd("xmllint", ["--noout", "--schema", schema, file],
             cd: @mdfe_pl,
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, _status} -> output
      end
    after
      File.rm(file)
    end
  end
end
