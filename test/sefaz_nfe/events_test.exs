defmodule SefazNfe.EventsTest do
  use ExUnit.Case, async: true

  alias SefazNfe.Events
  alias SefazNfe.Fixtures
  alias SefazNfe.Signer

  @ch String.duplicate("1", 44)
  @cnpj "00000000000191"

  defp base do
    %{ch_nfe: @ch, tax_id: @cnpj, uf_code: 35, tp_amb: 2, timestamp: "2026-09-07T10:00:00-03:00"}
  end

  describe "cancel" do
    test "the Id follows the MOC: code, key, two digit sequence" do
      event =
        Events.cancel(
          Map.merge(base(), %{n_prot: "135", justification: String.duplicate("a", 20)})
        )

      assert event =~ ~s(<infEvento Id="ID110111#{@ch}01">)
      assert event =~ "<tpEvento>110111</tpEvento>"
      assert event =~ "<nSeqEvento>1</nSeqEvento>"
      assert event =~ "<nProt>135</nProt>"
    end

    test "the justification is escaped, not injected" do
      event = Events.cancel(Map.merge(base(), %{n_prot: "1", justification: ~s(a & b <c>)}))

      assert event =~ "<xJust>a &amp; b &lt;c&gt;</xJust>"
      refute event =~ "<c>"
    end

    test "a cancel event signs on its own infEvento" do
      event =
        Events.cancel(Map.merge(base(), %{n_prot: "1", justification: String.duplicate("a", 20)}))

      assert {:ok, signed} = Signer.sign(event, Fixtures.cert(), "infEvento", "evento")
      assert signed =~ ~s(<Reference URI="#ID110111#{@ch}01">)
      assert String.ends_with?(signed, "</Signature></evento>")
    end
  end

  describe "correction" do
    test "carries the fixed legal text SEFAZ compares verbatim" do
      event = Events.correction(Map.merge(base(), %{correction: "corrigindo o endereco"}))

      assert event =~ "<tpEvento>110110</tpEvento>"
      assert event =~ "<xCorrecao>corrigindo o endereco</xCorrecao>"

      assert event =~
               "<xCondUso>A Carta de Correcao e disciplinada pelo paragrafo 1o-A do art. 7o"
    end

    test "the sequence goes into the Id, so corrections do not collide" do
      event = Events.correction(Map.merge(base(), %{correction: "x", sequence: 3}))

      assert event =~ ~s(Id="ID110110#{@ch}03")
      assert event =~ "<nSeqEvento>3</nSeqEvento>"
    end
  end

  describe "void_numbers" do
    test "the Id packs UF, year, CNPJ, model, series and the range" do
      message =
        Events.void_numbers(%{
          tax_id: @cnpj,
          uf_code: 35,
          tp_amb: 2,
          year: 2026,
          model: 55,
          serie: 1,
          n_ini: 10,
          n_fim: 20,
          justification: String.duplicate("a", 20)
        })

      assert message =~ ~s(<infInut Id="ID3526#{@cnpj}55001000000010000000020">)
      assert message =~ "<xServ>INUTILIZAR</xServ>"
      assert message =~ "<nNFIni>10</nNFIni><nNFFin>20</nNFFin>"
    end

    test "it signs on infInut, inside inutNFe" do
      message =
        Events.void_numbers(%{
          tax_id: @cnpj,
          uf_code: 35,
          tp_amb: 2,
          serie: 1,
          n_ini: 1,
          n_fim: 1,
          model: 55,
          justification: String.duplicate("a", 20)
        })

      assert {:ok, signed} = Signer.sign(message, Fixtures.cert(), "infInut", "inutNFe")
      assert String.ends_with?(signed, "</Signature></inutNFe>")
    end
  end
end
