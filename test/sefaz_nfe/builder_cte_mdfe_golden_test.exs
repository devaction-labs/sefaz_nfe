defmodule SefazNfe.BuilderCteMdfeGoldenTest do
  @moduledoc """
  C6 (`.specs/features/cte-mdfe/design.md`): for CT-e (57), CT-e OS (67) and MDF-e (58)
  payloads of the `fiscal-gateway` HTTP contract, `SefazNfe.Builder` must write the same
  `infCte` / `infMDFe` as NFePHP does for the gateway.

    * `test/golden/payloads/{cte,cte-os,mdfe}-*.json`  the gateway's request payloads (the
      fixtures of its `tests/Fixtures/{cte,cte-os,mdfe}`, plus variants written for the
      groups those leave out);
    * `test/golden/contexts/*.json`  what the gateway keeps outside the payload (company,
      model, series, number, cCT/cMDF, emission type, environment, issue time, and the MDF-e
      technical contact the gateway reads from its configuration);
    * `test/golden/expected/*.xml`   the unsigned XML the gateway's real
      `App\\Pipelines\\Cte\\BuildCteXml`, `BuildCteOsXml` and `App\\Pipelines\\Mdfe\\BuildMdfeXml`
      write for each pair, produced by `test/golden/php/render_cte_mdfe.php` (gateway commit in
      `expected/GATEWAY_SHA`).

  The suite never needs PHP: it only reads the committed XML. Both `inf*` elements are compared
  canonicalised (C14N); `infCTeSupl` / `infMDFeSupl` are added at authorization, not by the
  builder, so only `infCte` / `infMDFe` are compared. A difference is either fixed in
  `SefazNfe.GatewayCtePayload` / `SefazNfe.GatewayMdfePayload` (NFePHP behaviour the mapping
  reproduces) or listed in `@golden_exceptions`, asserted exactly.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.Builder
  alias SefazNfe.Fixtures
  alias SefazNfe.GatewayCtePayload
  alias SefazNfe.GatewayMdfePayload
  alias SefazNfe.Signer
  alias SefazNfe.XML
  alias SefazNfe.XML.C14N

  @golden Path.expand("../golden", __DIR__)

  @models %{57 => :cte, 67 => :cte_os, 58 => :mdfe}

  @kinds %{
    cte: %{
      inf: "infCte",
      root: "CTe",
      xsd: "cte_v4.00.xsd",
      modal: {"rodo", "cteModalRodoviario_v4.00.xsd"}
    },
    cte_os: %{
      inf: "infCte",
      root: "CTeOS",
      xsd: "cteOS_v4.00.xsd",
      modal: {"rodoOS", "cteModalRodoviarioOS_v4.00.xsd"}
    },
    mdfe: %{
      inf: "infMDFe",
      root: "MDFe",
      xsd: "mdfe_v3.00.xsd",
      modal: {"rodo", "mdfeModalRodoviario_v3.00.xsd"}
    }
  }

  @namespaces %{
    cte: "http://www.portalfiscal.inf.br/cte",
    cte_os: "http://www.portalfiscal.inf.br/cte",
    mdfe: "http://www.portalfiscal.inf.br/mdfe"
  }

  defp read_json(dir, name),
    do: [@golden, dir, name <> ".json"] |> Path.join() |> File.read!() |> JSON.decode!()

  # Payloads for which NFePHP writes a document that is invalid against the PL (proved with
  # xmllint below) and the builder, which follows the schema, refuses with these errors: the
  # gateway's `veic.owner` with a `state` and no `state_registration` becomes a `prop` with `UF`
  # and no `IE`, but the modal XSD makes `IE` + `UF` one optional sequence. Not compared.
  @nfephp_invalid %{
    "cte-os-owner-without-ie" => [
      {[:inf_cte_norm, :inf_modal, :rodo_os, :veic, :prop, :ie], :required}
    ]
  }

  # {name, kind} of every payload whose context is a CT-e, CT-e OS or MDF-e.
  @all_entries @golden
               |> Path.join("payloads/*.json")
               |> Path.wildcard()
               |> Enum.map(&Path.basename(&1, ".json"))
               |> Enum.sort()
               |> Enum.flat_map(fn name ->
                 ctx =
                   @golden |> Path.join("contexts/#{name}.json") |> File.read!() |> JSON.decode!()

                 case Map.fetch(@models, ctx["model"]) do
                   {:ok, kind} -> [{name, kind}]
                   :error -> []
                 end
               end)

  @entries Enum.reject(@all_entries, fn {name, _kind} -> Map.has_key?(@nfephp_invalid, name) end)
  @invalid_entries Enum.filter(@all_entries, fn {name, _kind} ->
                     Map.has_key?(@nfephp_invalid, name)
                   end)

  for {name, _kind} <- @all_entries do
    for dir <- ["payloads", "contexts"],
        do: @external_resource(Path.join(@golden, "#{dir}/#{name}.json"))

    @external_resource Path.join(@golden, "expected/#{name}.xml")
  end

  # Differences the builder is expected to keep, as exact canonical fragments:
  # name => [{what NFePHP writes, what the builder writes, reason}]. Empty: every difference
  # found was NFePHP behaviour the gateway mappings have to reproduce, and
  # `SefazNfe.GatewayCtePayload` / `SefazNfe.GatewayMdfePayload` do (see their comments); none
  # is a builder difference.
  @golden_exceptions %{}

  defp exceptions(name), do: Map.get(Map.new(@golden_exceptions), name, [])

  @cte_pl System.get_env("SEFAZ_NFE_CTE_PL_PATH")
  @mdfe_pl System.get_env("SEFAZ_NFE_MDFE_PL_PATH")
  @have_xmllint System.find_executable("xmllint") != nil
  @have_cte_pl @have_xmllint and is_binary(@cte_pl) and
                 File.exists?(Path.join(@cte_pl, "cte_v4.00.xsd"))
  @have_mdfe_pl @have_xmllint and is_binary(@mdfe_pl) and
                  File.exists?(Path.join(@mdfe_pl, "mdfe_v3.00.xsd"))

  @skip_cte if(@have_cte_pl, do: false, else: "SEFAZ_NFE_CTE_PL_PATH or xmllint is not available")
  @skip_mdfe if(@have_mdfe_pl,
               do: false,
               else: "SEFAZ_NFE_MDFE_PL_PATH or xmllint is not available"
             )

  defp pl(:mdfe), do: @mdfe_pl
  defp pl(_cte), do: @cte_pl

  defp kind(name), do: Map.fetch!(@models, read_json("contexts", name)["model"])

  defp expected_xml(name),
    do: [@golden, "expected", name <> ".xml"] |> Path.join() |> File.read!()

  defp built(name) do
    ctx = read_json("contexts", name)
    payload = read_json("payloads", name)

    case kind(name) do
      :cte ->
        Builder.build_cte(GatewayCtePayload.to_builder_map(payload, context: ctx))

      :cte_os ->
        Builder.build_cte_os(GatewayCtePayload.to_builder_map(payload, context: ctx))

      :mdfe ->
        Builder.build_mdfe(GatewayMdfePayload.to_builder_map(payload, context: ctx))
    end
  end

  defp canonical_inf(xml, kind) do
    {:ok, doc} = XML.parse(xml)
    doc |> XML.element(@kinds[kind].inf) |> C14N.canonicalize()
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

  describe "inf* equals the one NFePHP writes for the gateway" do
    for {name, kind} <- @entries do
      test name do
        name = unquote(name)
        kind = unquote(kind)
        assert {:ok, %{xml: ours, access_key: key}} = built(name)

        reference = expected_xml(name)
        a = canonical_inf(reference, kind)
        b = canonical_inf(ours, kind)

        assert key == a |> then(&Regex.run(~r/Id="(?:CTe|MDFe)(\d{44})"/, &1)) |> List.last()

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

  describe "both documents against the PL (xmllint)" do
    for {name, kind} <- @entries do
      @skip if(kind == :mdfe, do: @skip_mdfe, else: @skip_cte)

      @tag skip: @skip
      test "#{name}: NFePHP's XML" do
        name = unquote(name)
        assert xmllint(expected_xml(name), unquote(kind)) == :ok
      end

      @tag skip: @skip
      test "#{name}: the builder's XML" do
        name = unquote(name)
        assert {:ok, %{xml: xml}} = built(name)
        assert xmllint(xml, unquote(kind)) == :ok
      end

      @tag skip: @skip
      test "#{name}: NFePHP's modal against its modal XSD" do
        name = unquote(name)
        kind = unquote(kind)
        assert modal_lint(expected_xml(name), kind) == :ok
      end

      @tag skip: @skip
      test "#{name}: the builder's modal against its modal XSD" do
        name = unquote(name)
        kind = unquote(kind)
        assert {:ok, %{xml: xml}} = built(name)
        assert modal_lint(xml, kind) == :ok
      end
    end
  end

  describe "NFePHP writes a schema-invalid modal, the builder refuses it" do
    for {name, kind} <- @invalid_entries do
      test "#{name}: the builder reports the missing element" do
        assert built(unquote(name)) == {:error, Map.fetch!(@nfephp_invalid, unquote(name))}
      end

      @tag skip: if(kind == :mdfe, do: @skip_mdfe, else: @skip_cte)
      test "#{name}: NFePHP's modal fails its modal XSD (xmllint)" do
        name = unquote(name)
        result = modal_lint(expected_xml(name), unquote(kind))
        assert is_binary(result)

        assert result =~
                 "Element '{http://www.portalfiscal.inf.br/cte}UF': This element is not expected"
      end
    end
  end

  # The modal is an `xs:any` in the document's XSD: it is validated on its own.
  defp modal_lint(xml, kind) do
    {tag, xsd} = @kinds[kind].modal

    fragment =
      case Regex.run(~r/<#{tag}>.*<\/#{tag}>/s, xml) do
        [found] ->
          String.replace(found, "<#{tag}>", ~s(<#{tag} xmlns="#{@namespaces[kind]}">),
            global: false
          )
      end

    lint(fragment, xsd, pl(kind))
  end

  # The schema requires a Signature, so both are signed with the test certificate first.
  defp xmllint(xml, kind) do
    %{inf: inf, root: root, xsd: xsd} = @kinds[kind]
    {:ok, signed} = Signer.sign(xml, Fixtures.cert(), inf, root)
    lint(signed, xsd, pl(kind))
  end

  defp lint(xml, xsd, dir) do
    file = Path.join(System.tmp_dir!(), "golden_#{System.unique_integer([:positive])}.xml")
    File.write!(file, xml)

    try do
      case System.cmd("xmllint", ["--noout", "--schema", xsd, file],
             cd: dir,
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
