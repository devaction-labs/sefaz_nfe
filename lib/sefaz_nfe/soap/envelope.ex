defmodule SefazNfe.SOAP.Envelope do
  @moduledoc """
  Builds the SOAP 1.2 envelope the 4.00 webservices expect.

  Each service takes its message inside `nfeDadosMsg`, whose namespace is the
  service's own WSDL namespace — that is what routes the call on the `.asmx`
  endpoint, so it is per service rather than global.

  The message itself is passed through untouched. For `SefazNfe.authorize/1`
  that matters: the ERP owns the XML and a signed document must reach SEFAZ byte
  for byte, or the signature breaks (SEFAZ-04).
  """

  @envelope_ns "http://www.w3.org/2003/05/soap-envelope"
  @nfe_ns "http://www.portalfiscal.inf.br/nfe"
  @wsdl_base "http://www.portalfiscal.inf.br/nfe/wsdl"

  @wsdl %{
    nfe_autorizacao: "NFeAutorizacao4",
    nfe_ret_autorizacao: "NFeRetAutorizacao4",
    nfe_consulta_protocolo: "NFeConsultaProtocolo4",
    nfe_status_servico: "NFeStatusServico4",
    nfe_recepcao_evento: "NFeRecepcaoEvento4",
    nfe_inutilizacao: "NFeInutilizacao4",
    nfe_distribuicao_dfe: "NFeDistribuicaoDFe"
  }

  @type service :: SefazNfe.Endpoints.service()

  @doc "Wraps `message` for `service`."
  @spec wrap(service(), iodata()) :: {:ok, binary()} | {:error, {:unknown_service, term()}}
  def wrap(service, message) do
    case @wsdl[service] do
      nil ->
        {:error, {:unknown_service, service}}

      wsdl ->
        {:ok,
         IO.iodata_to_binary([
           ~s(<?xml version="1.0" encoding="UTF-8"?>),
           ~s(<soap:Envelope xmlns:soap="#{@envelope_ns}"><soap:Body>),
           ~s(<nfeDadosMsg xmlns="#{@wsdl_base}/#{wsdl}">),
           message,
           ~s(</nfeDadosMsg></soap:Body></soap:Envelope>)
         ])}
    end
  end

  @doc """
  `consStatServ` for `NFeStatusServico4`.

  `xServ` is fixed at `STATUS`; it is the only operation the service defines.
  """
  @spec status_service(pos_integer(), 1 | 2) :: binary()
  def status_service(uf_code, tp_amb) do
    ~s(<consStatServ xmlns="#{@nfe_ns}" versao="4.00">) <>
      ~s(<tpAmb>#{tp_amb}</tpAmb><cUF>#{uf_code}</cUF><xServ>STATUS</xServ>) <>
      ~s(</consStatServ>)
  end

  @doc "`consSitNFe` for `NFeConsultaProtocolo4`."
  @spec consult_protocol(String.t(), 1 | 2) :: binary()
  def consult_protocol(ch_nfe, tp_amb) do
    ~s(<consSitNFe xmlns="#{@nfe_ns}" versao="4.00">) <>
      ~s(<tpAmb>#{tp_amb}</tpAmb><xServ>CONSULTAR</xServ><chNFe>#{ch_nfe}</chNFe>) <>
      ~s(</consSitNFe>)
  end

  @doc "`consReciNFe` for `NFeRetAutorizacao4`."
  @spec authorization_result(String.t(), 1 | 2) :: binary()
  def authorization_result(n_rec, tp_amb) do
    ~s(<consReciNFe xmlns="#{@nfe_ns}" versao="4.00">) <>
      ~s(<tpAmb>#{tp_amb}</tpAmb><nRec>#{n_rec}</nRec>) <>
      ~s(</consReciNFe>)
  end

  @doc "`tpAmb` for an environment: 1 is production, 2 is homologation."
  @spec tp_amb(:production | :homologation) :: 1 | 2
  def tp_amb(:production), do: 1
  def tp_amb(:homologation), do: 2
end
