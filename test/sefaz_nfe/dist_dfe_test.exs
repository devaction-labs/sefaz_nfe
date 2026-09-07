defmodule SefazNfe.DistDFeTest do
  use ExUnit.Case, async: true

  alias SefazNfe.DistDFe
  alias SefazNfe.SOAP.Envelope

  defp zip(xml), do: xml |> :zlib.gzip() |> Base.encode64()

  defp response(c_stat, x_motivo, documents) do
    ~s(<?xml version="1.0" encoding="utf-8"?>) <>
      ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
      ~s(<nfeDistDFeInteresseResponse><nfeDistDFeInteresseResult>) <>
      ~s(<retDistDFeInt xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.01">) <>
      ~s(<tpAmb>2</tpAmb><cStat>#{c_stat}</cStat><xMotivo>#{x_motivo}</xMotivo>) <>
      ~s(<ultNSU>000000000000015</ultNSU><maxNSU>000000000000042</maxNSU>) <>
      ~s(<loteDistDFeInt>#{documents}</loteDistDFeInt>) <>
      ~s(</retDistDFeInt></nfeDistDFeInteresseResult>) <>
      ~s(</nfeDistDFeInteresseResponse></soap:Body></soap:Envelope>)
  end

  defp doc_zip(nsu, schema, xml) do
    ~s(<docZip NSU="#{nsu}" schema="#{schema}">#{zip(xml)}</docZip>)
  end

  test "documents arrive decompressed (SEFAZ-07)" do
    nfe = ~s(<procNFe><NFe><infNFe Id="NFe1"><vNF>100.00</vNF></infNFe></NFe></procNFe>)
    body = response(138, "Documento localizado", doc_zip("000000000000015", "procNFe_v4.00", nfe))

    assert {:ok, page} = DistDFe.parse(body)
    assert [%DistDFe.Document{} = document] = page.documents
    assert document.xml == nfe
    assert document.nsu == "000000000000015"
    assert document.schema == "procNFe_v4.00"
  end

  test "the cursor comes back even on an empty page, so it can be persisted" do
    body = response(137, "Nenhum documento localizado", "")

    assert {:ok, page} = DistDFe.parse(body)
    assert page.documents == []
    assert page.ult_nsu == "000000000000015"
    assert page.max_nsu == "000000000000042"
    assert page.c_stat == 137
  end

  test "several documents keep their order and their own NSU" do
    documents =
      doc_zip("000000000000010", "resNFe_v1.01", "<resNFe>a</resNFe>") <>
        doc_zip("000000000000011", "procEventoNFe_v1.00", "<procEventoNFe>b</procEventoNFe>")

    assert {:ok, page} = DistDFe.parse(response(138, "ok", documents))
    assert Enum.map(page.documents, & &1.nsu) == ["000000000000010", "000000000000011"]

    assert Enum.map(page.documents, & &1.xml) == [
             "<resNFe>a</resNFe>",
             "<procEventoNFe>b</procEventoNFe>"
           ]
  end

  test "consumo indevido arrives as a page, so the caller can back off" do
    assert {:ok, page} = DistDFe.parse(response(656, "Consumo Indevido", ""))
    assert page.c_stat == 656
    assert page.x_motivo == "Consumo Indevido"
  end

  test "an undecodable document fails the page instead of vanishing" do
    body = response(138, "ok", ~s(<docZip NSU="9" schema="procNFe_v4.00">nao-e-base64!!</docZip>))

    assert {:error, {:dist_dfe, {:bad_base64, "9"}}} = DistDFe.parse(body)
  end

  test "base64 that is not gzip fails the page too" do
    payload = Base.encode64("plain text, never compressed")
    body = response(138, "ok", ~s(<docZip NSU="9" schema="x">#{payload}</docZip>))

    assert {:error, {:dist_dfe, {:bad_gzip, "9"}}} = DistDFe.parse(body)
  end

  describe "the DistDFe envelope shape" do
    test "nests nfeDadosMsg inside the operation element" do
      assert {:ok, envelope} = Envelope.wrap(:nfe_distribuicao_dfe, "<distDFeInt/>")

      assert envelope =~
               ~s(<nfeDistDFeInteresse xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeDistribuicaoDFe"><nfeDadosMsg><distDFeInt/></nfeDadosMsg></nfeDistDFeInteresse>)
    end

    test "the UF services keep nfeDadosMsg flat in the body" do
      assert {:ok, envelope} = Envelope.wrap(:nfe_status_servico, "<consStatServ/>")

      assert envelope =~ ~s(<soap:Body><nfeDadosMsg xmlns=)
      refute envelope =~ "nfeDistDFeInteresse"
    end

    test "each service carries its own SOAPAction" do
      assert {:ok,
              "http://www.portalfiscal.inf.br/nfe/wsdl/NFeDistribuicaoDFe/nfeDistDFeInteresse"} =
               Envelope.action(:nfe_distribuicao_dfe)

      assert {:ok, "http://www.portalfiscal.inf.br/nfe/wsdl/NFeStatusServico4/nfeStatusServicoNF"} =
               Envelope.action(:nfe_status_servico)

      assert {:error, {:unknown_service, :nope}} = Envelope.action(:nope)
    end
  end

  describe "the distDFeInt envelope" do
    test "an NSU cursor is padded to fifteen digits" do
      message = Envelope.dist_dfe("00000000000191", 91, 2, {:ult_nsu, "15"})

      assert message =~ "<distNSU><ultNSU>000000000000015</ultNSU></distNSU>"
      assert message =~ "<CNPJ>00000000000191</CNPJ>"
      assert message =~ "<cUFAutor>91</cUFAutor>"
    end

    test "a CPF is sent as CPF, not as a short CNPJ" do
      assert Envelope.dist_dfe("00000000191", 91, 2, {:ult_nsu, "0"}) =~ "<CPF>00000000191</CPF>"
    end

    test "the other two query types have their own elements" do
      assert Envelope.dist_dfe("00000000000191", 91, 2, {:nsu, "7"}) =~
               "<consNSU><NSU>000000000000007</NSU></consNSU>"

      key = String.duplicate("1", 44)

      assert Envelope.dist_dfe("00000000000191", 91, 2, {:ch_nfe, key}) =~
               "<consChNFe><chNFe>#{key}</chNFe></consChNFe>"
    end
  end
end
