defmodule SefazNfe.Result do
  @moduledoc """
  Parsed SEFAZ business outcome. A SOAP envelope that we understood is
  `{:ok, t}` even when `c_stat != 100` — that is a rejection, not a crash.
  """

  @type status :: :autorizada | :lote_recebido | :rejeitada | :processando

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
end
