# Renders test/golden/rfb/expected/ from the official Receita Federal calculators.
#
# NOT part of `mix test` (it opens sockets). Run by scripts/conformance/rfb_calculator.sh:
#
#     MIX_ENV=test mix run scripts/conformance/render_rfb.exs
#
# MIX_ENV=test only so that test/support (SefazNfe.RFBCalculator, NFeMap) is compiled.
#
# Environment:
#
#     RFB_REGIME_URL   regime-regular API   (default http://127.0.0.1:18080/api/calculadora)
#     RFB_SIMPLES_URL  simples-nacional API (default http://127.0.0.1:18082/api)
#     RFB_REGIME_SHA, RFB_SIMPLES_SHA  commits being rendered (recorded in RFB_VERSIONS)
#
# For each test/golden/rfb/scenarios/<name>.json it writes, in expected/:
#
#     <name>.json             the calculator's result (for `roc` scenarios, the ROC itself)
#     <name>.xml              what `POST /xml/generate?tipo=<nfe|nfce>` writes for it
#     <name>.validation.json  the verdict of `POST /xml/validate?subtipo=grupo` on OUR
#                             fragment (built from the result by SefazNfe.Builder)
#
# and RFB_VERSIONS.

alias SefazNfe.RFBCalculator, as: RFB

unless Code.ensure_loaded?(RFB), do: raise("run with MIX_ENV=test (test/support is not compiled)")

defmodule RenderRFB do
  @moduledoc false

  @timeout to_timeout(second: 60)

  def regime, do: System.get_env("RFB_REGIME_URL", "http://127.0.0.1:18080/api/calculadora")
  def simples, do: System.get_env("RFB_SIMPLES_URL", "http://127.0.0.1:18082/api")

  def post(url, content_type, body) do
    request = {String.to_charlist(url), [], String.to_charlist(content_type), body}
    http = [timeout: @timeout, connect_timeout: @timeout]

    case :httpc.request(:post, request, http, body_format: :binary) do
      {:ok, {{_, status, _}, _headers, response}} -> {status, response}
      {:error, reason} -> raise "POST #{url}: #{inspect(reason)}"
    end
  end

  def get(url) do
    http = [timeout: @timeout, connect_timeout: @timeout]

    case :httpc.request(:get, {String.to_charlist(url), []}, http, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> JSON.decode!(body)
      other -> raise "GET #{url}: #{inspect(other)}"
    end
  end

  # Reformats a JSON text with indentation, keeping the calculator's key order and
  # number spelling (decoding would lose both).
  def pretty(json), do: json |> String.to_charlist() |> walk(0, false, []) |> to_string()

  defp walk([], _depth, _in_string, acc), do: Enum.reverse(["\n" | acc])

  defp walk([?\\, c | rest], depth, true, acc), do: walk(rest, depth, true, [c, ?\\ | acc])
  defp walk([?" | rest], depth, in_string, acc), do: walk(rest, depth, not in_string, [?" | acc])
  defp walk([c | rest], depth, true, acc), do: walk(rest, depth, true, [c | acc])

  defp walk([c, d | rest], depth, false, acc) when c in [?{, ?[] and d in [?}, ?]],
    do: walk(rest, depth, false, [d, c | acc])

  defp walk([c | rest], depth, false, acc) when c in [?{, ?[],
    do: walk(rest, depth + 1, false, [indent(depth + 1), ?\n, c | acc])

  defp walk([c | rest], depth, false, acc) when c in [?}, ?]],
    do: walk(rest, depth - 1, false, [c, indent(depth - 1), ?\n | acc])

  defp walk([?, | rest], depth, false, acc),
    do: walk(rest, depth, false, [indent(depth), ?\n, ?, | acc])

  defp walk([?: | rest], depth, false, acc), do: walk(rest, depth, false, [?\s, ?: | acc])
  defp walk([c | rest], depth, false, acc), do: walk(rest, depth, false, [c | acc])

  defp indent(depth), do: String.duplicate("  ", depth)
end

expected = Path.join(RFB.dir(), "expected")
File.mkdir_p!(expected)

# A rendering is a replacement, not an accumulation: files of a scenario that no
# longer exists must go.
current = RFB.names()

for file <- Path.wildcard(Path.join(expected, "*")),
    Path.basename(file) != "RFB_VERSIONS",
    name = file |> Path.basename() |> String.split(".") |> hd(),
    name not in current,
    do: File.rm!(file)

for name <- current do
  %{"meta" => meta, "request" => request} = RFB.scenario(name)
  out = fn ext -> Path.join(expected, name <> ext) end
  fail = fn what, status, body -> raise "#{name}: #{what} answered #{status}: #{body}" end

  # The calculator's result, as text.
  result =
    case meta["kind"] do
      "calculo" ->
        {status, body} =
          RenderRFB.post(
            RenderRFB.regime() <> "/regime-geral",
            "application/json",
            JSON.encode!(request)
          )

        if status != 200, do: fail.("regime-geral", status, body)
        body

      "roc" ->
        JSON.encode!(request)

      "simples" ->
        {status, body} =
          RenderRFB.post(
            RenderRFB.simples() <> "/calculadora/observabilidade/simples-nacional",
            "application/json",
            JSON.encode!(request)
          )

        if status != 200, do: fail.("simples-nacional", status, body)
        body
    end

  File.write!(out.(".json"), RenderRFB.pretty(result))

  if meta["kind"] != "simples" do
    {status, xml} =
      RenderRFB.post(
        RenderRFB.regime() <> "/xml/generate?tipo=#{meta["document"]}",
        "application/json",
        result
      )

    if status != 200, do: fail.("xml/generate", status, xml)
    File.write!(out.(".xml"), xml)

    # Our fragment, from the same numbers, and the calculator's opinion of it.
    decoded = JSON.decode!(result)

    verdict =
      case RFB.build(%{"meta" => meta}, decoded) do
        {:ok, %{xml: ours}} ->
          {status, body} =
            RenderRFB.post(
              RenderRFB.regime() <> "/xml/validate?tipo=#{meta["document"]}&subtipo=grupo",
              "application/xml",
              RFB.group_xml(ours)
            )

          case {status, body} do
            {200, "true"} ->
              %{"built" => true, "valid" => true}

            {_, body} ->
              # Only `detail`: the rest of the problem document carries a timestamp.
              detail = body |> JSON.decode!() |> Map.fetch!("detail")
              %{"built" => true, "valid" => false, "status" => status, "detail" => detail}
          end

        # The layout of the PL the library targets does not hold what the calculator
        # wrote: nothing to validate. The golden test lists it in `@differences`.
        {:error, errors} ->
          %{"built" => false, "errors" => inspect(errors, limit: :infinity)}
      end

    File.write!(out.(".validation.json"), RenderRFB.pretty(JSON.encode!(verdict)))
  end

  IO.puts("rendered #{name}")
end

# Versions: what the expected files were rendered with.
%{"versaoApp" => regime_app, "versaoDb" => regime_db, "dataVersaoDb" => regime_db_date} =
  RenderRFB.get(RenderRFB.regime() <> "/dados-abertos/versao")

simples = RenderRFB.get(RenderRFB.simples() <> "/versao")
notes = RenderRFB.get(RenderRFB.regime() <> "/xml/validate")

versions = [
  "regime_regular_sha=#{System.get_env("RFB_REGIME_SHA", "unknown")}",
  "simples_nacional_sha=#{System.get_env("RFB_SIMPLES_SHA", "unknown")}",
  "regime_regular_app=#{regime_app}",
  "regime_regular_db=#{regime_db} (#{regime_db_date})",
  "simples_nacional_app=#{simples["versaoApp"]}",
  "simples_nacional_db=#{simples["versaoDb"]} (#{simples["dataVersaoDb"]})",
  for(
    n <- notes,
    n["mnemonico"] in ["nfe", "nfce"],
    do: "nota_tecnica_#{n["mnemonico"]}=#{n["versaoNotaTecnica"]}"
  ),
  "sefaz_nfe_layout=#{SefazNfe.Layout.nfe().pl}"
]

File.write!(
  Path.join(expected, "RFB_VERSIONS"),
  versions |> List.flatten() |> Enum.join("\n") |> Kernel.<>("\n")
)

IO.puts("wrote RFB_VERSIONS")
