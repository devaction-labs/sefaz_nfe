defmodule SefazNfe.CertificateTest do
  use ExUnit.Case, async: true

  alias SefazNfe.Certificate
  alias SefazNfe.Certificate.PKCS12
  alias SefazNfe.Fixtures

  @password Fixtures.password()

  @data <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01>>
  @encrypted_data <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x06>>
  @pbe_3des <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x01, 0x03>>
  @pbes2 <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D>>
  @pbkdf2 <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C>>
  @sha1 <<0x2B, 0x0E, 0x03, 0x02, 0x1A>>
  @hmac_sha1 <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x07>>
  @hmac_sha256 <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09>>
  @aes256 <<0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A>>

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

      assert opts[:cert] == [Fixtures.cert().der | Fixtures.cert().chain]
      assert {:PrivateKeyInfo, key} = opts[:key]
      assert is_binary(key)
      assert is_list(opts[:cacerts])
    end

    test "ssl_options/1 presents the PFX chain but never trusts it" do
      {:ok, cert} = Certificate.load(Fixtures.pfx("a1_chain.pfx"), @password)
      assert [_intermediate, _root] = cert.chain

      opts = Certificate.ssl_options(cert)

      assert opts[:cert] == [cert.der | cert.chain]

      for der <- [cert.der | cert.chain] do
        refute der in opts[:cacerts]
      end
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

  describe "key and certificate pairing" do
    setup do
      {:ok, a} = Certificate.load(Fixtures.pfx("a1_3des.pfx"), @password)
      {:ok, b} = Certificate.load(Fixtures.pfx("a1_icp_pj.pfx"), @password)
      {:ok, chain} = Certificate.load(Fixtures.pfx("a1_chain.pfx"), @password)
      [a: a, b: b, chain: chain]
    end

    test "a key that matches no certificate is refused", %{a: a, b: b} do
      assert {:error, :key_cert_mismatch} =
               PKCS12.collect([{:key, a.key}, {:cert, b.der}])
    end

    test "two private keys are refused", %{a: a, b: b} do
      assert {:error, :multiple_keys} =
               PKCS12.collect([{:key, a.key}, {:key, b.key}, {:cert, a.der}])
    end

    test "an EC key is named, not mistaken for a mismatch", %{a: a} do
      ec =
        :public_key.der_encode(
          :PrivateKeyInfo,
          :public_key.generate_key({:namedCurve, :secp256r1})
        )

      assert {:error, {:unsupported_key, :ec}} = PKCS12.collect([{:key, ec}, {:cert, a.der}])
    end

    test "a key bag that is not a PrivateKeyInfo is bad input", %{a: a} do
      assert {:error, _reason} = PKCS12.collect([{:key, "nope"}, {:cert, a.der}])
    end

    test "the leaf is picked by key whatever the bag order", %{chain: c} do
      [intermediate, root] = c.chain
      key = {:key, c.key}

      for certs <- [
            [c.der, intermediate, root],
            [root, intermediate, c.der],
            [intermediate, root, c.der],
            [root, c.der, intermediate]
          ] do
        bags = Enum.map(certs, &{:cert, &1}) ++ [key]

        assert {:ok, %{der: der, chain: [first, second]}} = PKCS12.collect(bags)
        assert der == c.der
        # issuer after subject: leaf -> intermediate -> root
        assert first == intermediate
        assert second == root
      end
    end

    test "the leaf's issuer link holds in a loaded file", %{chain: c} do
      assert :public_key.pkix_is_issuer(c.der, hd(c.chain))
      assert :public_key.pkix_is_self_signed(List.last(c.chain))
    end

    test "a certificate that OTP cannot read does not hide the real leaf", %{a: a} do
      assert {:ok, %{der: der, chain: ["junk"]}} =
               PKCS12.collect([{:cert, "junk"}, {:cert, a.der}, {:key, a.key}])

      assert der == a.der
    end
  end

  describe "bounds on attacker-controlled work" do
    test "a PFX over 64 KiB is refused before it is read" do
      assert {:error, {:limit_exceeded, :size}} =
               Certificate.load(:binary.copy(<<0>>, 64 * 1024 + 1), @password)
    end

    test "a huge MAC iteration count returns the limit error, fast" do
      assert {:error, {:limit_exceeded, :iterations}} =
               within(fn ->
                 Certificate.load(pfx_with_mac_iterations(4_000_000_000), @password)
               end)

      assert {:error, {:limit_exceeded, :iterations}} =
               within(fn -> Certificate.load(pfx_with_mac_iterations(1_000_001), @password) end)

      assert {:error, {:limit_exceeded, :iterations}} =
               within(fn -> Certificate.load(pfx_with_mac_iterations(0), @password) end)
    end

    test "PBES1 iteration counts are bounded" do
      alg = seq([oid(@pbe_3des), seq([der(4, "saltsalt"), int(2_000_000)])])
      safe = seq([encrypted_info(alg, :binary.copy(<<0>>, 8))])

      assert {:error, {:limit_exceeded, :iterations}} =
               within(fn -> PKCS12.decode_safe(safe, @password) end)
    end

    test "the iterations of all blobs together are bounded" do
      # Each blob is far under the per-call limit; 32 of them cost 2.24M.
      infos = for _ <- 1..32, do: pbes2_info(pad(seq([])), iterations: 70_000)

      assert {:error, {:limit_exceeded, :iterations}} =
               within(fn -> PKCS12.decode_safe(seq(infos), @password) end)

      # ... and a handful of the same blobs is within budget.
      assert {:ok, []} =
               within(fn -> PKCS12.decode_safe(seq(Enum.take(infos, 8)), @password) end)
    end

    test "PBKDF2 iteration counts are bounded" do
      safe = pbes2_safe(pad(seq([])), iterations: 4_000_000_000)

      assert {:error, {:limit_exceeded, :iterations}} =
               within(fn -> PKCS12.decode_safe(safe, @password) end)
    end

    test "a PBKDF2 keyLength other than the cipher's is refused" do
      for length <- [1_000_000_000, 16, 0] do
        safe = pbes2_safe(pad(seq([])), key_length: length)

        assert {:error, {:limit_exceeded, :key_length}} =
                 within(fn -> PKCS12.decode_safe(safe, @password) end)
      end

      assert {:ok, []} = PKCS12.decode_safe(pbes2_safe(pad(seq([])), key_length: 32), @password)
    end

    test "more ContentInfos than a real A1 has" do
      empty = seq([oid(@data), der(0xA0, der(4, seq([])))])

      assert {:ok, []} = PKCS12.decode_safe(seq(List.duplicate(empty, 32)), @password)

      assert {:error, {:limit_exceeded, :bags}} =
               PKCS12.decode_safe(seq(List.duplicate(empty, 33)), @password)
    end

    test "more SafeBags than a real A1 has" do
      bag = seq([oid(<<1, 2, 3>>), der(0xA0, <<>>)])

      info = fn count ->
        seq([seq([oid(@data), der(0xA0, der(4, seq(List.duplicate(bag, count))))])])
      end

      assert {:ok, []} = PKCS12.decode_safe(info.(32), @password)
      assert {:error, {:limit_exceeded, :bags}} = PKCS12.decode_safe(info.(33), @password)
    end

    test "a PFX that is not version 3 is bad input" do
      assert {:error, :invalid_certificate} =
               Certificate.load(pfx_with_mac_iterations(2000, 2), @password)
    end

    test "BER indefinite length is refused, not read as zero" do
      assert {:error, :invalid_certificate} = PKCS12.decode_safe(<<0x30, 0x80, 0, 0>>, @password)
    end
  end

  describe "malformed encryption parameters" do
    test "strict PKCS#7 padding" do
      good = seq([])

      assert {:ok, []} = PKCS12.decode_safe(pbes2_safe(pad(good)), @password)

      for bad <- [
            # pad byte 0, and a pad longer than a block
            good <> :binary.copy(<<0>>, 14),
            good <> :binary.copy(<<17>>, 30),
            # pad bytes that disagree
            good <> :binary.copy(<<3>>, 11) <> <<9, 9, 3>>,
            # pad longer than the plaintext
            :binary.copy(<<0xFF>>, 16)
          ] do
        assert {:error, :invalid_certificate} = PKCS12.decode_safe(pbes2_safe(bad), @password)
      end
    end

    test "a ciphertext that is not a whole number of blocks" do
      alg = seq([oid(@pbe_3des), seq([der(4, "saltsalt"), int(10)])])
      safe = seq([encrypted_info(alg, <<1, 2, 3>>)])

      assert {:error, :invalid_certificate} = PKCS12.decode_safe(safe, @password)
    end

    test "an IV of the wrong length never reaches :crypto" do
      safe = pbes2_safe(pad(seq([])), iv: "short")

      assert {:error, :invalid_certificate} = PKCS12.decode_safe(safe, @password)
    end

    test "an unknown PBKDF2 PRF is named, not silently read as SHA-1" do
      sha384 = <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x0A>>
      safe = pbes2_safe(pad(seq([])), prf: sha384)

      assert {:error, {:unsupported_pbe, ^sha384}} = PKCS12.decode_safe(safe, @password)
    end

    test "SHA-1 and SHA-256 PRFs are accepted" do
      for prf <- [@hmac_sha1, @hmac_sha256] do
        assert {:ok, []} = PKCS12.decode_safe(pbes2_safe(pad(seq([])), prf: prf), @password)
      end
    end

    test "malformed 3DES parameters are not reported as an unsupported algorithm" do
      alg = seq([oid(@pbe_3des), der(5, <<>>)])

      assert {:error, :invalid_certificate} =
               PKCS12.decode_safe(seq([encrypted_info(alg, :binary.copy(<<0>>, 8))]), @password)
    end

    test "an unknown ContentInfo type is bad input, not a CaseClauseError" do
      safe = seq([seq([oid(<<1, 2, 3>>), der(0xA0, <<>>)])])

      assert {:error, :invalid_certificate} = PKCS12.decode_safe(safe, @password)
    end
  end

  describe "hostile bytes" do
    test "flipping bytes of real files never raises" do
      :rand.seed(:exsss, {1, 2, 3})

      files =
        for name <- ["a1_3des.pfx", "a1_aes.pfx"], do: Fixtures.pfx(name)

      started = System.monotonic_time(:millisecond)

      for pfx <- files, _ <- 1..200 do
        position = :rand.uniform(byte_size(pfx)) - 1
        <<head::binary-size(^position), byte, tail::binary>> = pfx
        mutated = <<head::binary, Bitwise.bxor(byte, :rand.uniform(255)), tail::binary>>

        assert match?({:ok, _}, Certificate.load(mutated, @password)) or
                 match?({:error, _}, Certificate.load(mutated, @password))
      end

      assert System.monotonic_time(:millisecond) - started < 10_000
    end

    test "truncating at every length never raises" do
      pfx = Fixtures.pfx("a1_aes.pfx")

      for size <- 0..byte_size(pfx)//37 do
        assert {:error, _reason} = Certificate.load(binary_part(pfx, 0, size), @password)
      end
    end
  end

  describe "passwords" do
    test "invalid UTF-8 is a password error" do
      assert {:error, :invalid_password} =
               Certificate.load(Fixtures.pfx("a1_3des.pfx"), <<0xFF, 0xFE, 0xFD>>)
    end

    test "a non-BMP character is a surrogate pair under PBES1, plain UTF-8 under PBES2" do
      password = "sefaz-🔑-çã"

      assert {:ok, legacy} = Certificate.load(Fixtures.pfx("a1_unicode.pfx"), password)
      assert {:ok, modern} = Certificate.load(Fixtures.pfx("a1_unicode_aes.pfx"), password)
      assert legacy.key == modern.key

      assert {:error, :invalid_password} =
               Certificate.load(Fixtures.pfx("a1_unicode.pfx"), "sefaz-🔒-çã")
    end
  end

  test "inspect never prints the key, the DER or the password" do
    printed = inspect(Fixtures.cert())

    assert printed == "#SefazNfe.Certificate<redacted>"
    refute printed =~ @password
  end

  # DER by hand, so a limit can be tested with a file no real tool would write.

  defp der(tag, body), do: <<tag, der_length(byte_size(body))::binary, body::binary>>

  defp der_length(size) when size < 128, do: <<size>>
  defp der_length(size) when size < 256, do: <<0x81, size>>
  defp der_length(size), do: <<0x82, size::16>>

  defp seq(parts), do: der(0x30, IO.iodata_to_binary(parts))
  defp oid(bytes), do: der(6, bytes)

  defp int(value) do
    bytes = :binary.encode_unsigned(value)
    der(2, if(:binary.first(bytes) >= 128, do: <<0, bytes::binary>>, else: bytes))
  end

  defp pfx_with_mac_iterations(iterations, version \\ 3) do
    mac =
      seq([
        seq([seq([oid(@sha1), <<5, 0>>]), der(4, :binary.copy(<<0>>, 20))]),
        der(4, "salt"),
        int(iterations)
      ])

    seq([int(version), seq([oid(@data), der(0xA0, der(4, seq([])))]), mac])
  end

  defp encrypted_info(alg, ciphertext) do
    seq([
      oid(@encrypted_data),
      der(0xA0, seq([int(0), seq([oid(@data), alg, der(0x80, ciphertext)])]))
    ])
  end

  defp pad(plain) do
    pad = 16 - rem(byte_size(plain), 16)
    plain <> :binary.copy(<<pad>>, pad)
  end

  defp pbes2_safe(plain, opts \\ []), do: seq([pbes2_info(plain, opts)])

  # An EncryptedData ContentInfo under PBES2/AES-256, encrypted for real so the
  # padding check sees what a MAC-verified file would hand it.
  defp pbes2_info(plain, opts) do
    salt = "0123456789abcdef"
    iv = Keyword.get(opts, :iv, :binary.copy(<<7>>, 16))
    prf_oid = Keyword.get(opts, :prf, @hmac_sha256)
    iterations = Keyword.get(opts, :iterations, 10)
    digest = if prf_oid == @hmac_sha1, do: :sha, else: :sha256

    key =
      if iterations <= 1_000_000,
        do: :crypto.pbkdf2_hmac(digest, @password, salt, iterations, 32),
        else: :binary.copy(<<1>>, 32)

    ciphertext =
      :crypto.crypto_one_time(:aes_256_cbc, key, :binary.copy(<<7>>, 16), plain, true)

    key_length = if length = opts[:key_length], do: [int(length)], else: []

    kdf =
      seq([
        oid(@pbkdf2),
        seq([der(4, salt), int(iterations)] ++ key_length ++ [seq([oid(prf_oid), <<5, 0>>])])
      ])

    alg = seq([oid(@pbes2), seq([kdf, seq([oid(@aes256), der(4, iv)])])])
    encrypted_info(alg, ciphertext)
  end

  # A stuck KDF would otherwise hang the suite instead of failing it.
  defp within(fun) do
    task = Task.async(fun)

    case Task.yield(task, to_timeout(second: 2)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      other -> flunk("did not return within 2s: #{inspect(other)}")
    end
  end
end
