defmodule SefazNfe.Signer do
  @moduledoc """
  Enveloped XMLDSig on `infNFe` / `infEvento`. Digest algorithm is taken from
  the MOC at implementation time — not guessed here.
  """

  @spec sign_nfe(String.t(), SefazNfe.Certificate.t()) :: {:ok, String.t()} | {:error, term()}
  def sign_nfe(xml, %SefazNfe.Certificate{}) when is_binary(xml) do
    {:error, :not_implemented}
  end
end
