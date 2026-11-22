defmodule SefazNfe.MDFe.Pending do
  @moduledoc """
  `retConsMDFeNaoEnc`: the MDF-e of an emitter that were authorized and not yet
  closed (encerrados), from `SefazNfe.MDFe.pending/1`.

  `:documents` is `[%{ch_mdfe: key, n_prot: protocol}]`, empty when SEFAZ lists
  none (or rejected the request: read `:c_stat` and `:x_motivo`, as with every
  answer SEFAZ gave).
  """

  alias SefazNfe.SOAP.Fault
  alias SefazNfe.XML

  @type document :: %{ch_mdfe: String.t(), n_prot: String.t() | nil}

  @type t :: %__MODULE__{
          c_stat: pos_integer(),
          x_motivo: String.t(),
          documents: [document()]
        }

  @enforce_keys [:c_stat, :x_motivo]
  defstruct [:c_stat, :x_motivo, documents: []]

  @doc false
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(body) when is_binary(body) do
    with {:ok, doc} <- XML.parse(body),
         :ok <- Fault.check(doc) do
      from_doc(doc)
    end
  end

  defp from_doc(doc) do
    case XML.integer(doc, "cStat") do
      nil ->
        {:error, {:xml, :no_c_stat}}

      c_stat ->
        {:ok,
         %__MODULE__{
           c_stat: c_stat,
           x_motivo: XML.text(doc, "xMotivo") || "",
           documents: doc |> XML.all("infMDFe") |> Enum.map(&document/1)
         }}
    end
  end

  defp document(element) do
    %{ch_mdfe: XML.text(element, "chMDFe"), n_prot: XML.text(element, "nProt")}
  end
end
