defmodule SefazNfe.Certificate do
  @moduledoc """
  A1 (PKCS#12) handle.

  `load/2` decodes the PFX, so a wrong password fails here — before any SOAP
  call — via the PKCS#12 MAC. The password is never kept on the struct and
  `Inspect` never prints the key or the DER.

  The fields are shaped for the two consumers: `:der` + `:key` + `:chain` feed
  `:ssl` client options for mTLS, and `:der` + `:key` feed XMLDSig.
  """

  alias SefazNfe.Certificate.PKCS12

  @type t :: %__MODULE__{
          der: binary(),
          key: binary(),
          chain: [binary()]
        }

  @enforce_keys [:der, :key]
  defstruct [:der, :key, chain: []]

  @doc """
  Decodes an A1 PFX.

  Returns `{:error, :invalid_certificate}` for an empty input, a wrong password
  (the MAC will not verify) or a structurally broken file, and
  `{:error, {:unsupported_pbe, oid}}` for a PFX encrypted with an algorithm this
  reader has not been verified against.
  """
  @spec load(binary(), String.t()) :: {:ok, t()} | {:error, term()}
  def load(pfx, password) when is_binary(pfx) and is_binary(password) do
    if pfx == "" or password == "" do
      {:error, :invalid_certificate}
    else
      with {:ok, parts} <- PKCS12.parse(pfx, password) do
        {:ok, struct!(__MODULE__, parts)}
      end
    end
  end

  def load(_pfx, _password), do: {:error, :invalid_certificate}

  @doc """
  Client options for an mTLS connection to SEFAZ.

  The private key is handed to `:ssl` as a `PrivateKeyInfo` DER, which is what
  the PKCS#12 shrouded key bag already contains. The A1's own chain goes into
  `:cacerts` because that is where `:ssl` looks when it builds the client chain
  to present.

  ## Trust anchors

  Several SEFAZ endpoints — SP and MT among them — serve certificates issued
  under *Autoridade Certificadora Raiz Brasileira*, which no operating system
  bundle carries. Without that root the handshake fails with `{:tls,
  :unknown_ca}`, and the fix is to supply it rather than to stop verifying:

      config :sefaz_nfe, :cacerts, "/etc/ssl/icp-brasil.pem"

  The value is a path to a PEM bundle or a list of DER binaries. It is added to
  the trust anchors, never replacing the system bundle, since other UFs chain
  to ordinary commercial roots.

  This library ships no trust anchors of its own on purpose: a CA bundle
  vendored from an unverified download is a man-in-the-middle waiting to
  happen. Fetch the roots from the ITI repository and check their fingerprints
  before installing them.
  """
  @spec ssl_options(t()) :: keyword()
  def ssl_options(%__MODULE__{} = cert) do
    [
      cert: cert.der,
      key: {:PrivateKeyInfo, cert.key},
      cacerts: cert.chain ++ extra_cacerts() ++ :public_key.cacerts_get()
    ]
  end

  @doc "DER trust anchors from `config :sefaz_nfe, :cacerts`."
  @spec extra_cacerts() :: [binary()]
  def extra_cacerts do
    case Application.get_env(:sefaz_nfe, :cacerts) do
      nil -> []
      ders when is_list(ders) -> ders
      path when is_binary(path) -> cached_pem(path)
    end
  end

  defp cached_pem(path) do
    key = {__MODULE__, :cacerts, path}

    case :persistent_term.get(key, nil) do
      nil ->
        ders = for {:Certificate, der, :not_encrypted} <- decode_pem(path), do: der
        :persistent_term.put(key, ders)
        ders

      ders ->
        ders
    end
  end

  defp decode_pem(path) do
    case File.read(path) do
      {:ok, pem} -> :public_key.pem_decode(pem)
      {:error, _reason} -> []
    end
  end

  defimpl Inspect do
    def inspect(%SefazNfe.Certificate{}, _opts), do: "#SefazNfe.Certificate<redacted>"
  end
end
