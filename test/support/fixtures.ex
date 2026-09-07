defmodule SefazNfe.Fixtures do
  @moduledoc """
  Throwaway A1 files for the test suite.

  Generated with `openssl req -x509 -newkey rsa:2048` and exported to PKCS#12;
  the keys are disposable and exist only in this repository. A real ICP-Brasil
  A1 never belongs in version control — it signs legally binding fiscal
  documents.

  Three shapes, matching what `SefazNfe.Certificate.PKCS12` does and does not
  accept:

    * `a1_3des.pfx` — `PBE-SHA1-3DES` with a SHA-1 MAC, encrypted certificate
      bags included. What ICP-Brasil issues today, and what the reader supports.
    * `a1_aes.pfx` — the OpenSSL 3 default: PBES2/AES-256 with a SHA-256 MAC.
    * `a1_aes_sha1mac.pfx` — a SHA-1 MAC over PBES2/AES-256 bags, which reaches
      the cipher before failing.
  """

  @password "sefaz-test"

  @spec password() :: String.t()
  def password, do: @password

  @spec pfx(String.t()) :: binary()
  def pfx(name) do
    [__DIR__, "..", "fixtures", name]
    |> Path.join()
    |> Path.expand()
    |> File.read!()
  end

  @spec cert() :: SefazNfe.Certificate.t()
  def cert do
    {:ok, cert} = SefazNfe.Certificate.load(pfx("a1_3des.pfx"), @password)
    cert
  end
end
