defmodule SefazNfe.MDFe.Messages do
  @moduledoc false

  # The `mdfeDadosMsg` payloads of the MDF-e services, layout 3.00. Internal;
  # `SefazNfe.SOAP.Envelope.wrap/2` puts them in the SOAP body.

  alias SefazNfe.SOAP.Envelope

  @mdfe_ns "http://www.portalfiscal.inf.br/mdfe"

  @doc """
  The synchronous send: the signed MDF-e alone, without declaration or `enviMDFe`,
  gzip compressed and Base64 encoded (NFePHP `base64_encode(gzencode($xml))`).
  """
  @spec send_mdfe(String.t()) :: binary()
  def send_mdfe(signed_mdfe) do
    signed_mdfe |> strip_declaration() |> :zlib.gzip() |> Base.encode64()
  end

  @doc "`consSitMDFe`."
  @spec consult(String.t(), 1 | 2) :: binary()
  def consult(ch_mdfe, tp_amb) do
    ~s(<consSitMDFe xmlns="#{@mdfe_ns}" versao="3.00">) <>
      ~s(<tpAmb>#{tp_amb}</tpAmb><xServ>CONSULTAR</xServ><chMDFe>#{ch_mdfe}</chMDFe>) <>
      ~s(</consSitMDFe>)
  end

  @doc "`consMDFeNaoEnc` for a CNPJ or CPF."
  @spec pending(String.t(), 1 | 2) :: binary()
  def pending(tax_id, tp_amb) do
    ~s(<consMDFeNaoEnc xmlns="#{@mdfe_ns}" versao="3.00">) <>
      ~s(<tpAmb>#{tp_amb}</tpAmb><xServ>CONSULTAR NÃO ENCERRADOS</xServ>) <>
      Envelope.tax_id_element(tax_id) <> ~s(</consMDFeNaoEnc>)
  end

  @doc "The signed `eventoMDFe` as it goes: plain XML, no `envEvento`, no declaration."
  @spec send_event(String.t()) :: binary()
  def send_event(signed_event), do: strip_declaration(signed_event)

  defp strip_declaration(xml), do: String.replace(xml, ~r/^\s*<\?xml[^>]*\?>/, "")
end
