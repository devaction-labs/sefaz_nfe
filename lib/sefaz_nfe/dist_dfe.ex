defmodule SefazNfe.DistDFe do
  @moduledoc """
  Page returned by `NFeDistribuicaoDFe` (Ambiente Nacional).

  The cursor belongs to the caller (AD-002): persist `ult_nsu` and pass it back,
  or the same documents arrive forever. `max_nsu` says how far the AN has gone,
  so `ult_nsu < max_nsu` means there is a backlog to drain.
  """

  alias SefazNfe.SOAP.Fault
  alias SefazNfe.XML

  defmodule Document do
    @moduledoc """
    One distributed document, already decompressed.

    `schema` is the AN's own label — `procNFe_v4.00`, `resNFe_v1.01`,
    `procEventoNFe_v1.00` — and it says whether `xml` is a full document or
    only a summary.
    """

    @type t :: %__MODULE__{schema: String.t(), nsu: String.t(), xml: String.t()}
    @enforce_keys [:schema, :nsu, :xml]
    defstruct [:schema, :nsu, :xml]
  end

  @type t :: %__MODULE__{
          ult_nsu: String.t(),
          max_nsu: String.t(),
          c_stat: pos_integer(),
          x_motivo: String.t(),
          documents: [Document.t()]
        }

  @enforce_keys [:ult_nsu, :max_nsu, :c_stat]
  defstruct [:ult_nsu, :max_nsu, :c_stat, x_motivo: "", documents: []]

  @doc """
  Parses a `retDistDFeInt` response.

  Every document arrives gzipped and base64 encoded. A payload that will not
  decode is an error rather than a silently dropped document (SEFAZ-07): losing
  an inbound NF-e without noticing is worse than failing the whole page, since
  the cursor would move past it.

  `cStat` 137 (no document found) is a normal empty page, and 656 (consumo
  indevido) arrives as a page too, so the caller can back off on it.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(body) when is_binary(body) do
    with {:ok, doc} <- XML.parse(body),
         :ok <- Fault.check(doc),
         {:ok, documents} <- documents(doc) do
      page(doc, documents)
    end
  end

  defp page(doc, documents) do
    case XML.integer(doc, "cStat") do
      nil ->
        {:error, {:xml, :no_c_stat}}

      c_stat ->
        {:ok,
         %__MODULE__{
           ult_nsu: XML.text(doc, "ultNSU") || "0",
           max_nsu: XML.text(doc, "maxNSU") || "0",
           c_stat: c_stat,
           x_motivo: XML.text(doc, "xMotivo") || "",
           documents: documents
         }}
    end
  end

  defp documents(doc) do
    doc
    |> XML.all("docZip")
    |> Enum.reduce_while({:ok, []}, fn element, {:ok, acc} ->
      case document(element) do
        {:ok, document} -> {:cont, {:ok, acc ++ [document]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp document(element) do
    nsu = XML.own_attribute(element, "NSU") || ""
    schema = XML.own_attribute(element, "schema") || ""

    with {:ok, compressed} <- decode(XML.own_text(element), nsu),
         {:ok, xml} <- gunzip(compressed, nsu) do
      {:ok, %Document{schema: schema, nsu: nsu, xml: xml}}
    end
  end

  defp decode(nil, nsu), do: {:error, {:dist_dfe, {:empty_document, nsu}}}

  defp decode(text, nsu) do
    case Base.decode64(text, ignore: :whitespace) do
      {:ok, compressed} -> {:ok, compressed}
      :error -> {:error, {:dist_dfe, {:bad_base64, nsu}}}
    end
  end

  defp gunzip(compressed, nsu) do
    {:ok, :zlib.gunzip(compressed)}
  rescue
    _error -> {:error, {:dist_dfe, {:bad_gzip, nsu}}}
  end
end
