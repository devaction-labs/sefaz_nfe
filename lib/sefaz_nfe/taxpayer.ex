defmodule SefazNfe.Taxpayer do
  @moduledoc """
  One `infCad` of a `NFeConsultaCadastro` answer.

  Field names are the XSD's, in snake_case (AD-008). Values stay strings, as
  SEFAZ sent them (dates are `AAAA-MM-DD`), except the two coded fields below,
  which are integers; any field the authorizer left out is `nil`.

  `c_sit` (`cSit`):

    * `0` - not enabled (nao habilitado)
    * `1` - enabled (habilitado)

  `ind_cred_nfe` / `ind_cred_cte` (`indCredNFe` / `indCredCTe`):

    * `0` - not accredited
    * `1` - accredited
    * `2` - accredited with full obligation
    * `3` - accredited with partial obligation
    * `4` - SEFAZ does not provide the information

  `address` is a map with `x_lgr, nro, x_cpl, x_bairro, c_mun, x_mun, cep`
  (`ender`), or `nil` when SEFAZ sent none.
  """

  @type address :: %{
          x_lgr: String.t() | nil,
          nro: String.t() | nil,
          x_cpl: String.t() | nil,
          x_bairro: String.t() | nil,
          c_mun: String.t() | nil,
          x_mun: String.t() | nil,
          cep: String.t() | nil
        }

  @type t :: %__MODULE__{
          ie: String.t() | nil,
          cnpj: String.t() | nil,
          cpf: String.t() | nil,
          uf: String.t() | nil,
          c_sit: 0 | 1 | nil,
          ind_cred_nfe: 0..4 | nil,
          ind_cred_cte: 0..4 | nil,
          x_nome: String.t() | nil,
          x_fant: String.t() | nil,
          x_reg_apur: String.t() | nil,
          cnae: String.t() | nil,
          d_ini_ativ: String.t() | nil,
          d_ult_sit: String.t() | nil,
          d_baixa: String.t() | nil,
          ie_unica: String.t() | nil,
          ie_atual: String.t() | nil,
          address: address() | nil
        }

  defstruct [
    :ie,
    :cnpj,
    :cpf,
    :uf,
    :c_sit,
    :ind_cred_nfe,
    :ind_cred_cte,
    :x_nome,
    :x_fant,
    :x_reg_apur,
    :cnae,
    :d_ini_ativ,
    :d_ult_sit,
    :d_baixa,
    :ie_unica,
    :ie_atual,
    :address
  ]
end
