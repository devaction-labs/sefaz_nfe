defmodule SefazNfe.BuilderGoldenTest do
  @moduledoc """
  T5 (`.specs/features/nfe-builder/design.md`): for NF-e / NFC-e payloads of the
  `fiscal-gateway` HTTP contract, `SefazNfe.Builder` must write the same `infNFe`
  as NFePHP does for the gateway.

    * `test/golden/payloads/*.json`  the gateway's request payloads (the fixtures of its
      `tests/Fixtures/{nfe,nfce}`, plus variants written for the groups those leave out);
    * `test/golden/contexts/*.json`  what the gateway keeps outside the payload (company,
      model, series, number, cNF, emission type, environment, issue time);
    * `test/golden/expected/*.xml`   the unsigned XML the gateway's real
      `App\\Pipelines\\Nfe\\BuildNfeXml` writes for each pair, produced by
      `test/golden/php/render.php` (gateway commit in `expected/GATEWAY_SHA`).

  The suite never needs PHP: it only reads the committed XML. Both `infNFe` are
  compared canonicalised (C14N). A difference is either fixed in
  `SefazNfe.GatewayPayload` or listed in `@golden_exceptions`, asserted exactly.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.Builder
  alias SefazNfe.Fixtures
  alias SefazNfe.GatewayPayload
  alias SefazNfe.Signer
  alias SefazNfe.XML
  alias SefazNfe.XML.C14N

  @golden Path.expand("../golden", __DIR__)
  # CT-e, CT-e OS and MDF-e payloads share the directories (`builder_cte_mdfe_golden_test.exs`).
  @names @golden
         |> Path.join("payloads/*.json")
         |> Path.wildcard()
         |> Enum.map(&Path.basename(&1, ".json"))
         |> Enum.filter(fn name ->
           ctx = @golden |> Path.join("contexts/#{name}.json") |> File.read!() |> JSON.decode!()
           ctx["model"] in [55, 65]
         end)
         |> Enum.sort()

  for name <- @names do
    for dir <- ["payloads", "contexts"],
        do: @external_resource(Path.join(@golden, "#{dir}/#{name}.json"))

    @external_resource Path.join(@golden, "expected/#{name}.xml")
  end

  # Differences the builder is expected to keep, as exact canonical fragments:
  # name => [{what NFePHP writes, what the builder writes, reason}]. Empty: every
  # difference found was NFePHP behaviour the gateway mapping has to reproduce, and
  # `SefazNfe.GatewayPayload` does (see its comments); none is a builder difference.
  @golden_exceptions %{}

  defp exceptions(name), do: Map.get(Map.new(@golden_exceptions), name, [])

  @pl System.get_env("SEFAZ_NFE_PL_PATH")
  @have_pl is_binary(@pl) and File.exists?(Path.join(@pl, "nfe_v4.00.xsd")) and
             System.find_executable("xmllint") != nil
  @skip_pl if(@have_pl, do: false, else: "SEFAZ_NFE_PL_PATH or xmllint is not available")

  defp read_json(dir, name),
    do: [@golden, dir, name <> ".json"] |> Path.join() |> File.read!() |> JSON.decode!()

  defp expected_xml(name),
    do: [@golden, "expected", name <> ".xml"] |> Path.join() |> File.read!()

  defp built(name) do
    map =
      GatewayPayload.to_builder_map(read_json("payloads", name),
        context: read_json("contexts", name)
      )

    Builder.build_nfe(map)
  end

  defp canonical_inf_nfe(xml) do
    {:ok, doc} = XML.parse(xml)
    doc |> XML.element("infNFe") |> C14N.canonicalize()
  end

  # The first place the two canonical documents differ, as two short fragments.
  defp first_difference(a, b) do
    prefix = common_prefix(a, b, 0)
    from = max(prefix - 60, 0)

    {binary_part(a, from, min(200, byte_size(a) - from)),
     binary_part(b, from, min(200, byte_size(b) - from))}
  end

  defp common_prefix(<<c, a::binary>>, <<c, b::binary>>, n), do: common_prefix(a, b, n + 1)
  defp common_prefix(_a, _b, n), do: n

  describe "infNFe equals the one NFePHP writes for the gateway" do
    for name <- @names do
      test name do
        name = unquote(name)
        assert {:ok, %{xml: ours, access_key: key}} = built(name)

        reference = expected_xml(name)

        assert key ==
                 reference
                 |> canonical_inf_nfe()
                 |> then(&Regex.run(~r/Id="NFe(\d{44})"/, &1))
                 |> List.last()

        a = canonical_inf_nfe(reference)
        b = canonical_inf_nfe(ours)

        expected =
          Enum.reduce(exceptions(name), a, fn {from, to, _why}, acc ->
            String.replace(acc, from, to, global: false)
          end)

        if b != expected do
          {nfephp, builder} = first_difference(expected, b)
          flunk("#{name} differs\nNFePHP : #{nfephp}\nbuilder: #{builder}")
        end
      end
    end
  end

  describe "both documents against PL_010_V1.30 (xmllint)" do
    @describetag skip: @skip_pl

    for name <- @names do
      test "#{name}: NFePHP's XML" do
        assert xmllint(expected_xml(unquote(name))) == :ok
      end

      test "#{name}: the builder's XML" do
        assert {:ok, %{xml: xml}} = built(unquote(name))
        assert xmllint(xml) == :ok
      end
    end
  end

  # The schema requires a Signature, so both are signed with the test certificate first.
  defp xmllint(xml) do
    {:ok, signed} = Signer.sign_nfe(xml, Fixtures.cert())
    lint(signed)
  end

  defp lint(xml) do
    file = Path.join(System.tmp_dir!(), "golden_#{System.unique_integer([:positive])}.xml")
    File.write!(file, xml)

    try do
      case System.cmd("xmllint", ["--noout", "--schema", "nfe_v4.00.xsd", file],
             cd: @pl,
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, _status} -> output
      end
    after
      File.rm(file)
    end
  end
end
