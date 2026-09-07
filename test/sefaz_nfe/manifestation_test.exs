defmodule SefazNfe.ManifestationTest do
  use ExUnit.Case, async: true

  alias SefazNfe.Events
  alias SefazNfe.Fixtures
  alias SefazNfe.Signer

  @ch String.duplicate("1", 44)
  @cnpj "00000000000191"

  defp base do
    %{ch_nfe: @ch, tax_id: @cnpj, tp_amb: 2, timestamp: "2026-09-07T10:00:00-03:00"}
  end

  test "the four MOC codes and their verbatim descriptions" do
    expected = %{
      confirmation: {"210200", "Confirmacao da Operacao"},
      awareness: {"210210", "Ciencia da Operacao"},
      unaware: {"210220", "Desconhecimento da Operacao"},
      not_performed: {"210240", "Operacao nao Realizada"}
    }

    for {type, {code, description}} <- expected do
      event =
        Events.manifestation(type, Map.put(base(), :justification, String.duplicate("a", 20)))

      assert event =~ "<tpEvento>#{code}</tpEvento>"
      assert event =~ "<descEvento>#{description}</descEvento>"
      assert event =~ ~s(Id="ID#{code}#{@ch}01")
    end
  end

  test "dhEvento is second precision, whatever the caller passes" do
    event = Events.manifestation(:awareness, Map.delete(base(), :timestamp))

    assert [_, stamp] = Regex.run(~r{<dhEvento>([^<]+)</dhEvento>}, event)
    assert String.match?(stamp, ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[-+]\d{2}:\d{2}$/)

    trimmed =
      Events.manifestation(
        :awareness,
        Map.put(base(), :timestamp, "2026-09-07T10:00:00.123456-03:00")
      )

    assert trimmed =~ "<dhEvento>2026-09-07T10:00:00-03:00</dhEvento>"
  end

  test "manifestation_types/0 lists exactly what the facade accepts" do
    assert Enum.sort(Events.manifestation_types()) ==
             [:awareness, :confirmation, :not_performed, :unaware]
  end

  test "cOrgao is 91: these are processed by the Ambiente Nacional" do
    assert Events.manifestation(:confirmation, base()) =~ "<cOrgao>91</cOrgao>"
  end

  test "only :not_performed carries a justification" do
    with_just =
      Events.manifestation(
        :not_performed,
        Map.put(base(), :justification, "motivo suficiente aqui")
      )

    assert with_just =~ "<xJust>motivo suficiente aqui</xJust>"

    for type <- [:confirmation, :awareness, :unaware] do
      refute Events.manifestation(type, base()) =~ "<xJust>"
    end
  end

  test "the event signs on its own infEvento" do
    event = Events.manifestation(:confirmation, base())

    assert {:ok, signed} = Signer.sign(event, Fixtures.cert(), "infEvento", "evento")
    assert signed =~ ~s(<Reference URI="#ID210200#{@ch}01">)
  end

  describe "the facade" do
    setup do: %{cert: Fixtures.cert()}

    test "an unknown type is refused before anything is built", %{cert: cert} do
      assert {:error, {:unknown_manifestation, :nope}} =
               SefazNfe.manifest(:nope, %{
                 ch_nfe: @ch,
                 tax_id: @cnpj,
                 cert: cert,
                 environment: :homologation
               })
    end

    test ":not_performed without a justification is refused", %{cert: cert} do
      assert {:error, {:missing_keys, [:justification]}} =
               SefazNfe.manifest(:not_performed, %{
                 ch_nfe: @ch,
                 tax_id: @cnpj,
                 cert: cert,
                 environment: :homologation
               })
    end

    test ":not_performed with a short justification is refused", %{cert: cert} do
      assert {:error, :justification_too_short} =
               SefazNfe.manifest(:not_performed, %{
                 ch_nfe: @ch,
                 tax_id: @cnpj,
                 justification: "curto",
                 cert: cert,
                 environment: :homologation
               })
    end

    test "a malformed access key never reaches the network", %{cert: cert} do
      assert {:error, :invalid_ch_nfe} =
               SefazNfe.manifest(:awareness, %{
                 ch_nfe: "123",
                 tax_id: @cnpj,
                 cert: cert,
                 environment: :homologation
               })
    end

    test "no :uf is required — the Ambiente Nacional handles these", %{cert: cert} do
      assert {:error, :not_implemented} =
               SefazNfe.manifest(:confirmation, %{
                 ch_nfe: @ch,
                 tax_id: @cnpj,
                 cert: cert,
                 environment: :homologation
               })
    end
  end
end
