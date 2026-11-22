defmodule SefazNfe.AuthorizeNfeMapTest do
  @moduledoc """
  `authorize/1` taking `:nfe`, a map, instead of `:xml`. The transport is a
  stub that records the URL and the body, so no socket is opened.

  `async: false` because `:sefaz_nfe, :soap` is global application environment.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.AccessKey
  alias SefazNfe.Endpoints
  alias SefazNfe.Fixtures
  alias SefazNfe.NFeBuilder
  alias SefazNfe.NFeMap

  defmodule Stub do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(endpoint, body, _cert, _opts) do
      send(:sefaz_nfe_authorize_map_test, {:posted, endpoint, IO.iodata_to_binary(body)})

      {:ok,
       ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
         ~s(<retStub xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">) <>
         ~s(<tpAmb>2</tpAmb><cStat>107</cStat><xMotivo>Servico em Operacao</xMotivo>) <>
         ~s(</retStub></soap:Body></soap:Envelope>)}
    end
  end

  setup do
    previous = Application.get_env(:sefaz_nfe, :soap)
    Process.register(self(), :sefaz_nfe_authorize_map_test)
    Application.put_env(:sefaz_nfe, :soap, Stub)

    on_exit(fn -> Application.put_env(:sefaz_nfe, :soap, previous) end)
    :ok
  end

  defp opts(nfe), do: %{nfe: nfe, cert: Fixtures.cert(), uf: "SP", environment: :homologation}

  # The map without what the builder generates.
  defp nfe(model) do
    key = NFeBuilder.build(model: model).access_key

    model
    |> NFeMap.document(3, key)
    |> Map.delete(:id)
    |> update_in([:ide], &Map.drop(&1, [:c_nf, :c_dv]))
  end

  defp url(model) do
    {:ok, url} = Endpoints.url("SP", :homologation, :nfe_autorizacao, model)
    url
  end

  test "an NF-e map is built, signed and sent to the NF-e endpoint" do
    assert {:ok, result} = SefazNfe.authorize(opts(nfe(55)))

    assert_receive {:posted, posted, body}
    assert posted == url(55)
    assert body =~ "<mod>55</mod>"
    assert body =~ "<Signature"
    assert result.signed_xml =~ "<Signature"

    [_, key] = Regex.run(~r/Id="NFe(\d{44})"/, result.signed_xml)
    assert AccessKey.valid?(key)
    assert body =~ key
  end

  test "an NFC-e map goes to the NFC-e endpoint and gets its infNFeSupl" do
    assert {:ok, result} = SefazNfe.authorize(opts(nfe(65)))

    assert_receive {:posted, posted, body}
    assert posted == url(65)
    assert body =~ "<mod>65</mod>"
    assert body =~ "<infNFeSupl>"
    assert result.signed_xml =~ "<infNFeSupl>"
  end

  test "builder errors are returned before the transport is reached" do
    bad = update_in(nfe(55), [:ide], &Map.delete(&1, :serie))

    assert {:error, {:invalid_nfe, [{[:ide, :serie], :required}]}} = SefazNfe.authorize(opts(bad))
    refute_receive {:posted, _, _}
  end

  test "a mismatching key never reaches the transport" do
    good = put_in(nfe(55), [:ide, :c_nf], "12345679")

    {:ok, key} =
      AccessKey.build(%{
        c_uf: 35,
        dh_emi: "2026-09-07T10:00:00-03:00",
        cnpj: "00000000000191",
        mod: 55,
        serie: 1,
        n_nf: 1,
        tp_emis: 1,
        c_nf: "12345679"
      })

    expected = String.last(key)
    bad = put_in(good, [:ide, :c_dv], if(expected == "9", do: "8", else: "9"))

    assert {:error, {:invalid_nfe, [{[:ide, :c_dv], {:mismatch, ^expected}}]}} =
             SefazNfe.authorize(opts(bad))

    refute_receive {:posted, _, _}
  end

  test ":xml and :nfe together are refused" do
    both = Map.put(opts(nfe(55)), :xml, "<NFe/>")

    assert {:error, {:conflicting_keys, [:xml, :nfe]}} = SefazNfe.authorize(both)
    refute_receive {:posted, _, _}
  end
end
