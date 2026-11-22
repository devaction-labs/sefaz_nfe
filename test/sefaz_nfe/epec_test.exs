defmodule SefazNfe.EPECTest do
  @moduledoc """
  Event 110140. The transport is a stub that records the URL and body, so no
  socket is opened. `async: false` because `:sefaz_nfe, :soap` is global
  application environment.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.EPEC
  alias SefazNfe.Fixtures
  alias SefazNfe.NFeBuilder
  alias SefazNfe.Signer

  defmodule Stub do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(endpoint, body, _cert, opts) do
      send(:sefaz_nfe_epec_test, {:posted, endpoint, IO.iodata_to_binary(body), opts})

      {:ok,
       ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
         ~s(<retEnvEvento xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.00">) <>
         ~s(<idLote>1</idLote><tpAmb>2</tpAmb><cStat>128</cStat>) <>
         ~s(<xMotivo>Lote de Evento Processado</xMotivo>) <>
         ~s(<retEvento versao="1.00"><infEvento><tpAmb>2</tpAmb><cStat>136</cStat>) <>
         ~s(<xMotivo>Evento registrado, mas nao vinculado a NF-e</xMotivo>) <>
         ~s(<tpEvento>110140</tpEvento><nSeqEvento>1</nSeqEvento>) <>
         ~s(<dhRegEvento>2026-09-07T10:05:00-03:00</dhRegEvento><nProt>891260000000001</nProt>) <>
         ~s(</infEvento></retEvento></retEnvEvento></soap:Body></soap:Envelope>)}
    end
  end

  setup do
    previous = Application.get_env(:sefaz_nfe, :soap)
    Process.register(self(), :sefaz_nfe_epec_test)
    Application.put_env(:sefaz_nfe, :soap, Stub)

    on_exit(fn -> Application.put_env(:sefaz_nfe, :soap, previous) end)
    :ok
  end

  defp epec_opts(xml), do: %{xml: xml, cert: Fixtures.cert(), environment: :homologation}

  defp built(opts \\ []) do
    NFeBuilder.build([uf: "SP", uf_code: 35, tp_emis: 4] ++ opts).xml
  end

  defp det_evento(body) do
    [det] = Regex.run(~r{<detEvento.*?</detEvento>}s, body)
    det
  end

  @header ~s(<detEvento versao="1.00"><descEvento>EPEC</descEvento><cOrgaoAutor>35</cOrgaoAutor>) <>
            ~s(<tpAutor>1</tpAutor><verAplic>sefaz_nfe</verAplic>) <>
            ~s(<dhEmi>2026-09-07T10:00:00-03:00</dhEmi><tpNF>1</tpNF><IE>110042490114</IE>)

  describe "detEvento, byte for byte" do
    test "a CNPJ recipient with an IE" do
      xml =
        String.replace(
          built(),
          "<indIEDest>9</indIEDest></dest>",
          "<indIEDest>1</indIEDest><IE>123456789012</IE></dest>"
        )

      assert {:ok, _} = SefazNfe.epec(epec_opts(xml))
      assert_receive {:posted, _url, body, _opts}

      assert det_evento(body) ==
               @header <>
                 ~s(<dest><UF>SP</UF><CNPJ>99999999000191</CNPJ><IE>123456789012</IE>) <>
                 ~s(<vNF>100.00</vNF><vICMS>18.00</vICMS><vST>0.00</vST></dest></detEvento>)
    end

    test "a CPF recipient without an IE" do
      assert {:ok, _} = SefazNfe.epec(epec_opts(built(dest_tax_id: "00000000191")))
      assert_receive {:posted, _url, body, _opts}

      assert det_evento(body) ==
               @header <>
                 ~s(<dest><UF>SP</UF><CPF>00000000191</CPF>) <>
                 ~s(<vNF>100.00</vNF><vICMS>18.00</vICMS><vST>0.00</vST></dest></detEvento>)
    end

    test "a foreign recipient (idEstrangeiro)" do
      xml =
        String.replace(
          built(),
          "<CNPJ>99999999000191</CNPJ><xNome>",
          "<idEstrangeiro>ABC123456</idEstrangeiro><xNome>"
        )

      assert {:ok, _} = SefazNfe.epec(epec_opts(xml))
      assert_receive {:posted, _url, body, _opts}

      assert det_evento(body) ==
               @header <>
                 ~s(<dest><UF>SP</UF><idEstrangeiro>ABC123456</idEstrangeiro>) <>
                 ~s(<vNF>100.00</vNF><vICMS>18.00</vICMS><vST>0.00</vST></dest></detEvento>)
    end

    test "an empty recipient IE is left out" do
      xml = String.replace(built(), "<indIEDest>9</indIEDest></dest>", "<IE></IE></dest>")

      assert {:ok, _} = SefazNfe.epec(epec_opts(xml))
      assert_receive {:posted, _url, body, _opts}
      refute det_evento(body) =~ "<dest><UF>SP</UF><CNPJ>99999999000191</CNPJ><IE>"
    end

    test ":ver_aplic overrides the document's verProc" do
      opts = Map.put(epec_opts(built()), :ver_aplic, "meu-erp 2.1")

      assert {:ok, _} = SefazNfe.epec(opts)
      assert_receive {:posted, _url, body, _opts}
      assert det_evento(body) =~ "<verAplic>meu-erp 2.1</verAplic>"
    end
  end

  describe "the event" do
    test "goes to the Ambiente Nacional as 110140, seq 1, cOrgao 91, authored by the emitter" do
      assert {:ok, result} = SefazNfe.epec(epec_opts(built()))

      assert_receive {:posted, url, body, opts}
      assert {:ok, ^url} = SefazNfe.Endpoints.url("AN", :homologation, :nfe_recepcao_evento)
      assert opts[:service] == :nfe_recepcao_evento

      [[key]] = Regex.scan(~r/<chNFe>(\d{44})<\/chNFe>/, body, capture: :all_but_first)
      assert body =~ ~s(Id="ID110140#{key}01")
      assert body =~ "<cOrgao>91</cOrgao>"
      assert body =~ "<CNPJ>00000000000191</CNPJ><chNFe>"
      assert body =~ "<tpEvento>110140</tpEvento><nSeqEvento>1</nSeqEvento>"
      assert body =~ ~s(<Reference URI="#ID110140#{key}01">)

      assert result.c_stat == 136
      assert result.status == :authorized
      assert result.n_prot == "891260000000001"
      assert result.dh_recbto == "2026-09-07T10:05:00-03:00"
    end

    test "a natural-person emitter is the event's CPF author" do
      xml =
        String.replace(
          built(),
          "<emit><CNPJ>00000000000191</CNPJ>",
          "<emit><CPF>12345678909</CPF>"
        )

      assert {:ok, _} = SefazNfe.epec(epec_opts(xml))
      assert_receive {:posted, _url, body, _opts}
      assert body =~ "<CPF>12345678909</CPF><chNFe>"
    end

    test "a signed NF-e works as well, and is not touched" do
      {:ok, signed} = Signer.sign_nfe(built(), Fixtures.cert())

      assert {:ok, _} = SefazNfe.epec(epec_opts(signed))
      assert_receive {:posted, _url, body, _opts}
      assert det_evento(body) =~ "<vNF>100.00</vNF>"
    end

    test "the event signature is on infEvento" do
      assert {:ok, _} = SefazNfe.epec(epec_opts(built()))
      assert_receive {:posted, _url, body, _opts}
      assert body =~ ~r{</infEvento><Signature}
    end
  end

  describe "refused before the network" do
    test "an NF-e that is not tpEmis 4" do
      xml = NFeBuilder.build(uf: "SP", uf_code: 35).xml

      assert {:error, {:not_epec_document, "1"}} = SefazNfe.epec(epec_opts(xml))
      refute_receive {:posted, _url, _body, _opts}
    end

    test "a model 65 document" do
      xml = NFeBuilder.build(model: 65, uf: "SP", uf_code: 35, tp_emis: 4).xml

      assert {:error, {:unsupported_for_model, 65}} = SefazNfe.epec(epec_opts(xml))
      refute_receive {:posted, _url, _body, _opts}
    end

    test "no recipient" do
      assert {:error, {:epec, :missing_dest}} =
               SefazNfe.epec(epec_opts(built(dest_tax_id: nil)))

      refute_receive {:posted, _url, _body, _opts}
    end

    test "an access key whose UF is not cUF" do
      xml = String.replace(built(), "<cUF>35</cUF>", "<cUF>29</cUF>")

      assert {:error, {:epec, {:ch_nfe_uf_mismatch, "35", "29"}}} =
               SefazNfe.epec(epec_opts(xml))

      refute_receive {:posted, _url, _body, _opts}
    end

    test "tpAmb against :environment" do
      opts = %{epec_opts(built()) | environment: :production}

      assert {:error, :environment_mismatch} = SefazNfe.epec(opts)
    end

    test "missing options and a non-binary xml" do
      assert {:error, {:missing_keys, [:xml]}} =
               SefazNfe.epec(Map.delete(epec_opts(built()), :xml))

      assert {:error, :invalid_xml} = SefazNfe.epec(epec_opts(:nope))
    end
  end

  describe "EPEC.extract/2" do
    test "reads the facts and does not need the network" do
      assert {:ok, %{ch_nfe: key, tax_id: "00000000000191", epec: epec}} =
               EPEC.extract(built())

      assert byte_size(key) == 44
      assert epec.c_uf == "35"
      assert epec.dest_id == {:cnpj, "99999999000191"}
      assert epec.dest_ie == nil
      assert {v_nf, v_icms, v_st} = {epec.v_nf, epec.v_icms, epec.v_st}
      assert {v_nf, v_icms, v_st} == {"100.00", "18.00", "0.00"}
    end
  end

  # Only the event element order and types the MOC publishes can say whether
  # the event is valid; the schema package is not vendored, so the test is
  # skipped on a machine without it or without xmllint.
  describe "against the real PL_010 event schema (xmllint)" do
    @schemas "/home/alex/PhpstormProjects/fiscal-gateway/vendor/nfephp-org/sped-nfe/schemes/PL_010_V1.30"
    @skip if(File.dir?(@schemas) and System.find_executable("xmllint"),
            do: false,
            else: "xmllint or the PL_010 schemas are not available"
          )

    @tag skip: @skip
    test "the signed EPEC event validates for each kind of recipient" do
      with_ie =
        String.replace(
          built(),
          "<indIEDest>9</indIEDest></dest>",
          "<indIEDest>1</indIEDest><IE>123456789012</IE></dest>"
        )

      foreign =
        String.replace(
          built(),
          "<CNPJ>99999999000191</CNPJ><xNome>",
          "<idEstrangeiro>ABC123456</idEstrangeiro><xNome>"
        )

      for xml <- [built(), with_ie, built(dest_tax_id: "00000000191"), foreign] do
        assert {:ok, _} = SefazNfe.epec(epec_opts(xml))
        assert_receive {:posted, _url, body, _opts}
        [envelope] = Regex.run(~r{<envEvento.*</envEvento>}s, body)

        assert xmllint(envelope, "envEvento_v1.00.xsd") == :ok, envelope

        # envEvento carries detEvento as xs:any; its own layout is e110140NFe.
        detail =
          String.replace(
            det_evento(body),
            "<detEvento ",
            ~s(<detEvento xmlns="http://www.portalfiscal.inf.br/nfe" )
          )

        assert xmllint(detail, "e110140NFe_v1.00.xsd") == :ok, detail
      end
    end

    defp xmllint(xml, schema) do
      file = Path.join(System.tmp_dir!(), "epec_#{System.unique_integer([:positive])}.xml")
      File.write!(file, xml)

      try do
        case System.cmd("xmllint", ["--noout", "--schema", schema, file],
               cd: @schemas,
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
end
