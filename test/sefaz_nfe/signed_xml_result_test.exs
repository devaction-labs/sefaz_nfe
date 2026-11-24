defmodule SefazNfe.SignedXmlResultTest do
  @moduledoc """
  `:signed_xml` on `authorization_result/1` and `consult_protocol/1`, and the
  raw answer in `Result.response_xml`, through a stub transport. No socket.

  `async: false` because `:sefaz_nfe, :soap` is global application environment.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.Fixtures
  alias SefazNfe.NFeBuilder
  alias SefazNfe.Signer

  @ns "http://www.portalfiscal.inf.br/nfe"

  defmodule Stub do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(_endpoint, _body, _cert, _opts) do
      send(:sefaz_nfe_signed_xml_result_test, :called)
      {:ok, Application.fetch_env!(:sefaz_nfe, :stub_answer)}
    end
  end

  setup do
    previous = Application.get_env(:sefaz_nfe, :soap)
    Process.register(self(), :sefaz_nfe_signed_xml_result_test)
    Application.put_env(:sefaz_nfe, :soap, Stub)

    on_exit(fn ->
      Application.put_env(:sefaz_nfe, :soap, previous)
      Application.delete_env(:sefaz_nfe, :stub_answer)
    end)

    %{xml: xml, access_key: key} = NFeBuilder.build(tax_id: "00000000000191")
    {:ok, signed} = Signer.sign_nfe(xml, Fixtures.cert())
    %{signed: signed, key: key, digest: digest(signed)}
  end

  defp digest(signed),
    do: hd(Regex.run(~r{<DigestValue>([^<]*)</DigestValue>}, signed, capture: :all_but_first))

  defp envelope(inner),
    do:
      ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
        inner <> ~s(</soap:Body></soap:Envelope>)

  defp prot(key, digest, c_stat) do
    ~s(<protNFe versao="4.00"><infProt><tpAmb>2</tpAmb><verAplic>SP_NFE</verAplic>) <>
      ~s(<chNFe>#{key}</chNFe><dhRecbto>2026-09-07T10:00:05-03:00</dhRecbto>) <>
      ~s(<nProt>135260000000001</nProt><digVal>#{digest}</digVal><cStat>#{c_stat}</cStat>) <>
      ~s(<xMotivo>Autorizado</xMotivo></infProt></protNFe>)
  end

  defp receipt(key, digest, c_stat \\ 100) do
    envelope(
      ~s(<retConsReciNFe xmlns="#{@ns}" versao="4.00"><tpAmb>2</tpAmb><nRec>351000000000001</nRec>) <>
        ~s(<cStat>104</cStat><xMotivo>Lote processado</xMotivo>) <>
        prot(key, digest, c_stat) <> ~s(</retConsReciNFe>)
    )
  end

  defp consult(key, digest, extra \\ "") do
    envelope(
      ~s(<retConsSitNFe xmlns="#{@ns}" versao="4.00"><tpAmb>2</tpAmb><cStat>100</cStat>) <>
        ~s(<xMotivo>Autorizado o uso da NF-e</xMotivo><chNFe>#{key}</chNFe>) <>
        prot(key, digest, 100) <> extra <> ~s(</retConsSitNFe>)
    )
  end

  defp cancellation(key) do
    ~s(<procEventoNFe versao="1.00"><evento versao="1.00"><infEvento Id="ID1101113#{key}01">) <>
      ~s(<tpEvento>110111</tpEvento></infEvento></evento><retEvento versao="1.00"><infEvento>) <>
      ~s(<cStat>135</cStat><xMotivo>Evento registrado</xMotivo><chNFe>#{key}</chNFe>) <>
      ~s(<tpEvento>110111</tpEvento><nProt>135260000000009</nProt></infEvento></retEvento>) <>
      ~s(</procEventoNFe>)
  end

  defp other_key(key),
    do: binary_part(key, 0, 43) <> if(String.ends_with?(key, "1"), do: "2", else: "1")

  defp base, do: %{cert: Fixtures.cert(), uf: "SP", environment: :homologation}
  defp receipt_opts, do: Map.put(base(), :n_rec, "351000000000001")
  defp consult_opts(key), do: Map.put(base(), :ch_nfe, key)

  describe "authorization_result/1" do
    test "with :signed_xml the result's :xml is the nfeProc", ctx do
      Application.put_env(:sefaz_nfe, :stub_answer, receipt(ctx.key, ctx.digest))

      assert {:ok, result} =
               SefazNfe.authorization_result(Map.put(receipt_opts(), :signed_xml, ctx.signed))

      assert result.c_stat == 100
      assert result.signed_xml == ctx.signed
      assert String.starts_with?(result.xml, ~s(<?xml version="1.0" encoding="UTF-8"?><nfeProc))
      assert result.xml =~ "<protNFe"
      assert result.xml =~ "<nProt>135260000000001</nProt>"
    end

    test "without :signed_xml the result is as before", ctx do
      Application.put_env(:sefaz_nfe, :stub_answer, receipt(ctx.key, ctx.digest))

      assert {:ok, result} = SefazNfe.authorization_result(receipt_opts())
      assert result.xml == nil
      assert result.signed_xml == nil
      assert result.n_prot == "135260000000001"
    end

    test "a digest that is not the document's leaves :xml nil", ctx do
      Application.put_env(
        :sefaz_nfe,
        :stub_answer,
        receipt(ctx.key, "AAAAAAAAAAAAAAAAAAAAAAAAAAA=")
      )

      assert {:ok, result} =
               SefazNfe.authorization_result(Map.put(receipt_opts(), :signed_xml, ctx.signed))

      assert result.xml == nil
      assert result.signed_xml == ctx.signed
    end

    test "a protocol of another key leaves :xml nil", ctx do
      other = other_key(ctx.key)
      Application.put_env(:sefaz_nfe, :stub_answer, receipt(other, ctx.digest))

      assert {:ok, result} =
               SefazNfe.authorization_result(Map.put(receipt_opts(), :signed_xml, ctx.signed))

      assert result.xml == nil
    end

    test "a :signed_xml that is not a string is refused before the network", ctx do
      Application.put_env(:sefaz_nfe, :stub_answer, receipt(ctx.key, ctx.digest))

      assert {:error, :invalid_xml} =
               SefazNfe.authorization_result(Map.put(receipt_opts(), :signed_xml, 123))

      refute_received :called
    end
  end

  describe "consult_protocol/1" do
    test "with :signed_xml the result's :xml is the nfeProc", ctx do
      Application.put_env(:sefaz_nfe, :stub_answer, consult(ctx.key, ctx.digest))

      assert {:ok, result} =
               SefazNfe.consult_protocol(Map.put(consult_opts(ctx.key), :signed_xml, ctx.signed))

      assert result.signed_xml == ctx.signed
      assert result.xml =~ "<nfeProc"
      assert result.xml =~ ctx.signed |> String.replace(~r/^\s*<\?xml[^>]*\?>/, "")
    end

    test "without :signed_xml :xml is nil", ctx do
      Application.put_env(:sefaz_nfe, :stub_answer, consult(ctx.key, ctx.digest))

      assert {:ok, result} = SefazNfe.consult_protocol(consult_opts(ctx.key))
      assert result.xml == nil
      assert result.signed_xml == nil
    end

    test "a procEventoNFe of a cancellation is not copied: only the protNFe", ctx do
      Application.put_env(
        :sefaz_nfe,
        :stub_answer,
        consult(ctx.key, ctx.digest, cancellation(ctx.key))
      )

      assert {:ok, result} =
               SefazNfe.consult_protocol(Map.put(consult_opts(ctx.key), :signed_xml, ctx.signed))

      assert result.xml =~ "<nfeProc"
      assert result.xml =~ "<protNFe"
      refute result.xml =~ "procEventoNFe"
      refute result.xml =~ "retEvento"
      refute result.xml =~ "110111"
      assert result.response_xml =~ "procEventoNFe"
    end

    test "a :signed_xml of another key is refused before the network", ctx do
      other = other_key(ctx.key)
      Application.put_env(:sefaz_nfe, :stub_answer, consult(other, ctx.digest))

      assert {:error, :signed_xml_key_mismatch} =
               SefazNfe.consult_protocol(Map.put(consult_opts(other), :signed_xml, ctx.signed))

      refute_received :called
    end

    test "a digest that is not the document's leaves :xml nil", ctx do
      Application.put_env(
        :sefaz_nfe,
        :stub_answer,
        consult(ctx.key, "AAAAAAAAAAAAAAAAAAAAAAAAAAA=")
      )

      assert {:ok, result} =
               SefazNfe.consult_protocol(Map.put(consult_opts(ctx.key), :signed_xml, ctx.signed))

      assert result.xml == nil
    end
  end

  describe "response_xml" do
    test "is the SOAP answer as received, for every operation", ctx do
      answer = consult(ctx.key, ctx.digest)
      Application.put_env(:sefaz_nfe, :stub_answer, answer)

      assert {:ok, consulted} = SefazNfe.consult_protocol(consult_opts(ctx.key))
      assert consulted.response_xml == answer

      status =
        envelope(
          ~s(<retConsStatServ xmlns="#{@ns}" versao="4.00"><tpAmb>2</tpAmb><cStat>107</cStat>) <>
            ~s(<xMotivo>Servico em Operacao</xMotivo></retConsStatServ>)
        )

      Application.put_env(:sefaz_nfe, :stub_answer, status)
      assert {:ok, service} = SefazNfe.service_status(base())
      assert service.response_xml == status
    end

    test "authorize keeps it next to :xml and :signed_xml", ctx do
      Application.put_env(:sefaz_nfe, :stub_answer, receipt(ctx.key, ctx.digest))

      assert {:ok, result} =
               SefazNfe.authorize(Map.put(base(), :xml, ctx.signed))

      assert result.response_xml == Application.fetch_env!(:sefaz_nfe, :stub_answer)
      assert result.xml =~ "<nfeProc"
    end

    test "is not in the JSON encoding", ctx do
      Application.put_env(:sefaz_nfe, :stub_answer, consult(ctx.key, ctx.digest))

      assert {:ok, result} =
               SefazNfe.consult_protocol(Map.put(consult_opts(ctx.key), :signed_xml, ctx.signed))

      json = JSON.encode!(result)
      refute json =~ "response_xml"
      refute json =~ "nfeProc"
      refute json =~ "retConsSitNFe"
    end
  end
end
