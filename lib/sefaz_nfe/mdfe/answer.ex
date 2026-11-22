defmodule SefazNfe.MDFe.Answer do
  @moduledoc false

  # Maps an MDF-e SOAP body to `SefazNfe.Result`. `SefazNfe.Result.parse/1`
  # reads `chNFe`; an MDF-e answer carries `chMDFe`, so the key lands in the
  # struct's `:ch_nfe` field, which is "the access key of the document" for every
  # model.
  #
  # Two scopes, because the outcome lives in different places:
  #
  #   * `:protocol` - an authorization or an event: `protMDFe/infProt` or
  #     `retEventoMDFe/infEvento` when present, the envelope's own `cStat`
  #     otherwise (a rejection of the request itself);
  #   * `:consult` - `retConsSitMDFe`: the top-level `cStat` is the document's
  #     situation (100 authorized, 101 cancelled, 132 closed). The nested
  #     `protMDFe` is the original authorization and always says 100, so reading
  #     it would report a cancelled MDF-e as authorized.

  alias SefazNfe.CStat
  alias SefazNfe.Result
  alias SefazNfe.SOAP.Fault
  alias SefazNfe.XML

  @spec parse(String.t(), :protocol | :consult) :: {:ok, Result.t()} | {:error, term()}
  def parse(body, scope) when is_binary(body) and scope in [:protocol, :consult] do
    with {:ok, doc} <- XML.parse(body),
         :ok <- Fault.check(doc) do
      from_doc(doc, scope)
    end
  end

  defp from_doc(doc, scope) do
    outcome = outcome(doc, scope)

    case XML.integer(outcome, "cStat") do
      nil -> {:error, {:xml, :no_c_stat}}
      c_stat -> {:ok, result(doc, outcome, c_stat)}
    end
  end

  defp outcome(doc, :protocol),
    do: XML.element(doc, "infProt") || XML.element(doc, "infEvento") || doc

  defp outcome(doc, :consult), do: doc

  defp result(doc, outcome, c_stat) do
    protocol = XML.element(doc, "infProt") || outcome

    %Result{
      status: CStat.classify(c_stat),
      c_stat: c_stat,
      x_motivo: XML.text(outcome, "xMotivo") || "",
      ch_nfe: XML.text(outcome, "chMDFe") || XML.text(doc, "chMDFe"),
      n_prot: XML.text(outcome, "nProt") || XML.text(protocol, "nProt"),
      dh_recbto:
        XML.text(outcome, "dhRecbto") || XML.text(outcome, "dhRegEvento") ||
          XML.text(protocol, "dhRecbto")
    }
  end
end
