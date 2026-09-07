defmodule SefazNfe.Result do
  alias SefazNfe.SOAP.Fault
  alias SefazNfe.XML

  @moduledoc """
  Parsed SEFAZ business outcome. A SOAP envelope that we understood is
  `{:ok, t}` even when `c_stat != 100` — that is a rejection, not a crash.

  A batch answer wraps the real outcome in `protNFe/infProt`, so `parse/1`
  reads the nested `cStat` when there is one and the envelope's otherwise.
  `150` is `100` with the authorization recorded outside the deadline, so both
  are `:authorized`.
  """

  @type status ::
          :authorized | :batch_received | :batch_processed | :processing | :rejected

  @type t :: %__MODULE__{
          status: status(),
          c_stat: pos_integer(),
          x_motivo: String.t(),
          ch_nfe: String.t() | nil,
          n_prot: String.t() | nil,
          n_rec: String.t() | nil,
          xml: String.t() | nil
        }

  @enforce_keys [:status, :c_stat, :x_motivo]
  defstruct [:status, :c_stat, :x_motivo, :ch_nfe, :n_prot, :n_rec, :xml]

  @doc """
  Maps a SEFAZ SOAP body to `t:t/0`.

  A body we could read is `{:ok, t}` even when `cStat` is a rejection: 204
  (duplicate) is a business outcome, not a transport failure (SEFAZ-03). Only an
  unreadable body or a SOAP fault is `{:error, _}`.

  The `cStat` values mapped to a status are the ones the MOC defines for these
  flows — 100 authorized, 103 lote received, 104 lote processed, 105 in
  processing. Everything else is `:rejected` with the raw code preserved; this
  library does not ship a `cStat` dictionary it would have to chase.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(body) when is_binary(body) do
    with {:ok, doc} <- XML.parse(body),
         :ok <- Fault.check(doc) do
      from_doc(doc)
    end
  end

  # cStat 104 means the batch was processed, not that the document was
  # authorized: the real outcome sits inside protNFe/infProt. Reading the
  # envelope's own cStat there would report every rejected document as fine.
  defp from_doc(doc) do
    outcome = XML.element(doc, "infProt") || doc

    case XML.integer(outcome, "cStat") do
      nil -> {:error, {:xml, :no_c_stat}}
      c_stat -> {:ok, result(doc, outcome, c_stat)}
    end
  end

  defp result(doc, outcome, c_stat) do
    %__MODULE__{
      status: status(c_stat),
      c_stat: c_stat,
      x_motivo: XML.text(outcome, "xMotivo") || "",
      ch_nfe: XML.text(outcome, "chNFe"),
      n_prot: XML.text(outcome, "nProt"),
      n_rec: XML.text(doc, "nRec")
    }
  end

  defp status(100), do: :authorized
  defp status(103), do: :batch_received
  defp status(104), do: :batch_processed
  defp status(105), do: :processing
  defp status(150), do: :authorized
  defp status(_other), do: :rejected
end
