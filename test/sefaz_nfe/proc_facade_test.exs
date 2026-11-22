defmodule SefazNfe.ProcFacadeTest do
  @moduledoc """
  What the facade puts in `Result.xml` and `Result.signed_xml` for events and
  for voiding, through a stub transport that answers as SEFAZ would for what it
  was sent. No socket.

  `async: false` because `:sefaz_nfe, :soap` is global application environment.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.Fixtures
  alias SefazNfe.NFeBuilder
  alias SefazNfe.XML

  @ns "http://www.portalfiscal.inf.br/nfe"

  defmodule Stub do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(_endpoint, body, _cert, _opts) do
      sent = IO.iodata_to_binary(body)
      send(:sefaz_nfe_proc_facade_test, {:sent, sent})

      {:ok, envelope(answer(sent, Application.get_env(:sefaz_nfe, :stub_c_stat)))}
    end

    defp field(sent, tag) do
      [_, value] = Regex.run(~r{<#{tag}>([^<]*)</#{tag}>}, sent)
      value
    end

    defp envelope(inner),
      do:
        ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
          inner <> ~s(</soap:Body></soap:Envelope>)

    defp answer(sent, c_stat) do
      if String.contains?(sent, "<inutNFe"), do: void(sent, c_stat), else: event(sent, c_stat)
    end

    defp event(sent, c_stat) do
      ~s(<retEnvEvento xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.00"><idLote>1</idLote>) <>
        ~s(<tpAmb>2</tpAmb><cStat>128</cStat><xMotivo>Lote de Evento Processado</xMotivo>) <>
        ~s(<retEvento versao="1.00"><infEvento><tpAmb>2</tpAmb><cOrgao>91</cOrgao><cStat>#{c_stat}</cStat>) <>
        ~s(<xMotivo>Evento registrado</xMotivo><chNFe>#{field(sent, "chNFe")}</chNFe>) <>
        ~s(<tpEvento>#{field(sent, "tpEvento")}</tpEvento><nSeqEvento>1</nSeqEvento>) <>
        ~s(<dhRegEvento>2026-09-07T10:10:02-03:00</dhRegEvento><nProt>135260000000002</nProt>) <>
        ~s(</infEvento></retEvento></retEnvEvento>)
    end

    defp void(sent, c_stat) do
      ~s(<retInutNFe xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00"><infInut>) <>
        ~s(<tpAmb>#{field(sent, "tpAmb")}</tpAmb><cStat>#{c_stat}</cStat><xMotivo>Inutilizacao</xMotivo>) <>
        ~s(<cUF>#{field(sent, "cUF")}</cUF><ano>#{field(sent, "ano")}</ano><CNPJ>#{field(sent, "CNPJ")}</CNPJ>) <>
        ~s(<mod>#{field(sent, "mod")}</mod><serie>#{field(sent, "serie")}</serie>) <>
        ~s(<nNFIni>#{field(sent, "nNFIni")}</nNFIni><nNFFin>#{field(sent, "nNFFin")}</nNFFin>) <>
        ~s(<dhRecbto>2026-09-07T10:20:00-03:00</dhRecbto><nProt>135260000000003</nProt>) <>
        ~s(</infInut></retInutNFe>)
    end
  end

  setup do
    previous = Application.get_env(:sefaz_nfe, :soap)
    Process.register(self(), :sefaz_nfe_proc_facade_test)
    Application.put_env(:sefaz_nfe, :soap, Stub)
    Application.put_env(:sefaz_nfe, :stub_c_stat, 135)

    on_exit(fn ->
      Application.put_env(:sefaz_nfe, :soap, previous)
      Application.delete_env(:sefaz_nfe, :stub_c_stat)
    end)

    %{key: NFeBuilder.build(tax_id: "00000000000191").access_key}
  end

  defp base(key) do
    %{
      ch_nfe: key,
      tax_id: "00000000000191",
      cert: Fixtures.cert(),
      uf: "SP",
      environment: :homologation
    }
  end

  defp signed_in(sent) do
    [evento] = Regex.run(~r{<evento .*</evento>}s, sent)
    evento
  end

  test "cancel: Result.xml is the procEventoNFe of what was sent and what was answered", %{
    key: key
  } do
    opts =
      Map.merge(base(key), %{n_prot: "135260000000001", justification: "Cancelamento de teste"})

    assert {:ok, result} = SefazNfe.cancel(opts)
    assert_receive {:sent, sent}

    assert result.c_stat == 135
    assert result.signed_xml == signed_in(sent)

    assert String.starts_with?(
             result.xml,
             ~s(<?xml version="1.0" encoding="UTF-8"?><procEventoNFe xmlns="#{@ns}" versao="1.00">) <>
               result.signed_xml <> "<retEvento"
           )

    assert String.ends_with?(result.xml, "</retEvento></procEventoNFe>")
    assert result.xml =~ "<nProt>135260000000002</nProt>"
    assert {:ok, _doc} = XML.parse(result.xml)
  end

  test "cce and manifest answer the same way", %{key: key} do
    assert {:ok, cce} =
             SefazNfe.cce(Map.put(base(key), :correction, "Correcao de teste do campo"))

    assert cce.xml =~ "<procEventoNFe"
    assert cce.xml =~ "<tpEvento>110110</tpEvento>"

    assert {:ok, manifest} = SefazNfe.manifest(:awareness, base(key))
    assert manifest.xml =~ "<tpEvento>210210</tpEvento>"
    assert manifest.signed_xml =~ "<Signature"
  end

  test "an event SEFAZ did not register has no xml, only the signed one", %{key: key} do
    Application.put_env(:sefaz_nfe, :stub_c_stat, 573)

    opts =
      Map.merge(base(key), %{n_prot: "135260000000001", justification: "Cancelamento de teste"})

    assert {:ok, result} = SefazNfe.cancel(opts)
    assert result.c_stat == 573
    assert result.xml == nil
    assert result.signed_xml =~ "<evento"
  end

  test "void_numbers: Result.xml is the procInutNFe" do
    Application.put_env(:sefaz_nfe, :stub_c_stat, 102)

    assert {:ok, result} =
             SefazNfe.void_numbers(%{
               serie: 1,
               n_ini: 1,
               n_fim: 10,
               justification: "Numeracao pulada por falha",
               tax_id: "00000000000191",
               cert: Fixtures.cert(),
               uf: "SP",
               environment: :homologation
             })

    assert_receive {:sent, sent}

    assert result.c_stat == 102
    assert result.signed_xml =~ "<inutNFe"

    assert String.starts_with?(
             result.xml,
             ~s(<?xml version="1.0" encoding="UTF-8"?><procInutNFe xmlns="#{@ns}" versao="4.00">) <>
               result.signed_xml <> "<retInutNFe"
           )

    assert String.contains?(sent, result.signed_xml)
    assert String.ends_with?(result.xml, "</retInutNFe></procInutNFe>")
    assert {:ok, _doc} = XML.parse(result.xml)
  end

  test "void_numbers rejected has no xml" do
    Application.put_env(:sefaz_nfe, :stub_c_stat, 241)

    assert {:ok, result} =
             SefazNfe.void_numbers(%{
               serie: 1,
               n_ini: 1,
               n_fim: 10,
               justification: "Numeracao pulada por falha",
               tax_id: "00000000000191",
               cert: Fixtures.cert(),
               uf: "SP",
               environment: :homologation
             })

    assert result.xml == nil
    assert result.signed_xml =~ "<inutNFe"
  end
end
