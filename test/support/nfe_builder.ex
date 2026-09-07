defmodule SefazNfe.NFeBuilder do
  @moduledoc """
  Builds a schema-valid NF-e 4.00 for tests and for a homologação round trip.

  This lives in `test/` on purpose. AD-001 keeps NF-e composition with the ERP
  because it carries tax arithmetic, and moving this into `lib/` would make the
  library a second fiscal engine. It exists only so the transport can be proven
  end to end without one.

  The numbers here are fixed test values, not a calculation: the ICMS is
  written, not derived.
  """

  @homologation_name "NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"

  # cMunFG has to sit inside the emitter's own UF, or SEFAZ answers cStat 271.
  # One capital per state is enough for a fixture.
  @capitals %{
    "AC" => {1_200_401, "RIO BRANCO"},
    "AL" => {2_704_302, "MACEIO"},
    "AM" => {1_302_603, "MANAUS"},
    "AP" => {1_600_303, "MACAPA"},
    "BA" => {2_927_408, "SALVADOR"},
    "CE" => {2_304_400, "FORTALEZA"},
    "DF" => {5_300_108, "BRASILIA"},
    "ES" => {3_205_309, "VITORIA"},
    "GO" => {5_208_707, "GOIANIA"},
    "MA" => {2_111_300, "SAO LUIS"},
    "MG" => {3_106_200, "BELO HORIZONTE"},
    "MS" => {5_002_704, "CAMPO GRANDE"},
    "MT" => {5_103_403, "CUIABA"},
    "PA" => {1_501_402, "BELEM"},
    "PB" => {2_507_507, "JOAO PESSOA"},
    "PE" => {2_611_606, "RECIFE"},
    "PI" => {2_211_001, "TERESINA"},
    "PR" => {4_106_902, "CURITIBA"},
    "RJ" => {3_304_557, "RIO DE JANEIRO"},
    "RN" => {2_408_102, "NATAL"},
    "RO" => {1_100_205, "PORTO VELHO"},
    "RR" => {1_400_100, "BOA VISTA"},
    "RS" => {4_314_902, "PORTO ALEGRE"},
    "SC" => {4_205_407, "FLORIANOPOLIS"},
    "SE" => {2_800_308, "ARACAJU"},
    "SP" => {3_550_308, "SAO PAULO"},
    "TO" => {1_721_000, "PALMAS"}
  }

  @doc """
  A single-item NF-e for `tax_id`.

  In homologação the MOC requires the recipient name to be exactly
  `#{@homologation_name}`, so it is forced rather than taken from `opts`.
  """
  @spec build(keyword()) :: %{xml: String.t(), access_key: String.t()}
  def build(opts \\ []) do
    tax_id = Keyword.get(opts, :tax_id, "00000000000191")
    uf_code = Keyword.get(opts, :uf_code, 35)
    uf = Keyword.get(opts, :uf, "SP")
    serie = Keyword.get(opts, :serie, 1)
    number = Keyword.get(opts, :number, 1)
    tp_amb = Keyword.get(opts, :tp_amb, 2)
    # The emitter's IE is TIe in the XSD: digits only. "ISENTO" is legal for a
    # recipient and rejected here as cStat 225.
    ie = Keyword.get(opts, :ie, "110042490114")
    # dhEmi is second precision with an explicit offset. A microsecond field —
    # what NaiveDateTime.to_iso8601/1 produces — fails the schema pattern.
    emitted_at = opts |> Keyword.get(:emitted_at, "2026-09-07T10:00:00-03:00") |> trim_precision()

    # NT 2019.001 rejects cNF equal to nNF (cStat 897), so it is independent of
    # the document number rather than derived from it.
    c_nf =
      opts
      |> Keyword.get_lazy(:c_nf, fn -> :rand.uniform(89_999_999) + 10_000_000 end)
      |> to_string()
      |> String.pad_leading(8, "0")

    key = access_key(uf_code, emitted_at, tax_id, serie, number, c_nf)

    {municipality, city} = Map.fetch!(@capitals, uf)

    xml =
      ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
        ~s(<NFe xmlns="http://www.portalfiscal.inf.br/nfe">) <>
        ~s(<infNFe Id="NFe#{key}" versao="4.00">) <>
        ide(uf_code, c_nf, serie, number, emitted_at, tp_amb, String.last(key), municipality) <>
        emit(tax_id, ie, uf, municipality, city) <>
        dest(tp_amb, uf, municipality, city, Keyword.get(opts, :dest_tax_id, "99999999000191")) <>
        aut_xml(Keyword.get(opts, :auth_tax_id)) <>
        det() <>
        total() <>
        ~s(<transp><modFrete>9</modFrete></transp>) <>
        ~s(<pag><detPag><indPag>0</indPag><tPag>01</tPag><vPag>100.00</vPag></detPag></pag>) <>
        ~s(</infNFe></NFe>)

    %{xml: xml, access_key: key}
  end

  defp trim_precision(<<stamp::binary-size(19), rest::binary>>) do
    stamp <> String.replace(rest, ~r/^\.\d+/, "")
  end

  defp trim_precision(stamp), do: stamp

  # autXML identifies whoever else may download the XML — typically the
  # accounting office. Bahia rejects a document without it (cStat 486) and the
  # rejection itself names the SEFAZ CNPJ to use when there is no office.
  # It sits between dest and det in the schema sequence.
  defp aut_xml(nil), do: ""
  defp aut_xml(id), do: ~s(<autXML>#{tax_id_element(id)}</autXML>)

  defp tax_id_element(id) when byte_size(id) == 11, do: ~s(<CPF>#{id}</CPF>)
  defp tax_id_element(id), do: ~s(<CNPJ>#{id}</CNPJ>)

  @doc """
  The 44 digit access key, with its modulo 11 check digit.

  Layout is fixed by the MOC: UF, year and month, CNPJ, model, series, number,
  emission type, numeric code, check digit.
  """
  @spec access_key(
          pos_integer(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          String.t()
        ) ::
          String.t()
  def access_key(uf_code, emitted_at, tax_id, serie, number, c_nf) do
    <<_::binary-size(2), year::binary-size(2), "-", month::binary-size(2), _rest::binary>> =
      emitted_at

    body =
      "#{uf_code}#{year}#{month}#{tax_id}55" <>
        String.pad_leading(to_string(serie), 3, "0") <>
        String.pad_leading(to_string(number), 9, "0") <> "1" <> c_nf

    body <> check_digit(body)
  end

  @doc "Modulo 11 check digit, weights 2 to 9 cycling from the right."
  @spec check_digit(String.t()) :: String.t()
  def check_digit(body) do
    sum =
      body
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit, index}, acc ->
        acc + String.to_integer(digit) * (rem(index, 8) + 2)
      end)

    case rem(sum, 11) do
      remainder when remainder in [0, 1] -> "0"
      remainder -> to_string(11 - remainder)
    end
  end

  defp ide(uf_code, c_nf, serie, number, emitted_at, tp_amb, c_dv, municipality) do
    ~s(<ide><cUF>#{uf_code}</cUF><cNF>#{c_nf}</cNF><natOp>VENDA DE MERCADORIA</natOp>) <>
      ~s(<mod>55</mod><serie>#{serie}</serie><nNF>#{number}</nNF>) <>
      ~s(<dhEmi>#{emitted_at}</dhEmi><tpNF>1</tpNF><idDest>1</idDest>) <>
      ~s(<cMunFG>#{municipality}</cMunFG><tpImp>1</tpImp><tpEmis>1</tpEmis><cDV>#{c_dv}</cDV>) <>
      ~s(<tpAmb>#{tp_amb}</tpAmb><finNFe>1</finNFe><indFinal>1</indFinal>) <>
      ~s(<indPres>1</indPres><procEmi>0</procEmi><verProc>sefaz_nfe</verProc></ide>)
  end

  defp emit(tax_id, ie, uf, municipality, city) do
    ~s(<emit><CNPJ>#{tax_id}</CNPJ><xNome>EMPRESA TESTE LTDA</xNome>) <>
      ~s(<xFant>TESTE</xFant>) <>
      ~s(<enderEmit><xLgr>RUA TESTE</xLgr><nro>100</nro><xBairro>CENTRO</xBairro>) <>
      ~s(<cMun>#{municipality}</cMun><xMun>#{city}</xMun><UF>#{uf}</UF><CEP>01001000</CEP>) <>
      ~s(<cPais>1058</cPais><xPais>BRASIL</xPais></enderEmit>) <>
      ~s(<IE>#{ie}</IE><CRT>3</CRT></emit>)
  end

  # A CPF recipient is a natural person, so the document goes out as CPF and
  # never as a short CNPJ. In homologação the name is fixed by the MOC.
  defp dest(tp_amb, uf, municipality, city, dest_tax_id) do
    name = if tp_amb == 2, do: @homologation_name, else: "CLIENTE TESTE"

    ~s(<dest>#{tax_id_element(dest_tax_id)}<xNome>#{name}</xNome>) <>
      ~s(<enderDest><xLgr>RUA CLIENTE</xLgr><nro>200</nro><xBairro>CENTRO</xBairro>) <>
      ~s(<cMun>#{municipality}</cMun><xMun>#{city}</xMun><UF>#{uf}</UF><CEP>01001000</CEP>) <>
      ~s(<cPais>1058</cPais><xPais>BRASIL</xPais></enderDest>) <>
      ~s(<indIEDest>9</indIEDest></dest>)
  end

  defp det do
    ~s(<det nItem="1"><prod><cProd>001</cProd><cEAN>SEM GTIN</cEAN>) <>
      ~s(<xProd>PRODUTO TESTE</xProd><NCM>84713012</NCM><CFOP>5102</CFOP>) <>
      ~s(<uCom>UN</uCom><qCom>1.0000</qCom><vUnCom>100.0000000000</vUnCom>) <>
      ~s(<vProd>100.00</vProd><cEANTrib>SEM GTIN</cEANTrib><uTrib>UN</uTrib>) <>
      ~s(<qTrib>1.0000</qTrib><vUnTrib>100.0000000000</vUnTrib><indTot>1</indTot></prod>) <>
      ~s(<imposto>) <>
      ~s(<ICMS><ICMS00><orig>0</orig><CST>00</CST><modBC>3</modBC>) <>
      ~s(<vBC>100.00</vBC><pICMS>18.00</pICMS><vICMS>18.00</vICMS></ICMS00></ICMS>) <>
      ~s(<PIS><PISAliq><CST>01</CST><vBC>100.00</vBC><pPIS>1.65</pPIS><vPIS>1.65</vPIS>) <>
      ~s(</PISAliq></PIS>) <>
      ~s(<COFINS><COFINSAliq><CST>01</CST><vBC>100.00</vBC><pCOFINS>7.60</pCOFINS>) <>
      ~s(<vCOFINS>7.60</vCOFINS></COFINSAliq></COFINS>) <>
      ibs_cbs() <>
      ~s(</imposto></det>)
  end

  # NT 2025.002 (reforma tributária) requires the IBS/CBS group per item from
  # 2026; without it SEFAZ answers cStat 1115, and with a zero rate 1026. The
  # 2026 transition rates are 0.1% IBS UF and 0.9% CBS. The library never fills these —
  # AD-001 keeps that with the ERP — this is a fixture so the transport can be
  # proven end to end.
  defp ibs_cbs do
    ~s(<IBSCBS><CST>000</CST><cClassTrib>000001</cClassTrib>) <>
      ~s(<gIBSCBS><vBC>100.00</vBC>) <>
      ~s(<gIBSUF><pIBSUF>0.1000</pIBSUF><vIBSUF>0.10</vIBSUF></gIBSUF>) <>
      ~s(<gIBSMun><pIBSMun>0.0000</pIBSMun><vIBSMun>0.00</vIBSMun></gIBSMun>) <>
      ~s(<vIBS>0.10</vIBS>) <>
      ~s(<gCBS><pCBS>0.9000</pCBS><vCBS>0.90</vCBS></gCBS>) <>
      ~s(</gIBSCBS></IBSCBS>)
  end

  defp ibs_cbs_total do
    ~s(<IBSCBSTot><vBCIBSCBS>100.00</vBCIBSCBS>) <>
      ~s(<gIBS>) <>
      ~s(<gIBSUF><vDif>0.00</vDif><vDevTrib>0.00</vDevTrib><vIBSUF>0.10</vIBSUF></gIBSUF>) <>
      ~s(<gIBSMun><vDif>0.00</vDif><vDevTrib>0.00</vDevTrib><vIBSMun>0.00</vIBSMun></gIBSMun>) <>
      ~s(<vIBS>0.10</vIBS><vCredPres>0.00</vCredPres>) <>
      ~s(<vCredPresCondSus>0.00</vCredPresCondSus>) <>
      ~s(</gIBS>) <>
      ~s(<gCBS><vDif>0.00</vDif><vDevTrib>0.00</vDevTrib><vCBS>0.90</vCBS>) <>
      ~s(<vCredPres>0.00</vCredPres><vCredPresCondSus>0.00</vCredPresCondSus></gCBS>) <>
      ~s(</IBSCBSTot>)
  end

  defp total do
    ~s(<total><ICMSTot><vBC>100.00</vBC><vICMS>18.00</vICMS><vICMSDeson>0.00</vICMSDeson>) <>
      ~s(<vFCP>0.00</vFCP><vBCST>0.00</vBCST><vST>0.00</vST><vFCPST>0.00</vFCPST>) <>
      ~s(<vFCPSTRet>0.00</vFCPSTRet><vProd>100.00</vProd><vFrete>0.00</vFrete>) <>
      ~s(<vSeg>0.00</vSeg><vDesc>0.00</vDesc><vII>0.00</vII><vIPI>0.00</vIPI>) <>
      ~s(<vIPIDevol>0.00</vIPIDevol><vPIS>1.65</vPIS><vCOFINS>7.60</vCOFINS>) <>
      ~s(<vOutro>0.00</vOutro><vNF>100.00</vNF></ICMSTot>) <>
      ibs_cbs_total() <>
      ~s(</total>)
  end
end
