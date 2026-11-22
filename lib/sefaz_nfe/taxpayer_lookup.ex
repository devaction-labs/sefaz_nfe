defmodule SefazNfe.TaxpayerLookup do
  @moduledoc """
  Answer of `NFeConsultaCadastro` (`retConsCad/infCons`).

  `c_stat` 111 means one record was found and 112 several. Anything else is a
  business outcome and still `{:ok, lookup}` with `taxpayers: []` - 259 (not
  registered) is the usual one - exactly as `SefazNfe.Result` treats a
  rejection. Only a SOAP fault or an unreadable body is an error.

  See `SefazNfe.Taxpayer` for the record, including the meaning of `cSit`,
  `indCredNFe` and `indCredCTe`.
  """

  alias SefazNfe.SOAP.Fault
  alias SefazNfe.Taxpayer
  alias SefazNfe.XML

  @type t :: %__MODULE__{
          c_stat: pos_integer(),
          x_motivo: String.t(),
          uf: String.t() | nil,
          dh_cons: String.t() | nil,
          taxpayers: [Taxpayer.t()]
        }

  @enforce_keys [:c_stat]
  defstruct [:c_stat, :uf, :dh_cons, x_motivo: "", taxpayers: []]

  @doc "Parses a `retConsCad` response."
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(body) when is_binary(body) do
    with {:ok, doc} <- XML.parse(body),
         :ok <- Fault.check(doc) do
      lookup(doc)
    end
  end

  defp lookup(doc) do
    case XML.integer(doc, "cStat") do
      nil ->
        {:error, {:xml, :no_c_stat}}

      c_stat ->
        {:ok,
         %__MODULE__{
           c_stat: c_stat,
           x_motivo: XML.text(doc, "xMotivo") || "",
           uf: text(doc, "UF"),
           dh_cons: text(doc, "dhCons"),
           taxpayers: doc |> XML.all("infCad") |> Enum.map(&taxpayer/1)
         }}
    end
  end

  defp taxpayer(element) do
    %Taxpayer{
      ie: text(element, "IE"),
      cnpj: text(element, "CNPJ"),
      cpf: text(element, "CPF"),
      uf: text(element, "UF"),
      c_sit: XML.integer(element, "cSit"),
      ind_cred_nfe: XML.integer(element, "indCredNFe"),
      ind_cred_cte: XML.integer(element, "indCredCTe"),
      x_nome: text(element, "xNome"),
      x_fant: text(element, "xFant"),
      x_reg_apur: text(element, "xRegApur"),
      cnae: text(element, "CNAE"),
      d_ini_ativ: text(element, "dIniAtiv"),
      d_ult_sit: text(element, "dUltSit"),
      d_baixa: text(element, "dBaixa"),
      ie_unica: text(element, "IEUnica"),
      ie_atual: text(element, "IEAtual"),
      address: address(element)
    }
  end

  defp address(element) do
    case XML.element(element, "ender") do
      nil ->
        nil

      ender ->
        %{
          x_lgr: text(ender, "xLgr"),
          nro: text(ender, "nro"),
          x_cpl: text(ender, "xCpl"),
          x_bairro: text(ender, "xBairro"),
          c_mun: text(ender, "cMun"),
          x_mun: text(ender, "xMun"),
          cep: text(ender, "CEP")
        }
    end
  end

  # An element SEFAZ sent empty is as absent as one it left out.
  defp text(element, name) do
    case XML.text(element, name) do
      "" -> nil
      text -> text
    end
  end
end
