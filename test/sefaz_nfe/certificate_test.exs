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
      assert {:error, :invalid_password} =
               Certificate.load(Fixtures.pfx("a1_3des.pfx"), "not-the-password")
    end

    test "empty input" do
      assert {:error, :invalid_certificate} = Certificate.load("", @password)
      assert {:error, :invalid_password} = Certificate.load("x", "")
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
      assert {:error, :invalid_password} = Certificate.load(Fixtures.pfx("a1_aes.pfx"), "nope")
    end
  end

  describe "validity and tax_id" do
    test "the validity window is read from the leaf as UTC DateTimes" do
      cert = Fixtures.cert()

      assert %DateTime{time_zone: "Etc/UTC"} = cert.not_before
      assert %DateTime{time_zone: "Etc/UTC"} = cert.not_after
      assert DateTime.compare(cert.not_before, cert.not_after) == :lt
      assert cert.not_after.year == 2036
    end

    test "falls back to the CN suffix when there is no ICP-Brasil otherName" do
      assert Fixtures.cert().tax_id == "00000000000191"
    end

    test "CNPJ comes from otherName 2.16.76.1.3.3, ahead of the CN" do
      assert {:ok, cert} = Certificate.load(Fixtures.pfx("a1_icp_pj.pfx"), @password)
      assert cert.tax_id == "11222333000181"
    end

    test "CPF comes from otherName 2.16.76.1.3.1, after the birth date, ahead of the CN" do
      assert {:ok, cert} = Certificate.load(Fixtures.pfx("a1_icp_pf.pfx"), @password)
      assert cert.tax_id == "12345678909"
    end
  end

  describe "load/3 expiry" do
    @far_future ~U[2040-01-01 00:00:00Z]

    test "an expired certificate is refused with the expiry date" do
      assert {:error, {:expired, %DateTime{} = not_after}} =
               Certificate.load(Fixtures.pfx("a1_3des.pfx"), @password, now: @far_future)

      assert not_after == Fixtures.cert().not_after
    end

    test "allow_expired: true loads it anyway" do
      assert {:ok, cert} =
               Certificate.load(Fixtures.pfx("a1_3des.pfx"), @password,
                 now: @far_future,
                 allow_expired: true
               )

      assert Certificate.expired?(cert, @far_future)
    end

    test "a certificate that is not valid yet is refused with its start date" do
      assert {:error, {:not_yet_valid, %DateTime{} = not_before}} =
               Certificate.load(Fixtures.pfx("a1_3des.pfx"), @password,
                 now: ~U[2000-01-01 00:00:00Z]
               )

      assert not_before == Fixtures.cert().not_before
    end

    test "expired?/2 and days_until_expiry/2" do
      cert = Fixtures.cert()
      before_end = DateTime.add(cert.not_after, -10 * 86_400 - 60, :second)
      after_end = DateTime.add(cert.not_after, 3 * 86_400 + 60, :second)

      refute Certificate.expired?(cert, before_end)
      assert Certificate.expired?(cert, after_end)
      assert Certificate.days_until_expiry(cert, before_end) == 10
      assert Certificate.days_until_expiry(cert, after_end) == -4
      assert Certificate.days_until_expiry(cert) > 0
    end
  end

  describe "load/3 error contract" do
    test "empty password is a password error, empty or non-binary pfx is a certificate error" do
      assert {:error, :invalid_password} = Certificate.load(Fixtures.pfx("a1_3des.pfx"), "")
      assert {:error, :invalid_certificate} = Certificate.load("", @password)
      assert {:error, :invalid_certificate} = Certificate.load(nil, @password)
    end

    test "a file with no MAC is a certificate error, not a password error" do
      assert {:error, :invalid_certificate} = Certificate.load(<<0x30, 0x03, 2, 1, 3>>, @password)
    end
  end

  test "inspect never prints the key, the DER or the password" do
    printed = inspect(Fixtures.cert())

    assert printed == "#SefazNfe.Certificate<redacted>"
    refute printed =~ @password
  end
end
