defmodule SefazNfe.SOAP.Fault do
  @moduledoc """
  Detects a SOAP fault in a 200 response.

  SEFAZ endpoints answer some errors with a fault inside a `200 OK`, so status
  code alone does not say whether the call worked. A fault is a transport
  failure and must never be reported as a `cStat`.
  """

  @doc "`:ok`, or the fault reason when the body carries one."
  @spec check(SefazNfe.XML.doc()) :: :ok | {:error, {:soap_fault, String.t()}}
  def check(doc) do
    case SefazNfe.XML.text(doc, "Fault") do
      nil -> :ok
      _fault -> {:error, {:soap_fault, reason(doc)}}
    end
  end

  defp reason(doc) do
    SefazNfe.XML.text(doc, "Text") || SefazNfe.XML.text(doc, "faultstring") || "unknown"
  end
end
