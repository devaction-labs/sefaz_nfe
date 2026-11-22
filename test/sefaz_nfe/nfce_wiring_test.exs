defmodule SefazNfe.NFCeWiringTest do
  @moduledoc """
  Which endpoints a call reaches, by document model. The transport is a stub
  that records the URL and the body, so no socket is opened.

  `async: false` because `:sefaz_nfe, :soap` is global application environment.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.Endpoints
  alias SefazNfe.Fixtures
  alias SefazNfe.NFeBuilder

  defmodule Stub do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(endpoint, body, _cert, opts) do
      send(:sefaz_nfe_nfce_wiring_test, {:posted, endpoint, IO.iodata_to_binary(body), opts})

      {:ok,
       ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
         ~s(<retStub xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">) <>
         ~s(<tpAmb>2</tpAmb><cStat>107</cStat><xMotivo>Servico em Operacao</xMotivo>) <>
         ~s(</retStub></soap:Body></soap:Envelope>)}
    end
  end

  setup do
    previous = Application.get_env(:sefaz_nfe, :soap)
    Process.register(self(), :sefaz_nfe_nfce_wiring_test)
    Application.put_env(:sefaz_nfe, :soap, Stub)

    on_exit(fn -> Application.put_env(:sefaz_nfe, :soap, previous) end)
    :ok
  end

  defp base(uf), do: %{cert: Fixtures.cert(), uf: uf, environment: :homologation}

  defp nfce(opts \\ []) do
    NFeBuilder.build([model: 65, uf: "BA", uf_code: 29] ++ opts)
  end

  defp url(uf, service, model) do
    {:ok, url} = Endpoints.url(uf, :homologation, service, model)
    url
  end

  describe "authorize/1" do
    test "a model 65 document goes to the NFC-e endpoint and gets its infNFeSupl" do
      %{xml: xml, access_key: key} = nfce()

      assert {:ok, _result} = SefazNfe.authorize(Map.put(base("BA"), :xml, xml))

      assert_receive {:posted, posted, body, _opts}
      assert posted == url("BA", :nfe_autorizacao, 65)
      assert posted =~ "nfce-homologacao.svrs.rs.gov.br"
      assert body =~ "<mod>65</mod>"

      assert body =~
               "</infNFe><infNFeSupl><qrCode>http://hnfe.sefaz.ba.gov.br/servicos/nfce/qrcode.aspx" <>
                 "?p=#{key}|3|2</qrCode><urlChave>http://hinternet.sefaz.ba.gov.br/nfce/consulta" <>
                 "</urlChave></infNFeSupl><Signature"
    end

    test "the document sent is well-formed with an accent before the splice point" do
      %{xml: xml} = nfce()
      accented = String.replace(xml, "EMPRESA TESTE LTDA", "MÓVEIS NOGUEIRA")

      assert {:ok, result} = SefazNfe.authorize(Map.put(base("BA"), :xml, accented))
      assert {:ok, doc} = SefazNfe.XML.parse(result.signed_xml)
      assert SefazNfe.XML.text(doc, "xNome") == "MÓVEIS NOGUEIRA"
      assert result.signed_xml =~ "</infNFe><infNFeSupl>"
    end

    test "a host-built infNFeSupl is sent as it is" do
      %{xml: xml} = nfce()
      supl = "<infNFeSupl><qrCode>q</qrCode><urlChave>u</urlChave></infNFeSupl>"
      xml = String.replace(xml, "</infNFe>", "</infNFe>" <> supl)

      assert {:ok, result} = SefazNfe.authorize(Map.put(base("BA"), :xml, xml))
      assert result.signed_xml |> String.split("infNFeSupl>") |> length() == 3
      assert result.signed_xml =~ supl
    end

    test "forwards the QR code 2.00 options, CSC included, and sends it" do
      %{xml: xml, access_key: key} = nfce()
      csc = "0123456789ABCDEF0123456789ABCDEF0123"

      opts =
        Map.merge(base("BA"), %{xml: xml, qr_code_version: 2, csc: csc, csc_id: "000001"})

      assert {:ok, result} = SefazNfe.authorize(opts)

      seq = "#{key}|2|2|1"
      hash = :sha |> :crypto.hash(seq <> csc) |> Base.encode16(case: :upper)

      assert_receive {:posted, _url, body, _opts}
      assert body =~ "?p=#{seq}|#{hash}</qrCode>"
      assert result.signed_xml =~ "?p=#{seq}|#{hash}</qrCode>"
      refute body =~ csc
    end

    test "QR code 2.00 without a CSC never reaches the transport" do
      %{xml: xml} = nfce()

      assert {:error, {:missing_csc, [:csc, :csc_id]}} =
               SefazNfe.authorize(Map.merge(base("BA"), %{xml: xml, qr_code_version: 2}))

      refute_receive {:posted, _url, _body, _opts}
    end

    test "SP model 65 hits its own NFC-e authorizer" do
      %{xml: xml} = nfce(uf: "SP", uf_code: 35)

      assert {:ok, _result} = SefazNfe.authorize(Map.put(base("SP"), :xml, xml))
      assert_receive {:posted, "https://homologacao.nfce.fazenda.sp.gov.br" <> _, _body, _opts}
    end

    test "tpEmis 9 without an infNFeSupl never reaches the transport" do
      %{xml: xml} = nfce()
      offline = String.replace(xml, "<tpEmis>1</tpEmis>", "<tpEmis>9</tpEmis>")

      assert {:error, {:unsupported, :offline_qr_code}} =
               SefazNfe.authorize(Map.put(base("BA"), :xml, offline))

      refute_receive {:posted, _url, _body, _opts}
    end

    test "model 55 goes to the NF-e endpoint and gets no infNFeSupl" do
      %{xml: xml} = NFeBuilder.build(uf: "BA", uf_code: 29)

      assert {:ok, result} = SefazNfe.authorize(Map.put(base("BA"), :xml, xml))

      assert_receive {:posted, posted, body, _opts}
      assert posted == url("BA", :nfe_autorizacao, 55)
      assert posted =~ "hnfe.sefaz.ba.gov.br"
      refute body =~ "infNFeSupl"
      refute result.signed_xml =~ "infNFeSupl"
    end

    test "any other mod is refused before the network" do
      %{xml: xml} = nfce()
      cte = String.replace(xml, "<mod>65</mod>", "<mod>57</mod>")

      assert {:error, {:unsupported_model, "57"}} =
               SefazNfe.authorize(Map.put(base("BA"), :xml, cte))

      refute_receive {:posted, _url, _body, _opts}
    end
  end

  describe "by access key" do
    test "consult_protocol routes a model 65 key to the NFC-e endpoint" do
      %{access_key: key} = nfce()

      assert {:ok, _} = SefazNfe.consult_protocol(Map.put(base("SP"), :ch_nfe, key))
      assert_receive {:posted, posted, _body, _opts}
      assert posted == url("SP", :nfe_consulta_protocolo, 65)
    end

    test "consult_protocol routes a model 55 key to the NF-e endpoint" do
      %{access_key: key} = NFeBuilder.build()

      assert {:ok, _} = SefazNfe.consult_protocol(Map.put(base("SP"), :ch_nfe, key))
      assert_receive {:posted, posted, _body, _opts}
      assert posted == url("SP", :nfe_consulta_protocolo, 55)
    end

    test "cancel routes a model 65 key to the NFC-e endpoint" do
      %{access_key: key} = nfce()

      opts =
        Map.merge(base("BA"), %{
          ch_nfe: key,
          n_prot: "129260000000001",
          justification: "Cancelamento por erro de digitacao",
          tax_id: "00000000000191"
        })

      assert {:ok, _} = SefazNfe.cancel(opts)
      assert_receive {:posted, posted, body, _opts}
      assert posted == url("BA", :nfe_recepcao_evento, 65)
      assert body =~ "<tpEvento>110111</tpEvento>"
    end

    test "cce is refused for a model 65 key, before the network" do
      %{access_key: key} = nfce()

      opts =
        Map.merge(base("BA"), %{
          ch_nfe: key,
          correction: "Correcao com mais de quinze caracteres",
          tax_id: "00000000000191"
        })

      assert {:error, {:unsupported_for_model, 65}} = SefazNfe.cce(opts)
      refute_receive {:posted, _url, _body, _opts}
    end

    test "cce still works for a model 55 key" do
      %{access_key: key} = NFeBuilder.build()

      opts =
        Map.merge(base("SP"), %{
          ch_nfe: key,
          correction: "Correcao com mais de quinze caracteres",
          tax_id: "00000000000191"
        })

      assert {:ok, _} = SefazNfe.cce(opts)
      assert_receive {:posted, posted, _body, _opts}
      assert posted == url("SP", :nfe_recepcao_evento, 55)
    end

    test "a key whose model is neither is refused" do
      key = binary_part(NFeBuilder.build().access_key, 0, 20) <> "57" <> String.duplicate("1", 22)

      assert {:error, {:unsupported_model, "57"}} =
               SefazNfe.consult_protocol(Map.put(base("SP"), :ch_nfe, key))
    end

    test "manifest stays on the Ambiente Nacional" do
      %{access_key: key} = NFeBuilder.build()

      assert {:ok, _} =
               SefazNfe.manifest(
                 :awareness,
                 Map.merge(base("SP"), %{ch_nfe: key, tax_id: "00000000000191"})
               )

      assert_receive {:posted, posted, _body, _opts}
      assert posted =~ "hom1.nfe.fazenda.gov.br"
    end
  end

  describe ":model on the services that take no document" do
    test "service_status defaults to 55 and follows :model" do
      assert {:ok, _} = SefazNfe.service_status(base("BA"))
      assert_receive {:posted, posted, _body, _opts}
      assert posted == url("BA", :nfe_status_servico, 55)

      assert {:ok, _} = SefazNfe.service_status(Map.put(base("BA"), :model, 65))
      assert_receive {:posted, posted, _body, _opts}
      assert posted == url("BA", :nfe_status_servico, 65)
      assert posted =~ "nfce-homologacao.svrs.rs.gov.br"
    end

    test "void_numbers follows :model, which is also the mod it voids" do
      opts =
        Map.merge(base("SP"), %{
          serie: 1,
          n_ini: 5,
          n_fim: 7,
          justification: "Numeracao pulada por falha",
          tax_id: "00000000000191",
          model: 65
        })

      assert {:ok, _} = SefazNfe.void_numbers(opts)
      assert_receive {:posted, posted, body, _opts}
      assert posted == url("SP", :nfe_inutilizacao, 65)
      assert body =~ "<mod>65</mod>"
    end

    test "void_numbers stays on model 55 by default" do
      opts =
        Map.merge(base("SP"), %{
          serie: 1,
          n_ini: 5,
          n_fim: 7,
          justification: "Numeracao pulada por falha",
          tax_id: "00000000000191"
        })

      assert {:ok, _} = SefazNfe.void_numbers(opts)
      assert_receive {:posted, posted, body, _opts}
      assert posted == url("SP", :nfe_inutilizacao, 55)
      assert body =~ "<mod>55</mod>"
    end

    test "authorization_result follows :model" do
      opts = Map.merge(base("MG"), %{n_rec: "351000000000001", model: 65})

      assert {:ok, _} = SefazNfe.authorization_result(opts)
      assert_receive {:posted, posted, _body, _opts}
      assert posted == url("MG", :nfe_ret_autorizacao, 65)
      assert posted =~ "nfce.fazenda.mg.gov.br"
    end

    test "an unsupported :model never reaches the transport" do
      assert {:error, {:unsupported_model, 57}} =
               SefazNfe.service_status(Map.put(base("BA"), :model, 57))

      refute_receive {:posted, _url, _body, _opts}
    end
  end
end
