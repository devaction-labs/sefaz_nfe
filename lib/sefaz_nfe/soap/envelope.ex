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
    nfe_distribuicao_dfe: "NFeDistribuicaoDFe",
    nfe_consulta_cadastro: "CadConsultaCadastro4"
  }

  # The WSDL operation each service exposes. SOAP 1.2 carries it as the
  # `action` parameter of the content type, and the Ambiente Nacional refuses a
  # request without one ("Please supply a valid soap action"); the UF endpoints
  # happen not to enforce it.
  @operation %{
    nfe_autorizacao: "nfeAutorizacaoLote",
    nfe_ret_autorizacao: "nfeRetAutorizacao",
    nfe_consulta_protocolo: "nfeConsultaNF",
    nfe_status_servico: "nfeStatusServicoNF",
    nfe_recepcao_evento: "nfeRecepcaoEvento",
    nfe_inutilizacao: "nfeInutilizacaoNF",
    nfe_distribuicao_dfe: "nfeDistDFeInteresse",
    nfe_consulta_cadastro: "consultaCadastro4"
  }

  @type service :: SefazNfe.Endpoints.service()

  @doc """
  SOAPAction URI for `service`.

  `operation` overrides the service's default operation name. Only
  `NFeConsultaCadastro` needs it: its authorizers disagree on the name, so it
  comes from `SefazNfe.Endpoints.operation/2`. `nil` keeps the default.
  """
  @spec action(service(), String.t() | nil) ::
          {:ok, String.t()} | {:error, {:unknown_service, term()}}
  def action(service, operation \\ nil) do
    case {@wsdl[service], operation || @operation[service]} do
      {nil, _operation} -> {:error, {:unknown_service, service}}
      {wsdl, operation} -> {:ok, "#{@wsdl_base}/#{wsdl}/#{operation}"}
    end
  end

  @doc """
  Wraps `message` for `service`.

  The UF services take `nfeDadosMsg` directly in the body. `NFeDistribuicaoDFe`
  nests it one level deeper, inside the operation element — sending it flat
  makes the Ambiente Nacional answer a null reference from its own .NET stack
  rather than a `cStat`.
  """
  @spec wrap(service(), iodata()) :: {:ok, binary()} | {:error, {:unknown_service, term()}}
  def wrap(service, message) do
    case @wsdl[service] do
      nil -> {:error, {:unknown_service, service}}
      wsdl -> {:ok, envelope(service, wsdl, message)}
    end
  end

  defp envelope(:nfe_distribuicao_dfe, wsdl, message) do
    body(
      ~s(<nfeDistDFeInteresse xmlns="#{@wsdl_base}/#{wsdl}"><nfeDadosMsg>),
      message,
      ~s(</nfeDadosMsg></nfeDistDFeInteresse>)
    )
  end

  defp envelope(_service, wsdl, message) do
    body(~s(<nfeDadosMsg xmlns="#{@wsdl_base}/#{wsdl}">), message, ~s(</nfeDadosMsg>))
  end

  defp body(open, message, close) do
    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<soap:Envelope xmlns:soap="#{@envelope_ns}"><soap:Body>),
      open,
      message,
      close,
      ~s(</soap:Body></soap:Envelope>)
    ])
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

  @doc """
  `enviNFe` for `NFeAutorizacao4`, carrying one already signed NF-e.

  `ind_sinc` 1 asks SEFAZ to process the batch in the same call and answer with
  the protocol; 0 answers a receipt that `SefazNfe.authorization_result/1` then
  consults. The MOC allows up to 50 documents per batch, and v1 sends one.

  The signed document is embedded verbatim apart from its XML declaration,
  which is not allowed inside another document. Touching anything else would
  break the signature.
  """
  @spec send_nfe(String.t(), String.t(), 0 | 1) :: binary()
  def send_nfe(signed_nfe, id_lote, ind_sinc) do
    ~s(<enviNFe xmlns="#{@nfe_ns}" versao="4.00">) <>
      ~s(<idLote>#{id_lote}</idLote><indSinc>#{ind_sinc}</indSinc>) <>
      strip_declaration(signed_nfe) <>
      ~s(</enviNFe>)
  end

  @doc """
  `distDFeInt` for `NFeDistribuicaoDFe`.

  The cursor is one of `{:ult_nsu, nsu}` to walk forward, `{:nsu, nsu}` for a
  single document, or `{:ch_nfe, key}` to fetch one by access key.
  """
  @spec dist_dfe(String.t(), pos_integer(), 1 | 2, {atom(), String.t()}) :: binary()
  def dist_dfe(tax_id, uf_code, tp_amb, cursor) do
    ~s(<distDFeInt xmlns="#{@nfe_ns}" versao="1.01">) <>
      ~s(<tpAmb>#{tp_amb}</tpAmb><cUFAutor>#{uf_code}</cUFAutor>) <>
      tax_id_element(tax_id) <>
      dist_cursor(cursor) <>
      ~s(</distDFeInt>)
  end

  @doc """
  `envEvento` for `NFeRecepcaoEvento4`, carrying one already signed event.
  """
  @spec send_event(String.t(), String.t()) :: binary()
  def send_event(signed_event, id_lote) do
    ~s(<envEvento xmlns="#{@nfe_ns}" versao="1.00">) <>
      ~s(<idLote>#{id_lote}</idLote>) <>
      strip_declaration(signed_event) <>
      ~s(</envEvento>)
  end

  @doc """
  `ConsCad` for `NFeConsultaCadastro` (layout 2.00, not 4.00).

  `uf` is the UF whose registry is consulted. `filter` is exactly one of
  `{:tax_id, id}` (CPF or CNPJ) and `{:ie, ie}`.

  MT quirk (from NFePHP): SEFAZ-MT wants the message wrapped in one more
  `nfeDadosMsg`, with no namespace of its own, inside the WSDL one. Every other
  authorizer takes `ConsCad` directly.
  """
  @spec consult_taxpayer(String.t(), {:tax_id | :ie, String.t()}) :: binary()
  def consult_taxpayer("MT" = uf, filter) do
    "<nfeDadosMsg>" <> cons_cad(uf, filter) <> "</nfeDadosMsg>"
  end

  def consult_taxpayer(uf, filter), do: cons_cad(uf, filter)

  defp cons_cad(uf, filter) do
    ~s(<ConsCad xmlns="#{@nfe_ns}" versao="2.00"><infCons><xServ>CONS-CAD</xServ>) <>
      ~s(<UF>#{uf}</UF>#{cad_filter(filter)}</infCons></ConsCad>)
  end

  defp cad_filter({:tax_id, id}), do: tax_id_element(id)
  defp cad_filter({:ie, ie}), do: ~s(<IE>#{ie}</IE>)

  @doc "A CPF is 11 digits; anything else is treated as a CNPJ."
  @spec tax_id_element(String.t()) :: binary()
  def tax_id_element(tax_id) when byte_size(tax_id) == 11, do: ~s(<CPF>#{tax_id}</CPF>)
  def tax_id_element(tax_id), do: ~s(<CNPJ>#{tax_id}</CNPJ>)

  defp dist_cursor({:ult_nsu, nsu}), do: ~s(<distNSU><ultNSU>#{pad_nsu(nsu)}</ultNSU></distNSU>)
  defp dist_cursor({:nsu, nsu}), do: ~s(<consNSU><NSU>#{pad_nsu(nsu)}</NSU></consNSU>)
  defp dist_cursor({:ch_nfe, key}), do: ~s(<consChNFe><chNFe>#{key}</chNFe></consChNFe>)

  # The AN wants a 15 digit NSU; a caller storing it as an integer string would
  # otherwise silently ask for the wrong page.
  defp pad_nsu(nsu), do: nsu |> to_string() |> String.pad_leading(15, "0")

  defp strip_declaration(xml), do: String.replace(xml, ~r/^\s*<\?xml[^>]*\?>/, "")

  @doc "`tpAmb` for an environment: 1 is production, 2 is homologation."
  @spec tp_amb(:production | :homologation) :: 1 | 2
  def tp_amb(:production), do: 1
  def tp_amb(:homologation), do: 2
end
