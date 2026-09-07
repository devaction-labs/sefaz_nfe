defmodule SefazNfe.Certificate do
  @moduledoc """
  A1 (PKCS#12) handle. The password is not kept on the struct after `load/2`
  and `Inspect` never prints the DER.
  """

  @type t :: %__MODULE__{der: binary()}
  defstruct [:der]

  @spec load(binary(), String.t()) :: {:ok, t()} | {:error, :invalid_certificate}
  def load(pfx, password) when is_binary(pfx) and is_binary(password) do
    if pfx == "" or password == "" do
      {:error, :invalid_certificate}
    else
      {:ok, %__MODULE__{der: pfx}}
    end
  end

  def load(_, _), do: {:error, :invalid_certificate}

  defimpl Inspect do
    def inspect(%SefazNfe.Certificate{}, _opts), do: "#SefazNfe.Certificate<redacted>"
  end
end
