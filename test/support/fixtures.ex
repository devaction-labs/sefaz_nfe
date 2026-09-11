defmodule SefazNfe.Fixtures do
  @moduledoc """
  Throwaway A1 files for the test suite.

  Generated with `openssl req -x509 -newkey rsa:2048` and exported to PKCS#12;
  the keys are disposable and exist only in this repository. A real ICP-Brasil
  A1 never belongs in version control — it signs legally binding fiscal
  documents.

  Four shapes, covering what `SefazNfe.Certificate.PKCS12` accepts and what it
  must refuse by name:

    * `a1_3des.pfx` — `PBE-SHA1-3DES` with a SHA-1 MAC and encrypted certificate
      bags. What ICP-Brasil issues today.
    * `a1_aes.pfx` — the OpenSSL 3 default: PBES2/AES-256, SHA-256 MAC. Shares
      a keypair with `a1_3des.pfx`, so the two must decode to the same bytes.
    * `a1_aes_sha1mac.pfx` — PBES2/AES-256 under a SHA-1 MAC.
    * `a1_rc2.pfx` — RC2-40, which the reader does not implement and must
      reject as `{:unsupported_pbe, oid}` rather than as a bad password.
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
