defmodule SefazNfe.CTeWire do
  @moduledoc false
  # Test fixtures for the CT-e transport: a signed CT-e / CT-e OS and the SEFAZ
  # answers (retCTe with protCTe, retCTeOS, retEventoCTe) written from the
  # shapes of `retCTe_v4.00.xsd` and `retEventoCTe_v4.00.xsd`.

  alias SefazNfe.Builder
  alias SefazNfe.CTe.Supl
  alias SefazNfe.CTeMap
  alias SefazNfe.Fixtures
  alias SefazNfe.Signer
  alias SefazNfe.XML

  @cte_ns "http://www.portalfiscal.inf.br/cte"
  @soap ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>)

  @doc "The unsigned XML and key of the fixture CT-e (`:cte`) or CT-e OS (`:cte_os`)."
  @spec built(:cte | :cte_os, map() | nil) :: %{xml: String.t(), access_key: String.t()}
  def built(kind \\ :cte, map \\ nil)

  def built(:cte, map) do
    {:ok, built} = Builder.build_cte(map || CTeMap.cte())
    built
  end

  def built(:cte_os, map) do
    {:ok, built} = Builder.build_cte_os(map || CTeMap.cte_os())
    built
  end

  @doc "The fixture, signed and with `infCTeSupl`, as `SefazNfe.CTe.authorize/1` sends it."
  @spec signed(:cte | :cte_os) :: %{xml: String.t(), key: String.t()}
  def signed(kind \\ :cte) do
    %{xml: xml, access_key: key} = built(kind)
    root = if kind == :cte, do: "CTe", else: "CTeOS"
    {:ok, signed} = Signer.sign(xml, Fixtures.cert(), "infCte", root)
    {:ok, signed} = Supl.put(signed, "BA", :homologation)
    %{xml: signed, key: key}
  end

  @doc "A 44-character key of `model` (57 or 67) whose DV is not checked by the facade."
  @spec key(57 | 67) :: String.t()
  def key(57), do: "29260900000000000191570010000012341123456795"
  def key(67), do: "29260900000000000191670010000000771876543215"

  @doc "The `cteDadosMsg` of a posted envelope, base64-decoded and gunzipped."
  @spec sent_cte(binary()) :: String.t()
  def sent_cte(envelope) do
    [payload] =
      Regex.run(~r|<cteDadosMsg[^>]*>([^<]*)</cteDadosMsg>|, envelope, capture: :all_but_first)

    payload |> Base.decode64!() |> :zlib.gunzip()
  end

  @doc "The `cteDadosMsg` content of a posted envelope that is not compressed."
  @spec sent_plain(binary()) :: String.t()
  def sent_plain(envelope) do
    [message] =
      Regex.run(~r|<cteDadosMsg[^>]*>(.*)</cteDadosMsg>|s, envelope, capture: :all_but_first)

    message
  end

  @doc """
  The retCTe (`:cte`) or retCTeOS (`:cte_os`) SOAP answer for a posted CT-e.

  Options: `:c_stat` (100), `:x_motivo`, `:key` and `:digest` (default: the
  document's own), `:protocol` (false leaves protCTe out).
  """
  @spec answer(String.t(), keyword()) :: String.t()
  def answer(sent_cte, opts \\ []) do
    {:ok, doc} = XML.parse(sent_cte)
    key = Keyword.get_lazy(opts, :key, fn -> doc |> XML.attribute("infCte", "Id") |> key_of() end)
    digest = Keyword.get_lazy(opts, :digest, fn -> XML.text(doc, "DigestValue") end)
    c_stat = Keyword.get(opts, :c_stat, 100)
    x_motivo = Keyword.get(opts, :x_motivo, "Autorizado o uso do CT-e")

    {ret, service} =
      if XML.element(doc, "CTeOS"),
        do: {"retCTeOS", "CTeRecepcaoOSV4"},
        else: {"retCTe", "CTeRecepcaoSincV4"}

    protocol =
      if Keyword.get(opts, :protocol, true) do
        ~s(<protCTe versao="4.00"><infProt Id="ID129260000000001">) <>
          ~s(<tpAmb>2</tpAmb><verAplic>SVRS202609</verAplic><chCTe>#{key}</chCTe>) <>
          ~s(<dhRecbto>2026-09-07T10:00:05-03:00</dhRecbto><nProt>129260000000001</nProt>) <>
          ~s(<digVal>#{digest}</digVal><cStat>#{c_stat}</cStat><xMotivo>#{x_motivo}</xMotivo>) <>
          ~s(</infProt></protCTe>)
      else
        ""
      end

    soap(
      service,
      ~s(<#{ret} versao="4.00" xmlns="#{@cte_ns}"><tpAmb>2</tpAmb><cUF>29</cUF>) <>
        ~s(<verAplic>SVRS202609</verAplic><cStat>#{c_stat}</cStat><xMotivo>#{x_motivo}</xMotivo>) <>
        "#{protocol}</#{ret}>"
    )
  end

  @doc """
  The retEventoCTe SOAP answer for an event, as written by SEFAZ.

  Options: `:c_stat` (135), `:x_motivo`, `:key`, `:tp_evento` and `:sequence`
  (default: those of the event sent).
  """
  @spec event_answer(String.t(), keyword()) :: String.t()
  def event_answer(sent_event, opts \\ []) do
    {:ok, doc} = XML.parse(sent_event)
    key = Keyword.get_lazy(opts, :key, fn -> XML.text(doc, "chCTe") end)
    tp_evento = Keyword.get_lazy(opts, :tp_evento, fn -> XML.text(doc, "tpEvento") end)
    sequence = Keyword.get_lazy(opts, :sequence, fn -> XML.text(doc, "nSeqEvento") end)
    c_stat = Keyword.get(opts, :c_stat, 135)
    x_motivo = Keyword.get(opts, :x_motivo, "Evento registrado e vinculado ao CT-e")

    soap(
      "CTeRecepcaoEventoV4",
      ~s(<retEventoCTe versao="4.00" xmlns="#{@cte_ns}"><infEvento Id="ID329260000000042">) <>
        ~s(<tpAmb>2</tpAmb><verAplic>SVRS202609</verAplic><cOrgao>29</cOrgao>) <>
        ~s(<cStat>#{c_stat}</cStat><xMotivo>#{x_motivo}</xMotivo><chCTe>#{key}</chCTe>) <>
        ~s(<tpEvento>#{tp_evento}</tpEvento><xEvento>Evento</xEvento>) <>
        ~s(<nSeqEvento>#{sequence}</nSeqEvento>) <>
        ~s(<dhRegEvento>2026-09-07T10:05:00-03:00</dhRegEvento><nProt>329260000000042</nProt>) <>
        ~s(</infEvento></retEventoCTe>)
    )
  end

  @doc "The retConsSitCTe SOAP answer of a consultation."
  @spec consult_answer(String.t(), keyword()) :: String.t()
  def consult_answer(key, opts \\ []) do
    c_stat = Keyword.get(opts, :c_stat, 100)
    x_motivo = Keyword.get(opts, :x_motivo, "Autorizado o uso do CT-e")

    soap(
      "CTeConsultaV4",
      ~s(<retConsSitCTe versao="4.00" xmlns="#{@cte_ns}"><tpAmb>2</tpAmb>) <>
        ~s(<verAplic>SVRS202609</verAplic><cStat>#{c_stat}</cStat><xMotivo>#{x_motivo}</xMotivo>) <>
        ~s(<cUF>29</cUF><protCTe versao="4.00"><infProt><tpAmb>2</tpAmb>) <>
        ~s(<verAplic>SVRS202609</verAplic><chCTe>#{key}</chCTe>) <>
        ~s(<dhRecbto>2026-09-07T10:00:05-03:00</dhRecbto><nProt>129260000000001</nProt>) <>
        ~s(<digVal>AAAAAAAAAAAAAAAAAAAAAAAAAAA=</digVal><cStat>#{c_stat}</cStat>) <>
        ~s(<xMotivo>#{x_motivo}</xMotivo></infProt></protCTe></retConsSitCTe>)
    )
  end

  @doc "A SOAP answer carrying only `cStat` and `xMotivo` in a rejection of the request."
  @spec rejection(non_neg_integer(), String.t()) :: String.t()
  def rejection(c_stat, x_motivo \\ "Rejeicao") do
    soap(
      "CTeRecepcaoSincV4",
      ~s(<retCTe versao="4.00" xmlns="#{@cte_ns}"><tpAmb>2</tpAmb><cUF>29</cUF>) <>
        ~s(<verAplic>SVRS202609</verAplic><cStat>#{c_stat}</cStat><xMotivo>#{x_motivo}</xMotivo>) <>
        ~s(</retCTe>)
    )
  end

  @doc "Wraps `inner` in the SOAP envelope the service answers with."
  @spec soap(String.t(), String.t()) :: String.t()
  def soap(service, inner) do
    ~s(<?xml version="1.0" encoding="utf-8"?>) <>
      @soap <>
      ~s(<cteResultMsg xmlns="http://www.portalfiscal.inf.br/cte/wsdl/#{service}">) <>
      inner <> ~s(</cteResultMsg></soap:Body></soap:Envelope>)
  end

  defp key_of("CTe" <> key), do: key
end
