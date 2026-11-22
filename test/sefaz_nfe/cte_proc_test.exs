defmodule SefazNfe.CTeProcTest do
  @moduledoc """
  `SefazNfe.CTe.Proc`: `cteProc`/`cteOSProc`, `procEventoCTe` and the
  cancellation register. The bytes of the signed document and of SEFAZ's answer
  survive unchanged, and an answer is only joined to the document it is about.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.CTe.Events
  alias SefazNfe.CTe.Proc
  alias SefazNfe.CTeWire
  alias SefazNfe.Fixtures
  alias SefazNfe.Signer

  @pl System.get_env("SEFAZ_NFE_CTE_PL_PATH")
  @skip if(
          System.find_executable("xmllint") != nil and is_binary(@pl) and
            File.exists?(Path.join(@pl || "", "procCTe_v4.00.xsd")),
          do: false,
          else: "SEFAZ_NFE_CTE_PL_PATH or xmllint is not available"
        )

  setup_all do
    {:ok, cte: CTeWire.signed(:cte), os: CTeWire.signed(:cte_os)}
  end

  defp signed_event(key, kind, extra \\ %{}) do
    opts =
      Map.merge(
        %{
          ch_cte: key,
          tax_id: "00000000000191",
          uf_code: 29,
          tp_amb: 2,
          timestamp: "2026-09-07T10:05:00-03:00",
          n_prot: "129260000000001",
          justification: "Erro de digitacao no valor",
          corrections: [%{grupo_alterado: "ide", campo_alterado: "xObs", valor_alterado: "x"}]
        },
        extra
      )

    {:ok, signed} =
      Signer.sign(apply(Events, kind, [opts]), Fixtures.cert(), "infEvento", "eventoCTe")

    signed
  end

  defp xmllint(xml, xsd) do
    path = Path.join(System.tmp_dir!(), "cte_proc_#{System.unique_integer([:positive])}.xml")
    File.write!(path, xml)

    try do
      System.cmd("xmllint", ["--noout", "--schema", Path.join(@pl, xsd), path],
        stderr_to_stdout: true
      )
    after
      File.rm(path)
    end
  end

  describe "cte_proc/2" do
    test "joins the signed CT-e and the protocol, both verbatim", %{cte: cte} do
      response = CTeWire.answer(cte.xml)

      assert {:ok, proc} = Proc.cte_proc(cte.xml, response)

      [protocol] = Regex.run(~r|<protCTe.*</protCTe>|s, response)

      assert proc ==
               ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
                 ~s(<cteProc xmlns="http://www.portalfiscal.inf.br/cte" versao="4.00">) <>
                 cte.xml <> protocol <> "</cteProc>"

      assert {:ok, _doc} = SefazNfe.XML.parse(proc)
    end

    test "the inner document keeps no XML declaration of its own", %{cte: cte} do
      declared = ~s(<?xml version="1.0" encoding="UTF-8"?>) <> cte.xml

      assert {:ok, proc} = Proc.cte_proc(declared, CTeWire.answer(cte.xml))
      assert length(String.split(proc, "<?xml")) == 2
    end

    test "a CT-e OS becomes a cteOSProc", %{os: os} do
      assert {:ok, proc} = Proc.cte_proc(os.xml, CTeWire.answer(os.xml))

      assert String.starts_with?(
               proc,
               ~s(<?xml version="1.0" encoding="UTF-8"?><cteOSProc xmlns="http://www.portalfiscal.inf.br/cte" versao="4.00"><CTeOS)
             )

      assert String.ends_with?(proc, "</cteOSProc>")
    end

    test "the answer may be the SOAP envelope, the retCTe or the protCTe", %{cte: cte} do
      soap = CTeWire.answer(cte.xml)
      [ret] = Regex.run(~r|<retCTe.*</retCTe>|s, soap)
      [protocol] = Regex.run(~r|<protCTe.*</protCTe>|s, soap)

      assert {:ok, a} = Proc.cte_proc(cte.xml, soap)
      assert {:ok, ^a} = Proc.cte_proc(cte.xml, ret)
      assert {:ok, ^a} = Proc.cte_proc(cte.xml, protocol)
    end

    test "a denied CT-e is archived too: 110 and 301, but 301 never for a CT-e OS", %{
      cte: cte,
      os: os
    } do
      for c_stat <- [100, 150, 110, 205, 301] do
        assert {:ok, _proc} = Proc.cte_proc(cte.xml, CTeWire.answer(cte.xml, c_stat: c_stat))
      end

      assert {:ok, _proc} = Proc.cte_proc(os.xml, CTeWire.answer(os.xml, c_stat: 110))

      assert {:error, {:not_accepted, 301}} =
               Proc.cte_proc(os.xml, CTeWire.answer(os.xml, c_stat: 301))
    end

    test "SEFAZ did not accept it", %{cte: cte} do
      assert {:error, {:not_accepted, 539}} =
               Proc.cte_proc(cte.xml, CTeWire.answer(cte.xml, c_stat: 539))

      assert {:error, :no_protocol} =
               Proc.cte_proc(cte.xml, CTeWire.answer(cte.xml, protocol: false))

      assert {:error, :no_protocol} = Proc.cte_proc(cte.xml, CTeWire.rejection(215))
    end

    test "an answer about another document", %{cte: cte, os: os} do
      assert {:error, :key_mismatch} = Proc.cte_proc(cte.xml, CTeWire.answer(os.xml))

      assert {:error, :digest_mismatch} =
               Proc.cte_proc(cte.xml, CTeWire.answer(cte.xml, digest: "AAAA"))
    end

    test "a protocol without digVal is not held to the digest", %{cte: cte} do
      response = String.replace(CTeWire.answer(cte.xml), ~r|<digVal>[^<]*</digVal>|, "")
      assert {:ok, _proc} = Proc.cte_proc(cte.xml, response)
    end

    test "a document without infCte, and anything that is not XML" do
      assert {:error, :no_inf_cte} = Proc.cte_proc("<CTe/>", "<protCTe/>")
      assert {:error, {:xml, _reason}} = Proc.cte_proc("not xml", "<protCTe/>")
    end

    @tag skip: @skip
    test "the cteProc and its parts are valid against the CT-e schemas", %{cte: cte, os: os} do
      for {document, xsd} <- [{cte, "procCTe_v4.00.xsd"}, {os, "procCTeOS_v4.00.xsd"}] do
        answer = CTeWire.answer(document.xml)
        {:ok, proc} = Proc.cte_proc(document.xml, answer)
        [ret] = Regex.run(~r|<retCTe(?:OS)?.*</retCTe(?:OS)?>|s, answer)

        assert {_out, 0} = xmllint(proc, xsd)

        assert {_out, 0} =
                 xmllint(
                   ret,
                   if(document == os, do: "retCTeOS_v4.00.xsd", else: "retCTe_v4.00.xsd")
                 )
      end
    end
  end

  describe "cte_event_proc/2" do
    test "joins the signed eventoCTe and the retEventoCTe, both verbatim", %{cte: cte} do
      signed = signed_event(cte.key, :cancel)
      response = CTeWire.event_answer(signed)

      assert {:ok, proc} = Proc.cte_event_proc(signed, response)
      [returned] = Regex.run(~r|<retEventoCTe.*</retEventoCTe>|s, response)

      assert proc ==
               ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
                 ~s(<procEventoCTe xmlns="http://www.portalfiscal.inf.br/cte" versao="4.00">) <>
                 signed <> returned <> "</procEventoCTe>"
    end

    test "134, 135 and 136 for any event; 155 only for a cancellation", %{cte: cte} do
      cancel = signed_event(cte.key, :cancel)
      correction = signed_event(cte.key, :correction)

      for c_stat <- [134, 135, 136] do
        assert {:ok, _} =
                 Proc.cte_event_proc(cancel, CTeWire.event_answer(cancel, c_stat: c_stat))

        assert {:ok, _} =
                 Proc.cte_event_proc(correction, CTeWire.event_answer(correction, c_stat: c_stat))
      end

      assert {:ok, _} = Proc.cte_event_proc(cancel, CTeWire.event_answer(cancel, c_stat: 155))

      assert {:error, {:not_accepted, 155}} =
               Proc.cte_event_proc(correction, CTeWire.event_answer(correction, c_stat: 155))

      assert {:error, {:not_accepted, 494}} =
               Proc.cte_event_proc(cancel, CTeWire.event_answer(cancel, c_stat: 494))
    end

    test "only the answer to this event", %{cte: cte} do
      cancel = signed_event(cte.key, :cancel)

      assert {:error, :key_mismatch} =
               Proc.cte_event_proc(cancel, CTeWire.event_answer(cancel, key: CTeWire.key(67)))

      assert {:error, :key_mismatch} =
               Proc.cte_event_proc(cancel, CTeWire.event_answer(cancel, tp_evento: "110110"))

      assert {:error, :no_event_return} = Proc.cte_event_proc(cancel, CTeWire.rejection(215))
      assert {:error, :no_event} = Proc.cte_event_proc("<other/>", "<retEventoCTe/>")
    end

    @tag skip: @skip
    test "the procEventoCTe and the answer are valid against the CT-e schemas", %{cte: cte} do
      for kind <- [:cancel, :correction] do
        signed = signed_event(cte.key, kind)
        answer = CTeWire.event_answer(signed)
        {:ok, proc} = Proc.cte_event_proc(signed, answer)
        [ret] = Regex.run(~r|<retEventoCTe.*</retEventoCTe>|s, answer)

        assert {_out, 0} = xmllint(proc, "procEventoCTe_v4.00.xsd")
        assert {_out, 0} = xmllint(ret, "retEventoCTe_v4.00.xsd")
      end
    end
  end

  describe "cte_cancel_register/2" do
    setup %{cte: cte} do
      {:ok, cte_proc} = Proc.cte_proc(cte.xml, CTeWire.answer(cte.xml))
      cancel = signed_event(cte.key, :cancel)
      {:ok, cte_proc: cte_proc, cancel: cancel}
    end

    test "appends the retEventoCTe after the protCTe", %{cte_proc: cte_proc, cancel: cancel} do
      response = CTeWire.event_answer(cancel)
      [returned] = Regex.run(~r|<retEventoCTe.*</retEventoCTe>|s, response)

      assert {:ok, registered} = Proc.cte_cancel_register(cte_proc, response)
      assert registered == String.replace_suffix(cte_proc, "</cteProc>", returned <> "</cteProc>")
    end

    test "registering the same answer twice changes nothing", %{
      cte_proc: cte_proc,
      cancel: cancel
    } do
      response = CTeWire.event_answer(cancel)

      assert {:ok, once} = Proc.cte_cancel_register(cte_proc, response)
      assert {:ok, ^once} = Proc.cte_cancel_register(once, response)
    end

    test "the procEventoCTe is accepted as the answer", %{cte_proc: cte_proc, cancel: cancel} do
      {:ok, event_proc} = Proc.cte_event_proc(cancel, CTeWire.event_answer(cancel))
      assert {:ok, registered} = Proc.cte_cancel_register(cte_proc, event_proc)
      assert registered =~ "<retEventoCTe"
    end

    test "a CT-e OS proc takes the cancellation too", %{os: os} do
      {:ok, os_proc} = Proc.cte_proc(os.xml, CTeWire.answer(os.xml))
      cancel = signed_event(os.key, :cancel)

      assert {:ok, registered} = Proc.cte_cancel_register(os_proc, CTeWire.event_answer(cancel))
      assert String.ends_with?(registered, "</retEventoCTe></cteOSProc>")
    end

    test "only an accepted cancellation of this CT-e", %{
      cte: cte,
      cte_proc: cte_proc,
      cancel: cancel
    } do
      correction = signed_event(cte.key, :correction)

      assert {:error, {:not_a_cancellation, "110110"}} =
               Proc.cte_cancel_register(cte_proc, CTeWire.event_answer(correction))

      assert {:error, {:not_accepted, 494}} =
               Proc.cte_cancel_register(cte_proc, CTeWire.event_answer(cancel, c_stat: 494))

      assert {:error, :key_mismatch} =
               Proc.cte_cancel_register(
                 cte_proc,
                 CTeWire.event_answer(cancel, key: CTeWire.key(67))
               )

      assert {:error, :no_event_return} =
               Proc.cte_cancel_register(cte_proc, CTeWire.rejection(215))
    end

    test "something that is not a cteProc", %{cte: cte, cancel: cancel} do
      assert {:error, :no_protocol} =
               Proc.cte_cancel_register(cte.xml, CTeWire.event_answer(cancel))

      assert {:error, :not_a_cte_proc} =
               Proc.cte_cancel_register(
                 "<x><protCTe></protCTe></x>",
                 CTeWire.event_answer(cancel)
               )
    end
  end
end
