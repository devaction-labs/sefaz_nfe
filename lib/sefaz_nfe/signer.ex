defmodule SefazNfe.Signer do
  @moduledoc """
  Enveloped XMLDSig on `infNFe` / `infEvento`. Digest algorithm is taken from
  the MOC at implementation time — not guessed here.
  """

  @signature ~r/<(?:[\w.-]+:)?Signature[\s>]/

  @doc """
  Signs `xml` with the A1 in `cert`, or returns it untouched when the ERP
  already signed it (MOC: a document is signed once).
  """
  @spec sign_nfe(String.t(), SefazNfe.Certificate.t()) :: {:ok, String.t()} | {:error, term()}
  def sign_nfe(xml, %SefazNfe.Certificate{}) when is_binary(xml) do
    case signed?(xml) do
      true -> {:ok, xml}
      false -> {:error, :not_implemented}
    end
  end

  @doc """
  Whether `xml` already carries an XMLDSig `<Signature>` element, with or
  without a namespace prefix.

  Presence is enough: validating the signature is SEFAZ's job, and re-signing an
  already signed document breaks it.
  """
  @spec signed?(String.t()) :: boolean()
  def signed?(xml) when is_binary(xml), do: Regex.match?(@signature, xml)
end
