defmodule SefazNfe.SOAP do
  @moduledoc """
  HTTP+mTLS POST of a SOAP envelope. `mix test` must never open a socket:
  point `:sefaz_nfe, :soap` at a stub (the default is `NotImplemented`).
  """

  @type cert :: SefazNfe.Certificate.t()

  @callback call(String.t(), iodata(), cert(), keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @spec client() :: module()
  def client do
    Application.get_env(:sefaz_nfe, :soap, SefazNfe.SOAP.NotImplemented)
  end

  defmodule NotImplemented do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(_endpoint, _body, _cert, _opts), do: {:error, :not_implemented}
  end
end
