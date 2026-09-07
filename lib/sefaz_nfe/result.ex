defmodule SefazNfe.Result do
  alias SefazNfe.SOAP.Fault
  alias SefazNfe.XML

  @moduledoc """
  Parsed SEFAZ business outcome. A SOAP envelope that we understood is
  `{:ok, t}` even when `c_stat != 100` — that is a rejection, not a crash.

  ## The two XML fields

  `:signed_xml` is what was actually sent to SEFAZ, always present after an
  authorization attempt. `:xml` is the `nfeProc` — the signed document plus its
  protocol — and is only set once a protocol exists. The `nfeProc` is the
  document that has to be archived and delivered to the recipient, so losing
  either of them loses something legally required: without the protocol there
  is nothing to prove, and without the signed bytes the protocol cannot be
  attached to anything later.

  A batch answer wraps the real outcome one level down — `protNFe/infProt` for a
  document, `retEvento/infEvento` for an event — so `parse/1` reads the nested
  `cStat` when there is one and the envelope's otherwise. `150` is `100` with
  the authorization recorded outside the deadline, and `135` and `136` are the
  event equivalents of `100`, so all four are `:authorized`.
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
          xml: String.t() | nil,
          signed_xml: String.t() | nil
        }

  @enforce_keys [:status, :c_stat, :x_motivo]
  defstruct [:status, :c_stat, :x_motivo, :ch_nfe, :n_prot, :n_rec, :xml, :signed_xml]

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

  # A batch answer reports on the batch, not on the document: 104 means "lote
  # processado" and 128 "lote de evento processado". The outcome that matters
  # is nested — in protNFe/infProt for a document, in retEvento/infEvento for
  # an event. Reading the envelope's own cStat would report every rejection as
  # a success.
  defp from_doc(doc) do
    outcome = XML.element(doc, "infProt") || XML.element(doc, "infEvento") || doc

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

  @nfe_ns "http://www.portalfiscal.inf.br/nfe"
  @protocol ~r{<protNFe.*?</protNFe>}s
  @declaration ~r/^\s*<\?xml[^>]*\?>/

  @doc """
  Assembles the `nfeProc` from a signed document and the SEFAZ response.

  Both halves are spliced verbatim: the signature covers the document exactly
  as it was sent, and the protocol is SEFAZ's own bytes. Returns `nil` when the
  answer carries no protocol, which is the normal case for a receipt or a
  rejection.
  """
  @spec proc(String.t(), String.t()) :: String.t() | nil
  def proc(signed_xml, body) when is_binary(signed_xml) and is_binary(body) do
    case Regex.run(@protocol, body) do
      [protocol] ->
        ~s(<?xml version="1.0" encoding="UTF-8"?><nfeProc xmlns="#{@nfe_ns}" versao="4.00">) <>
          String.replace(signed_xml, @declaration, "") <>
          protocol <>
          ~s(</nfeProc>)

      nil ->
        nil
    end
  end

  defp status(100), do: :authorized
  defp status(103), do: :batch_received
  defp status(104), do: :batch_processed
  defp status(105), do: :processing
  defp status(150), do: :authorized
  defp status(135), do: :authorized
  defp status(136), do: :authorized
  defp status(_other), do: :rejected
end
