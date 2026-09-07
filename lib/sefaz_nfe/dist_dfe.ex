defmodule SefazNfe.DistDFe do
  @moduledoc "Page returned by `NFeDistribuicaoDFe` (Ambiente Nacional)."

  defmodule Document do
    @moduledoc false
    @type t :: %__MODULE__{schema: String.t(), nsu: String.t(), xml: String.t()}
    defstruct [:schema, :nsu, :xml]
  end

  @type t :: %__MODULE__{
          ult_nsu: String.t(),
          max_nsu: String.t(),
          c_stat: pos_integer(),
          documents: [Document.t()]
        }

  @enforce_keys [:ult_nsu, :max_nsu, :c_stat]
  defstruct [:ult_nsu, :max_nsu, :c_stat, documents: []]
end
