defmodule SefazNfe.ContingencyTest do
  @moduledoc """
  SVC-AN / SVC-RS routing (AD-005: only ever on the caller's say-so). The
  transport is a stub that records the URL and body, so no socket is opened.

  `async: false` because `:sefaz_nfe, :soap` is global application environment.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.Endpoints
  alias SefazNfe.Fixtures
  alias SefazNfe.NFeBuilder

  defmodule Stub do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(endpoint, body, _cert, opts) do
      send(:sefaz_nfe_contingency_test, {:posted, endpoint, IO.iodata_to_binary(body), opts})

      {:ok,
       ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
         ~s(<retStub xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">) <>
         ~s(<tpAmb>2</tpAmb><cStat>107</cStat><xMotivo>Servico em Operacao</xMotivo>) <>
         ~s(</retStub></soap:Body></soap:Envelope>)}
    end
  end

  setup do
    previous = Application.get_env(:sefaz_nfe, :soap)
    Process.register(self(), :sefaz_nfe_contingency_test)
    Application.put_env(:sefaz_nfe, :soap, Stub)

    on_exit(fn -> Application.put_env(:sefaz_nfe, :soap, previous) end)
    :ok
  end

  @codes %{"BA" => 29, "SP" => 35, "MA" => 21}

  defp base(uf), do: %{cert: Fixtures.cert(), uf: uf, environment: :homologation}

  defp nfe(uf, opts) do
    NFeBuilder.build([uf: uf, uf_code: Map.fetch!(@codes, uf)] ++ opts)
  end

  defp url(authorizer_or_uf, service) when authorizer_or_uf in [:svc_an, :svc_rs] do
    {:ok, url} = Endpoints.contingency_url(authorizer_or_uf, :homologation, service)
    url
  end

  defp url(uf, service) do
    {:ok, url} = Endpoints.url(uf, :homologation, service)
    url
  end

  defp authorize(uf, opts) do
    %{xml: xml} = nfe(uf, opts)
    SefazNfe.authorize(Map.put(base(uf), :xml, xml))
  end

  describe "the data" do
    test "SVC-RS serves AM BA GO MA MS MT PE PR, SVC-AN every other UF" do
      rs = ~w(AM BA GO MA MS MT PE PR)

      snapshot = JSON.decode!(File.read!("priv/endpoints/nfe_4.00.json"))
      assert map_size(snapshot["uf_contingency"]) == 27

      for uf <- Map.keys(snapshot["uf_authorizer"]) do
        expected = if uf in rs, do: :svc_rs, else: :svc_an
        assert Endpoints.contingency_for(uf) == {:ok, expected}, uf
      end
    end

    test "contingency_for/1 normalizes and refuses what is not a UF" do
      assert {:ok, :svc_an} = Endpoints.contingency_for(:sp)
      assert {:ok, :svc_rs} = Endpoints.contingency_for("ba")
      assert {:error, {:unknown_uf, "AN"}} = Endpoints.contingency_for("AN")
      assert {:error, {:unknown_uf, "XX"}} = Endpoints.contingency_for("XX")
    end

    test "the two SVCs are distinct hosts" do
      assert url(:svc_an, :nfe_autorizacao) =~ "sefazvirtual.fazenda.gov.br"
      assert url(:svc_rs, :nfe_autorizacao) =~ "svrs.rs.gov.br"

      assert {:error, {:invalid_contingency, :nope}} =
               Endpoints.contingency_url(:nope, :homologation, :nfe_autorizacao)
    end
  end

  describe "authorize/1 by tpEmis" do
    test "tpEmis 1 keeps the origin routing" do
      assert {:ok, _} = authorize("BA", [])
      assert_receive {:posted, posted, _body, _opts}
      assert posted == url("BA", :nfe_autorizacao)
    end

    test "BA with tpEmis 7 goes to SVC-RS" do
      assert {:ok, _} = authorize("BA", tp_emis: 7)
      assert_receive {:posted, posted, body, _opts}
      assert posted == url(:svc_rs, :nfe_autorizacao)
      assert body =~ "<tpEmis>7</tpEmis>"
    end

    test "SP with tpEmis 6 goes to SVC-AN" do
      assert {:ok, _} = authorize("SP", tp_emis: 6)
      assert_receive {:posted, posted, _body, _opts}
      assert posted == url(:svc_an, :nfe_autorizacao)
    end

    test "the wrong SVC for the UF is refused, naming the right one" do
      assert {:error, {:wrong_contingency, "BA", :svc_rs}} = authorize("BA", tp_emis: 6)
      assert {:error, {:wrong_contingency, "SP", :svc_an}} = authorize("SP", tp_emis: 7)
      refute_receive {:posted, _url, _body, _opts}
    end

    test "tpEmis 4 (an EPEC NF-e coming back) goes to the ORIGIN authorizer" do
      assert {:ok, _} = authorize("SP", tp_emis: 4)
      assert_receive {:posted, posted, body, _opts}
      assert posted == url("SP", :nfe_autorizacao)
      assert body =~ "<tpEmis>4</tpEmis>"
    end

    test "FS-IA, SCAN and FS-DA are unsupported" do
      for tp_emis <- [2, 3, 5] do
        assert {:error, {:unsupported, {:tp_emis, to_string(tp_emis)}}} ==
                 authorize("SP", tp_emis: tp_emis)
      end

      refute_receive {:posted, _url, _body, _opts}
    end

    test "tpEmis 4, 6 and 7 need dhCont and xJust before the network" do
      for {uf, tp_emis} <- [{"SP", 4}, {"SP", 6}, {"BA", 7}] do
        assert {:error, {:missing_contingency_fields, [:dh_cont, :x_just]}} =
                 authorize(uf, tp_emis: tp_emis, dh_cont: nil, x_just: nil)

        assert {:error, {:missing_contingency_fields, [:dh_cont]}} =
                 authorize(uf, tp_emis: tp_emis, dh_cont: nil)

        assert {:error, {:missing_contingency_fields, [:x_just]}} =
                 authorize(uf, tp_emis: tp_emis, x_just: nil)
      end

      refute_receive {:posted, _url, _body, _opts}
    end

    test "the document goes out as built: dhCont and xJust are kept" do
      assert {:ok, result} = authorize("SP", tp_emis: 6)
      assert result.signed_xml =~ "<dhCont>2026-09-07T09:30:00-03:00</dhCont>"
      assert result.signed_xml =~ "<xJust>SEFAZ DE ORIGEM INDISPONIVEL</xJust>"
    end

    test "model 65 keeps its own behaviour: no SVC" do
      %{xml: xml} = NFeBuilder.build(model: 65, uf: "BA", uf_code: 29)

      assert {:ok, _} = SefazNfe.authorize(Map.put(base("BA"), :xml, xml))
      assert_receive {:posted, posted, _body, _opts}
      assert {:ok, ^posted} = Endpoints.url("BA", :homologation, :nfe_autorizacao, 65)
    end
  end

  describe ":contingency on the other calls" do
    test "consult_protocol routes to the SVC; absent is unchanged" do
      %{access_key: key} = nfe("BA", [])

      assert {:ok, _} = SefazNfe.consult_protocol(Map.put(base("BA"), :ch_nfe, key))
      assert_receive {:posted, origin, _body, _opts}
      assert origin == url("BA", :nfe_consulta_protocolo)

      opts = base("BA") |> Map.put(:ch_nfe, key) |> Map.put(:contingency, :svc_rs)
      assert {:ok, _} = SefazNfe.consult_protocol(opts)
      assert_receive {:posted, svc, _body, _opts}
      assert svc == url(:svc_rs, :nfe_consulta_protocolo)
      refute svc == origin
    end

    test "consult_protocol refuses the wrong SVC for the UF" do
      %{access_key: key} = nfe("BA", [])
      opts = base("BA") |> Map.put(:ch_nfe, key) |> Map.put(:contingency, :svc_an)

      assert {:error, {:wrong_contingency, "BA", :svc_rs}} = SefazNfe.consult_protocol(opts)
      refute_receive {:posted, _url, _body, _opts}
    end

    test "an unknown :contingency value is refused" do
      %{access_key: key} = nfe("BA", [])
      opts = base("BA") |> Map.put(:ch_nfe, key) |> Map.put(:contingency, :scan)

      assert {:error, {:invalid_contingency, :scan}} = SefazNfe.consult_protocol(opts)
    end

    test "the key's tpEmis digit never decides: a tpEmis 7 key without :contingency goes to origin" do
      %{access_key: key} = nfe("BA", tp_emis: 7)
      assert String.at(key, 34) == "7"

      assert {:ok, _} = SefazNfe.consult_protocol(Map.put(base("BA"), :ch_nfe, key))
      assert_receive {:posted, posted, _body, _opts}
      assert posted == url("BA", :nfe_consulta_protocolo)
    end

    test "cancel routes to the SVC's event service" do
      %{access_key: key} = nfe("SP", [])

      opts =
        base("SP")
        |> Map.merge(%{
          ch_nfe: key,
          n_prot: "135260000000001",
          justification: "cancelamento em contingencia",
          tax_id: "00000000000191",
          contingency: :svc_an
        })

      assert {:ok, _} = SefazNfe.cancel(opts)
      assert_receive {:posted, posted, body, _opts}
      assert posted == url(:svc_an, :nfe_recepcao_evento)
      assert body =~ "<tpEvento>110111</tpEvento>"
      # The author is the UF's code, as ever.
      assert body =~ "<cOrgao>35</cOrgao>"
    end

    test "cce routes to the SVC's event service" do
      %{access_key: key} = nfe("MA", [])

      opts =
        base("MA")
        |> Map.merge(%{
          ch_nfe: key,
          correction: "correcao com mais de quinze caracteres",
          tax_id: "00000000000191",
          contingency: :svc_rs
        })

      assert {:ok, _} = SefazNfe.cce(opts)
      assert_receive {:posted, posted, _body, _opts}
      assert posted == url(:svc_rs, :nfe_recepcao_evento)
    end

    test "cancel without :contingency still goes to the origin" do
      %{access_key: key} = nfe("SP", [])

      opts =
        Map.merge(base("SP"), %{
          ch_nfe: key,
          n_prot: "135260000000001",
          justification: "cancelamento normal aqui",
          tax_id: "00000000000191"
        })

      assert {:ok, _} = SefazNfe.cancel(opts)
      assert_receive {:posted, posted, _body, _opts}
      assert posted == url("SP", :nfe_recepcao_evento)
    end

    test "service_status routes to the SVC and keeps the UF's cUF" do
      assert {:ok, _} = SefazNfe.service_status(Map.put(base("BA"), :contingency, :svc_rs))
      assert_receive {:posted, posted, body, _opts}
      assert posted == url(:svc_rs, :nfe_status_servico)
      assert body =~ "<cUF>29</cUF>"

      assert {:ok, _} = SefazNfe.service_status(base("BA"))
      assert_receive {:posted, origin, _body, _opts}
      assert origin == url("BA", :nfe_status_servico)
    end

    test "NFC-e has no SVC" do
      opts = base("BA") |> Map.merge(%{model: 65, contingency: :svc_rs})

      assert {:error, {:unsupported_for_model, 65}} = SefazNfe.service_status(opts)
    end
  end
end
