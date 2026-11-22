defmodule SefazNfe.ProcAssemblyTest do
  @moduledoc """
  `SefazNfe.Proc` on hand-built answers shaped like SEFAZ's. The parts are
  spliced verbatim, so every case compares bytes, not just content.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.Proc
  alias SefazNfe.Result
  alias SefazNfe.XML

  @ns "http://www.portalfiscal.inf.br/nfe"
  @key "35260100000000000191550010000000011000000017"
  @other_key "35260100000000000191550010000000021000000024"
  @declaration ~s(<?xml version="1.0" encoding="UTF-8"?>)

  @signature ~s(<Signature xmlns="http://www.w3.org/2000/09/xmldsig#">) <>
               ~s(<SignedInfo><Reference URI="#NFe#{@key}"><DigestValue>DIGEST=</DigestValue></Reference></SignedInfo>) <>
               ~s(<SignatureValue>abc</SignatureValue></Signature>)

  @nfe ~s(<NFe xmlns="#{@ns}"><infNFe Id="NFe#{@key}" versao="4.00">) <>
         ~s(<total><vNF>100.00</vNF></total></infNFe>#{@signature}</NFe>)
  @signed_nfe @declaration <> @nfe

  defp envelope(inner),
    do:
      ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
        inner <> ~s(</soap:Body></soap:Envelope>)

  defp prot(opts \\ []) do
    key = Keyword.get(opts, :key, @key)
    c_stat = Keyword.get(opts, :c_stat, 100)
    digest = Keyword.get(opts, :digest, "DIGEST=")

    ~s(<protNFe versao="4.00"><infProt Id="ID135260000000001"><tpAmb>2</tpAmb><verAplic>SP_NFE_PL_009</verAplic>) <>
      ~s(<chNFe>#{key}</chNFe><dhRecbto>2026-09-07T10:00:05-03:00</dhRecbto><nProt>135260000000001</nProt>) <>
      if(digest, do: ~s(<digVal>#{digest}</digVal>), else: "") <>
      ~s(<cStat>#{c_stat}</cStat><xMotivo>Autorizado o uso da NF-e</xMotivo></infProt></protNFe>)
  end

  defp authorization(protocols) do
    envelope(
      ~s(<retEnviNFe xmlns="#{@ns}" versao="4.00"><tpAmb>2</tpAmb><cStat>104</cStat>) <>
        ~s(<xMotivo>Lote processado</xMotivo>#{protocols}</retEnviNFe>)
    )
  end

  # -- nfeProc ----------------------------------------------------------------

  describe "nfe_proc/2" do
    test "is the signed NFe followed by protNFe, both byte for byte" do
      protocol = prot()
      assert {:ok, proc} = Proc.nfe_proc(@signed_nfe, authorization(protocol))

      assert proc ==
               @declaration <>
                 ~s(<nfeProc xmlns="#{@ns}" versao="4.00">) <>
                 @nfe <> protocol <> "</nfeProc>"

      assert {:ok, _doc} = XML.parse(proc)
    end

    test "takes the bare protNFe too" do
      assert {:ok, proc} = Proc.nfe_proc(@signed_nfe, prot())
      assert proc =~ "<nProt>135260000000001</nProt>"
    end

    test "picks the protocol of this document out of a batch" do
      other = prot(key: @other_key)
      mine = prot()

      assert {:ok, proc} = Proc.nfe_proc(@signed_nfe, authorization(other <> mine))
      assert String.contains?(proc, mine)
      refute String.contains?(proc, other)
    end

    test "a document without DigestValue, or a protocol without digVal, is joined on the key" do
      assert {:ok, _proc} = Proc.nfe_proc(@signed_nfe, authorization(prot(digest: nil)))

      unsigned = String.replace(@signed_nfe, ~r{<Signature.*</Signature>}s, "")
      assert {:ok, _proc} = Proc.nfe_proc(unsigned, authorization(prot()))
    end

    test "denied documents are archived too" do
      for c_stat <- [110, 205, 301, 302, 303, 150, 120] do
        assert {:ok, _proc} = Proc.nfe_proc(@signed_nfe, authorization(prot(c_stat: c_stat)))
      end
    end

    test "errors" do
      receipt =
        envelope(
          ~s(<retEnviNFe xmlns="#{@ns}"><cStat>103</cStat><infRec><nRec>1</nRec></infRec></retEnviNFe>)
        )

      assert Proc.nfe_proc(@signed_nfe, receipt) == {:error, :no_protocol}

      assert Proc.nfe_proc(@signed_nfe, authorization(prot(key: @other_key))) ==
               {:error, :key_mismatch}

      assert Proc.nfe_proc(@signed_nfe, authorization(prot(digest: "OTHER="))) ==
               {:error, :digest_mismatch}

      assert Proc.nfe_proc(@signed_nfe, authorization(prot(c_stat: 204))) ==
               {:error, {:not_accepted, 204}}

      assert Proc.nfe_proc("<NFe/>", authorization(prot())) == {:error, :no_inf_nfe}
      assert Proc.nfe_proc("nope", authorization(prot())) == {:error, {:xml, :malformed}}
    end

    test "Result.proc/2 is the same thing, with nil for an error" do
      assert Result.proc(@signed_nfe, authorization(prot())) ==
               elem(Proc.nfe_proc(@signed_nfe, authorization(prot())), 1)

      assert Result.proc(@signed_nfe, authorization(prot(key: @other_key))) == nil
    end
  end

  # -- procEventoNFe ----------------------------------------------------------

  defp event(opts \\ []) do
    key = Keyword.get(opts, :key, @key)
    tp = Keyword.get(opts, :tp_evento, "110111")

    ~s(<evento xmlns="#{@ns}" versao="1.00"><infEvento Id="ID#{tp}#{key}01"><cOrgao>35</cOrgao><tpAmb>2</tpAmb>) <>
      ~s(<CNPJ>00000000000191</CNPJ><chNFe>#{key}</chNFe><dhEvento>2026-09-07T10:10:00-03:00</dhEvento>) <>
      ~s(<tpEvento>#{tp}</tpEvento><nSeqEvento>1</nSeqEvento><verEvento>1.00</verEvento>) <>
      ~s(<detEvento versao="1.00"><descEvento>Cancelamento</descEvento><nProt>135260000000001</nProt>) <>
      ~s(<xJust>Justificativa de teste do cancelamento</xJust></detEvento></infEvento>#{@signature}</evento>)
  end

  defp ret_evento(opts \\ []) do
    key = Keyword.get(opts, :key, @key)
    tp = Keyword.get(opts, :tp_evento, "110111")
    c_stat = Keyword.get(opts, :c_stat, 135)

    ~s(<retEvento versao="1.00"><infEvento><tpAmb>2</tpAmb><verAplic>SP_EVENTOS_PL_100</verAplic>) <>
      ~s(<cOrgao>35</cOrgao><cStat>#{c_stat}</cStat><xMotivo>Evento registrado e vinculado a NF-e</xMotivo>) <>
      ~s(<chNFe>#{key}</chNFe><tpEvento>#{tp}</tpEvento><xEvento>Cancelamento registrado</xEvento>) <>
      ~s(<nSeqEvento>1</nSeqEvento><CNPJDest>99999999000191</CNPJDest>) <>
      ~s(<dhRegEvento>2026-09-07T10:10:02-03:00</dhRegEvento><nProt>135260000000002</nProt></infEvento></retEvento>)
  end

  defp event_answer(returns) do
    envelope(
      ~s(<retEnvEvento xmlns="#{@ns}" versao="1.00"><idLote>1</idLote><tpAmb>2</tpAmb>) <>
        ~s(<cStat>128</cStat><xMotivo>Lote de Evento Processado</xMotivo>#{returns}</retEnvEvento>)
    )
  end

  describe "event_proc/2" do
    test "is the signed evento followed by retEvento, both byte for byte" do
      event = event()
      ret = ret_evento()

      assert {:ok, proc} = Proc.event_proc(@declaration <> event, event_answer(ret))

      assert proc ==
               @declaration <>
                 ~s(<procEventoNFe xmlns="#{@ns}" versao="1.00">) <>
                 event <> ret <> "</procEventoNFe>"

      assert {:ok, _doc} = XML.parse(proc)
    end

    test "takes the evento out of an envEvento" do
      event = event()

      envelope =
        ~s(<envEvento xmlns="#{@ns}" versao="1.00"><idLote>1</idLote>#{event}</envEvento>)

      assert {:ok, proc} = Proc.event_proc(envelope, event_answer(ret_evento()))
      assert String.contains?(proc, event)
      refute proc =~ "envEvento"
    end

    test "picks the retEvento of this event out of several" do
      other = ret_evento(key: @other_key)
      mine = ret_evento()

      assert {:ok, proc} = Proc.event_proc(event(), event_answer(other <> mine))
      assert String.contains?(proc, mine)
      refute String.contains?(proc, other)
    end

    test "cStat 136 registers any event, 155 only a cancellation" do
      assert {:ok, _proc} = Proc.event_proc(event(), event_answer(ret_evento(c_stat: 136)))
      assert {:ok, _proc} = Proc.event_proc(event(), event_answer(ret_evento(c_stat: 155)))

      cce = event(tp_evento: "110110")

      assert {:error, {:not_accepted, 155}} =
               Proc.event_proc(cce, event_answer(ret_evento(tp_evento: "110110", c_stat: 155)))

      assert {:ok, _proc} =
               Proc.event_proc(cce, event_answer(ret_evento(tp_evento: "110110", c_stat: 135)))
    end

    test "errors" do
      assert Proc.event_proc(event(), event_answer("")) == {:error, :no_event_return}

      assert Proc.event_proc(event(), event_answer(ret_evento(key: @other_key))) ==
               {:error, :key_mismatch}

      assert Proc.event_proc(event(), event_answer(ret_evento(tp_evento: "110110"))) ==
               {:error, :key_mismatch}

      assert Proc.event_proc(event(), event_answer(ret_evento(c_stat: 573))) ==
               {:error, {:not_accepted, 573}}

      assert Proc.event_proc("<other/>", event_answer(ret_evento())) == {:error, :no_event}
    end
  end

  # -- procInutNFe ------------------------------------------------------------

  @inut ~s(<inutNFe xmlns="#{@ns}" versao="4.00"><infInut Id="ID35260000000001910550010000000010000000010">) <>
          ~s(<tpAmb>2</tpAmb><xServ>INUTILIZAR</xServ><cUF>35</cUF><ano>26</ano><CNPJ>00000000000191</CNPJ>) <>
          ~s(<mod>55</mod><serie>1</serie><nNFIni>1</nNFIni><nNFFin>10</nNFFin>) <>
          ~s(<xJust>Numeracao pulada por falha</xJust></infInut>#{@signature}</inutNFe>)

  defp ret_inut(changes \\ []) do
    fields =
      Map.merge(
        %{
          "tpAmb" => "2",
          "cUF" => "35",
          "ano" => "26",
          "CNPJ" => "00000000000191",
          "mod" => "55",
          "serie" => "1",
          "nNFIni" => "1",
          "nNFFin" => "10",
          "cStat" => "102"
        },
        Map.new(changes, fn {key, value} -> {to_string(key), value} end)
      )

    body =
      ~s(<retInutNFe versao="4.00"><infInut><tpAmb>#{fields["tpAmb"]}</tpAmb><verAplic>SP_NFE_PL_009</verAplic>) <>
        ~s(<cStat>#{fields["cStat"]}</cStat><xMotivo>Inutilizacao de numero homologado</xMotivo>) <>
        ~s(<cUF>#{fields["cUF"]}</cUF><ano>#{fields["ano"]}</ano><CNPJ>#{fields["CNPJ"]}</CNPJ>) <>
        ~s(<mod>#{fields["mod"]}</mod><serie>#{fields["serie"]}</serie><nNFIni>#{fields["nNFIni"]}</nNFIni>) <>
        ~s(<nNFFin>#{fields["nNFFin"]}</nNFFin><dhRecbto>2026-09-07T10:20:00-03:00</dhRecbto>) <>
        ~s(<nProt>135260000000003</nProt></infInut></retInutNFe>)

    {body, envelope(body)}
  end

  describe "void_proc/2" do
    test "is the signed inutNFe followed by retInutNFe, both byte for byte" do
      {ret, answer} = ret_inut()

      assert {:ok, proc} = Proc.void_proc(@declaration <> @inut, answer)

      assert proc ==
               @declaration <>
                 ~s(<procInutNFe xmlns="#{@ns}" versao="4.00">) <>
                 @inut <> ret <> "</procInutNFe>"

      assert {:ok, _doc} = XML.parse(proc)
    end

    test "errors" do
      {_ret, rejected} = ret_inut(cStat: "241")
      assert Proc.void_proc(@inut, rejected) == {:error, {:not_accepted, 241}}

      assert Proc.void_proc(@inut, envelope("<other/>")) == {:error, :no_void_return}
      assert Proc.void_proc("<other/>", elem(ret_inut(), 1)) == {:error, :no_inut}

      for {change, field} <- [
            {[nNFFin: "11"], :n_nf_fin},
            {[nNFIni: "2"], :n_nf_ini},
            {[serie: "2"], :serie},
            {[mod: "65"], :mod},
            {[ano: "25"], :ano},
            {[tpAmb: "1"], :tp_amb},
            {[CNPJ: "99999999000191"], :tax_id}
          ] do
        {_ret, answer} = ret_inut(change)
        assert Proc.void_proc(@inut, answer) == {:error, {:mismatch, field}}
      end
    end

    test "a version that differs is a mismatch" do
      {_ret, answer} = ret_inut()

      answer =
        String.replace(answer, ~s(<retInutNFe versao="4.00">), ~s(<retInutNFe versao="3.10">))

      assert Proc.void_proc(@inut, answer) == {:error, {:mismatch, :versao}}
    end
  end

  # -- cancel_register --------------------------------------------------------

  describe "cancel_register/2" do
    setup do
      {:ok, nfe_proc} = Proc.nfe_proc(@signed_nfe, authorization(prot()))
      %{nfe_proc: nfe_proc}
    end

    test "appends the cancellation's retEvento after the protocol, byte for byte", %{
      nfe_proc: nfe_proc
    } do
      ret = ret_evento()

      assert {:ok, registered} = Proc.cancel_register(nfe_proc, event_answer(ret))

      assert registered == String.replace(nfe_proc, "</nfeProc>", ret <> "</nfeProc>")
      assert {:ok, _doc} = XML.parse(registered)
    end

    test "takes the procEventoNFe as well, and is idempotent", %{nfe_proc: nfe_proc} do
      {:ok, event_proc} = Proc.event_proc(event(), event_answer(ret_evento()))

      assert {:ok, registered} = Proc.cancel_register(nfe_proc, event_proc)
      assert registered =~ "<xEvento>Cancelamento registrado</xEvento>"
      assert Proc.cancel_register(registered, event_proc) == {:ok, registered}
    end

    test "cStat 135, 136 and 155 of a cancellation or of a substitution (110112)", %{
      nfe_proc: nfe_proc
    } do
      for c_stat <- [135, 136, 155], tp <- ["110111", "110112"] do
        answer = event_answer(ret_evento(c_stat: c_stat, tp_evento: tp))
        assert {:ok, _registered} = Proc.cancel_register(nfe_proc, answer)
      end
    end

    test "skips a retEvento that does not qualify for one that does", %{nfe_proc: nfe_proc} do
      other = ret_evento(key: @other_key)
      mine = ret_evento()

      assert {:ok, registered} = Proc.cancel_register(nfe_proc, event_answer(other <> mine))
      assert String.contains?(registered, mine)
      refute String.contains?(registered, other)
    end

    test "errors", %{nfe_proc: nfe_proc} do
      assert Proc.cancel_register(nfe_proc, event_answer(ret_evento(tp_evento: "110110"))) ==
               {:error, {:not_a_cancellation, "110110"}}

      assert Proc.cancel_register(nfe_proc, event_answer(ret_evento(c_stat: 573))) ==
               {:error, {:not_accepted, 573}}

      assert Proc.cancel_register(nfe_proc, event_answer(ret_evento(key: @other_key))) ==
               {:error, :key_mismatch}

      assert Proc.cancel_register(nfe_proc, event_answer("")) == {:error, :no_event_return}

      assert Proc.cancel_register(@signed_nfe, event_answer(ret_evento())) ==
               {:error, :no_protocol}

      assert Proc.cancel_register(
               String.replace(nfe_proc, "</nfeProc>", "</other>"),
               event_answer(ret_evento())
             ) == {:error, :not_an_nfe_proc}
    end
  end
end
