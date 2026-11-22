defmodule SefazNfe.CTeEventsTest do
  @moduledoc """
  `SefazNfe.CTe.Events` bytes, `SefazNfe.CTe.Supl` (the QR code), the QR data in
  the endpoint table and the CT-e `cStat` classification. The XSD checks run
  `xmllint` against `SEFAZ_NFE_CTE_PL_PATH` (the `PL_CTe_400_RTC` package) and
  skip when it is unset.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.CStat
  alias SefazNfe.CTe.Events
  alias SefazNfe.CTe.Supl
  alias SefazNfe.CTeWire
  alias SefazNfe.Endpoints
  alias SefazNfe.Fixtures
  alias SefazNfe.Signer

  @pl System.get_env("SEFAZ_NFE_CTE_PL_PATH")
  @skip if(
          System.find_executable("xmllint") != nil and is_binary(@pl) and
            File.exists?(Path.join(@pl || "", "eventoCTe_v4.00.xsd")),
          do: false,
          else: "SEFAZ_NFE_CTE_PL_PATH or xmllint is not available"
        )

  @key CTeWire.key(57)
  @cte_ns "http://www.portalfiscal.inf.br/cte"

  defp opts(extra) do
    Map.merge(
      %{
        ch_cte: @key,
        tax_id: "00000000000191",
        uf_code: 29,
        tp_amb: 2,
        timestamp: "2026-09-07T10:05:00-03:00",
        n_prot: "129260000000001"
      },
      extra
    )
  end

  defp sign(event) do
    {:ok, signed} = Signer.sign(event, Fixtures.cert(), "infEvento", "eventoCTe")
    signed
  end

  defp xmllint(xml, xsd) do
    path = Path.join(System.tmp_dir!(), "cte_ev_#{System.unique_integer([:positive])}.xml")
    File.write!(path, xml)

    try do
      System.cmd("xmllint", ["--noout", "--schema", Path.join(@pl, xsd), path],
        stderr_to_stdout: true
      )
    after
      File.rm(path)
    end
  end

  # The one child of `detEvento`, given the CT-e namespace the way it inherits it.
  defp detail(event) do
    [element, tag] =
      Regex.run(~r|<detEvento[^>]*>(<(ev\w+)>.*</ev\w+>)</detEvento>|s, event,
        capture: :all_but_first
      )

    {tag, String.replace(element, "<#{tag}>", ~s(<#{tag} xmlns="#{@cte_ns}">), global: false)}
  end

  @delivery %{
    dh_entrega: "2026-09-07T09:30:00-03:00",
    n_doc: "1234567",
    x_nome: "MARIA DA SILVA",
    image: <<1, 2, 3, 4, 5>>
  }
  @failure %{dh_tentativa_entrega: "2026-09-07T09:30:00-03:00", tp_motivo: 1}

  # Every event of the module, as (name, xsd of its detEvento child, built XML).
  defp events do
    ce = opts(@delivery)

    [
      {"cancel", "evCancCTe_v4.00.xsd",
       Events.cancel(opts(%{justification: "Erro de digitacao no valor"}))},
      {"cancel with an ampersand", "evCancCTe_v4.00.xsd",
       Events.cancel(opts(%{justification: "Erro de A & B no valor"}))},
      {"cce", "evCCeCTe_v4.00.xsd",
       Events.correction(
         opts(%{
           sequence: 3,
           corrections: [
             %{grupo_alterado: "ide", campo_alterado: "xObs", valor_alterado: "NOVO TEXTO"},
             %{
               grupo_alterado: "infDoc",
               campo_alterado: "chave",
               valor_alterado: "x",
               nro_item_alterado: 12
             }
           ]
         })
       )},
      {"delivery proof", "evCECTe_v4.00.xsd", Events.delivery_proof(ce)},
      {"delivery proof with everything", "evCECTe_v4.00.xsd",
       Events.delivery_proof(
         Map.merge(ce, %{
           latitude: -12.971598,
           longitude: 38.5,
           ch_nfes: [String.duplicate("3", 44), String.duplicate("4", 44)],
           dh_hash: "2026-09-07T09:31:00-03:00"
         })
       )},
      {"cancel delivery proof", "evCancCECTe_v4.00.xsd",
       Events.cancel_delivery_proof(opts(%{n_prot_ce: "329260000000042"}))},
      {"delivery failure", "evIECTe_v4.00.xsd", Events.delivery_failure(opts(@failure))},
      {"delivery failure, motive 4 with image", "evIECTe_v4.00.xsd",
       Events.delivery_failure(
         opts(
           Map.merge(@failure, %{
             tp_motivo: 4,
             x_just_motivo: "Estabelecimento fechado no horario",
             n_tentativa: 2,
             latitude: "-12.971598",
             longitude: "-38.501000",
             image: "foto",
             ch_nfes: [String.duplicate("3", 44)]
           })
         )
       )},
      {"cancel delivery failure", "evCancIECTe_v4.00.xsd",
       Events.cancel_delivery_failure(opts(%{n_prot_ie: "329260000000043"}))}
    ]
  end

  describe "event bytes against the XSDs" do
    @describetag skip: @skip

    test "the signed eventoCTe is valid for every event" do
      for {name, _xsd, event} <- events() do
        assert {_out, 0} = xmllint(sign(event), "eventoCTe_v4.00.xsd"), name
      end
    end

    test "detEvento's child is valid against the event's own schema" do
      for {name, xsd, event} <- events() do
        {_tag, element} = detail(event)
        {out, status} = xmllint(element, xsd)
        assert status == 0, "#{name}: #{out}"
      end
    end
  end

  describe "event shape" do
    test "Id is ID + tpEvento + key + three digits, as the XSD pattern wants" do
      event = Events.cancel(opts(%{justification: "Erro de digitacao no valor", sequence: 7}))

      assert event =~ ~s(<infEvento Id="ID110111#{@key}007">)
      assert event =~ "<nSeqEvento>007</nSeqEvento>"
      assert Regex.match?(~r/Id="ID[0-9]{12}[A-Z0-9]{12}[0-9]{29}"/, event)
    end

    test "the root is eventoCTe 4.00, detEvento carries versaoEvento" do
      event = Events.cancel(opts(%{justification: "Erro de digitacao no valor"}))

      assert String.starts_with?(event, ~s(<eventoCTe xmlns="#{@cte_ns}" versao="4.00">))
      assert event =~ ~s(<detEvento versaoEvento="4.00">)
      refute event =~ ~s(<detEvento versao=)
      assert event =~ "<chCTe>#{@key}</chCTe>"
      refute event =~ "chNFe"
    end

    test "a CPF author and XML escaping" do
      event =
        Events.cancel(opts(%{tax_id: "12345678909", justification: "Erro <A> & \"B\" no valor"}))

      assert event =~ "<CPF>12345678909</CPF>"
      assert event =~ "<xJust>Erro &lt;A&gt; &amp; \"B\" no valor</xJust>"
    end

    test "the timestamp is trimmed to the XSD's shape" do
      stamp = fn value ->
        event =
          Events.cancel(opts(%{justification: "Erro de digitacao no valor", timestamp: value}))

        [stamp] = Regex.run(~r|<dhEvento>([^<]*)</dhEvento>|, event, capture: :all_but_first)
        stamp
      end

      assert stamp.("2026-09-07T10:05:00.123456-03:00") == "2026-09-07T10:05:00-03:00"
      assert stamp.("2026-09-07T13:05:00Z") == "2026-09-07T13:05:00+00:00"
      assert stamp.(~U[2026-09-07 13:05:00.999Z]) == "2026-09-07T13:05:00+00:00"
    end

    test "xCondUso is the XSD's unaccented text, verbatim" do
      event =
        Events.correction(
          opts(%{
            corrections: [%{grupo_alterado: "ide", campo_alterado: "x", valor_alterado: "y"}]
          })
        )

      assert event =~
               "<xCondUso>A Carta de Correcao e disciplinada pelo Art. 58-B do CONVENIO/SINIEF 06/89: " <>
                 "Fica permitida a utilizacao de carta de correcao, para regularizacao de erro ocorrido na " <>
                 "emissao de documentos fiscais relativos a prestacao de servico de transporte, desde que o " <>
                 "erro nao esteja relacionado com: I - as variaveis que determinam o valor do imposto tais " <>
                 "como: base de calculo, aliquota, diferenca de preco, quantidade, valor da prestacao;II - a " <>
                 "correcao de dados cadastrais que implique mudanca do emitente, tomador, remetente ou do " <>
                 "destinatario;III - a data de emissao ou de saida.</xCondUso>"
    end
  end

  describe "the delivery hash" do
    test "is base64(sha1(key <> base64(image))), 28 characters" do
      image = :crypto.strong_rand_bytes(64)
      hash = Events.delivery_hash(@key, image)

      assert hash == Base.encode64(:crypto.hash(:sha, @key <> Base.encode64(image)))
      assert String.length(hash) == 28
      assert byte_size(Base.decode64!(hash)) == 20
    end

    test "depends on the key and on the image" do
      assert Events.delivery_hash(@key, "a") != Events.delivery_hash(@key, "b")
      assert Events.delivery_hash(@key, "a") != Events.delivery_hash(CTeWire.key(67), "a")
    end
  end

  describe "the QR code (infCTeSupl)" do
    test "the text is the on-line form, with no sign" do
      assert Supl.qr_code("https://dfe-portal.svrs.rs.gov.br/cte/qrCode", @key, "2") ==
               "https://dfe-portal.svrs.rs.gov.br/cte/qrCode?chCTe=#{@key}&tpAmb=2"
    end

    test "it is spliced before the Signature, outside of what is signed" do
      %{xml: xml, access_key: key} = CTeWire.built(:cte)
      {:ok, signed} = Signer.sign(xml, Fixtures.cert(), "infCte", "CTe")
      assert {:ok, with_supl} = Supl.put(signed, "BA", :homologation)

      assert with_supl =~
               "</infCte><infCTeSupl><qrCodCTe>https://dfe-portal.svrs.rs.gov.br/cte/qrCode" <>
                 "?chCTe=#{key}&amp;tpAmb=2</qrCodCTe></infCTeSupl><Signature"

      # The signature does not cover it: the digest is that of the unsigned infCte.
      {:ok, doc} = SefazNfe.XML.parse(signed)
      {:ok, doc_supl} = SefazNfe.XML.parse(with_supl)

      assert SefazNfe.XML.text(doc, "DigestValue") == SefazNfe.XML.text(doc_supl, "DigestValue")
    end

    test "an unsigned document gets it before the closing root" do
      %{xml: xml} = CTeWire.built(:cte_os)
      assert {:ok, with_supl} = Supl.put(xml, "BA", :production)
      assert with_supl =~ "</infCte><infCTeSupl><qrCodCTe>"
      assert String.ends_with?(with_supl, "</infCTeSupl></CTeOS>")
    end

    test "a document that already has one is returned as it is" do
      %{xml: signed} = CTeWire.signed(:cte)
      assert {:ok, ^signed} = Supl.put(signed, "BA", :homologation)
    end

    test "the environment selects the portal where the UF has one per environment" do
      %{xml: xml} = CTeWire.built(:cte)

      assert {:ok, hom} = Supl.put(xml, "MT", :homologation)
      assert hom =~ "https://homologacao.sefaz.mt.gov.br/cte/qrcode?chCTe="

      assert {:ok, prod} =
               Supl.put(
                 String.replace(xml, "<tpAmb>2</tpAmb>", "<tpAmb>1</tpAmb>"),
                 "MT",
                 :production
               )

      assert prod =~ "https://www.sefaz.mt.gov.br/cte/qrcode?chCTe="
      assert prod =~ "&amp;tpAmb=1"
    end

    test "contingency forms that need a signed QR are refused, and a UF that has no portal" do
      %{xml: xml} = CTeWire.built(:cte)
      fs_da = String.replace(xml, "<tpEmis>1</tpEmis>", "<tpEmis>5</tpEmis>")

      assert {:error, {:unsupported, {:tp_emis, "5"}}} = Supl.put(fs_da, "BA", :homologation)

      assert {:error, {:unknown_endpoint, "XX", :cte_qr_code}} =
               Supl.put(xml, "XX", :homologation)
    end

    @tag skip: @skip
    test "a signed CT-e and CT-e OS with infCTeSupl are valid against the CT-e schemas" do
      for {kind, xsd} <- [{:cte, "cte_v4.00.xsd"}, {:cte_os, "cteOS_v4.00.xsd"}] do
        %{xml: signed} = CTeWire.signed(kind)
        {out, status} = xmllint(signed, xsd)
        assert status == 0, "#{kind}: #{out}"
      end
    end

    @tag skip: @skip
    test "the answers the fixtures write are valid against the retorno schemas" do
      %{xml: signed} = CTeWire.signed(:cte)
      event = sign(Events.cancel(opts(%{justification: "Erro de digitacao no valor"})))

      cases = [
        {CTeWire.answer(signed), ~r|<retCTe.*</retCTe>|s, "retCTe_v4.00.xsd"},
        {CTeWire.event_answer(event), ~r|<retEventoCTe.*</retEventoCTe>|s,
         "retEventoCTe_v4.00.xsd"},
        {CTeWire.consult_answer(@key), ~r|<retConsSitCTe.*</retConsSitCTe>|s,
         "retConsSitCTe_v4.00.xsd"}
      ]

      for {soap, extract, xsd} <- cases do
        [inner] = Regex.run(extract, soap)
        {out, status} = xmllint(inner, xsd)
        assert status == 0, "#{xsd}: #{out}"
      end
    end
  end

  describe "the QR data in the CT-e endpoint table" do
    test "every authorizer has an address in both environments" do
      snapshot = JSON.decode!(File.read!("priv/endpoints/cte_4.00.json"))

      assert Map.keys(snapshot["qr_code"]) |> Enum.sort() ==
               Map.keys(snapshot["authorizers"]) |> Enum.sort()

      for {authorizer, environments} <- snapshot["qr_code"],
          environment <- ["homologation", "production"] do
        assert environments[environment] =~ ~r{^https?://}, "#{authorizer} #{environment}"
      end
    end

    test "the portal of the authorizer that serves the UF" do
      assert {:ok, "https://dfe-portal.svrs.rs.gov.br/cte/qrCode"} =
               Endpoints.cte_qr_code_url("BA", :homologation)

      assert {:ok, "https://nfe.fazenda.sp.gov.br/CTeConsulta/qrCode"} =
               Endpoints.cte_qr_code_url(:pe, :production)

      assert {:ok, "https://homologacao.nfe.fazenda.sp.gov.br/CTeConsulta/qrCode"} =
               Endpoints.cte_qr_code_url("SP", :homologation)

      assert {:ok, "http://www.fazenda.pr.gov.br/cte/qrcode"} =
               Endpoints.cte_qr_code_url("PR", :production)

      assert {:ok, "https://portalcte.fazenda.mg.gov.br/portalcte/sistema/qrcode.xhtml"} =
               Endpoints.cte_qr_code_url("MG", :production)
    end

    test "every UF has one" do
      snapshot = JSON.decode!(File.read!("priv/endpoints/cte_4.00.json"))

      for uf <- Map.keys(snapshot["uf_authorizer"]),
          environment <- [:homologation, :production] do
        assert {:ok, _url} = Endpoints.cte_qr_code_url(uf, environment), "#{uf} #{environment}"
      end
    end

    test "unknown UF and environment" do
      assert {:error, {:unknown_endpoint, "XX", :cte_qr_code}} =
               Endpoints.cte_qr_code_url("XX", :production)

      assert {:error, {:invalid_environment, :prod}} = Endpoints.cte_qr_code_url("BA", :prod)
    end
  end

  describe "CStat for CT-e" do
    test "the codes the CT-e MOC names classify as the NF-e ones" do
      assert CStat.classify(100, 57) == :authorized
      assert CStat.classify(101, 57) == :cancelled
      assert CStat.classify(110, 57) == :denied
      assert CStat.classify(301, 67) == :denied
      assert CStat.classify(107, 57) == :in_operation
      assert CStat.classify(108, 57) == :retryable
      assert CStat.classify(109, 57) == :retryable
      assert CStat.classify(539, 57) == :rejected

      for c_stat <- [134, 135, 136, 155], do: assert(CStat.classify(c_stat, 57) == :authorized)
    end

    test "678 is Consumo Indevido for CT-e and an ordinary rejection for NF-e" do
      assert CStat.classify(678, 57) == :retryable
      assert CStat.classify(678, 67) == :retryable
      assert CStat.classify(678, 55) == :rejected
      assert CStat.classify(678) == :rejected
      assert CStat.classify(656, 57) == :retryable
    end

    test "134 is a registered event for any model" do
      assert CStat.classify(134) == :authorized
      assert CStat.classify(134, 55) == :authorized
    end
  end
end
