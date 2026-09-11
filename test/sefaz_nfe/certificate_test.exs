defmodule SefazNfe.CertificateTest do
  use ExUnit.Case, async: true

  alias SefazNfe.Certificate
  alias SefazNfe.Fixtures

  @password Fixtures.password()

  describe "load/2 with a supported A1" do
    test "returns the leaf, the private key and the chain" do
      assert {:ok, cert} = Certificate.load(Fixtures.pfx("a1_3des.pfx"), @password)

      assert is_binary(cert.der)
      assert is_binary(cert.key)
      assert is_list(cert.chain)
    end

    test "the leaf really is an X.509 the OTP decoder accepts" do
      cert = Fixtures.cert()

      assert {:OTPCertificate, _tbs, _alg, _sig} = :public_key.pkix_decode_cert(cert.der, :otp)
    end

    test "the private key signs, and the leaf verifies the signature" do
      cert = Fixtures.cert()

      key = :public_key.der_decode(:PrivateKeyInfo, cert.key)
      signature = :public_key.sign("nfe", :sha256, key)

      public =
        cert.der
        |> :public_key.pkix_decode_cert(:otp)
        |> elem(1)
        |> elem(7)
        |> elem(2)

      assert :public_key.verify("nfe", :sha256, signature, public)
    end

    test "ssl_options/1 hands :ssl a usable client identity" do
      opts = Certificate.ssl_options(Fixtures.cert())

      assert opts[:cert] == Fixtures.cert().der
      assert {:PrivateKeyInfo, key} = opts[:key]
      assert is_binary(key)
      assert is_list(opts[:cacerts])
    end
  end

  describe "load/2 rejections" do
    test "a wrong password fails on the MAC, before any SOAP call" do
      assert {:error, :invalid_certificate} =
               Certificate.load(Fixtures.pfx("a1_3des.pfx"), "not-the-password")
    end

    test "empty input" do
      assert {:error, :invalid_certificate} = Certificate.load("", @password)
      assert {:error, :invalid_certificate} = Certificate.load("x", "")
      assert {:error, :invalid_certificate} = Certificate.load(nil, @password)
    end

    test "a truncated file is bad input, not a crash" do
      truncated = binary_part(Fixtures.pfx("a1_3des.pfx"), 0, 400)

      assert {:error, :invalid_certificate} = Certificate.load(truncated, @password)
    end

    test "random bytes are bad input, not a crash" do
      assert {:error, :invalid_certificate} =
               Certificate.load(:crypto.strong_rand_bytes(2000), @password)
    end
  end

  describe "load/2 across PKCS#12 encryption schemes" do
    test "PBES2 with AES-256 and a SHA-256 MAC, the OpenSSL 3 export default" do
      assert {:ok, cert} = Certificate.load(Fixtures.pfx("a1_aes.pfx"), @password)
      assert byte_size(cert.key) > 0
    end

    test "PBES2 with AES-256 under a SHA-1 MAC" do
      assert {:ok, cert} = Certificate.load(Fixtures.pfx("a1_aes_sha1mac.pfx"), @password)
      assert byte_size(cert.key) > 0
    end

    test "PBES1 with 3DES, which is what ICP-Brasil issues" do
      assert {:ok, cert} = Certificate.load(Fixtures.pfx("a1_3des.pfx"), @password)
      assert byte_size(cert.key) > 0
    end

    test "the same keypair decodes identically whichever scheme wrapped it" do
      {:ok, legacy} = Certificate.load(Fixtures.pfx("a1_3des.pfx"), @password)
      {:ok, modern} = Certificate.load(Fixtures.pfx("a1_aes.pfx"), @password)

      assert legacy.key == modern.key
      assert legacy.der == modern.der
    end

    test "an unsupported cipher is named, never reported as a bad password" do
      assert {:error, {:unsupported_pbe, _oid}} =
               Certificate.load(Fixtures.pfx("a1_rc2.pfx"), @password)
    end

    test "a wrong password is still told apart from an unsupported algorithm" do
      assert {:error, :invalid_certificate} = Certificate.load(Fixtures.pfx("a1_aes.pfx"), "nope")
    end
  end

  test "inspect never prints the key, the DER or the password" do
    printed = inspect(Fixtures.cert())

    assert printed == "#SefazNfe.Certificate<redacted>"
    refute printed =~ @password
  end
end
