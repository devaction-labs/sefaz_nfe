defmodule SefazNfe.Certificate.PKCS12 do
  @moduledoc """
  PKCS#12 (RFC 7292) reader for ICP-Brasil A1 files. Internal to
  `SefazNfe.Certificate`.

  OTP 29 ships no PKCS#12 support — `:public_key` has no `pkcs12_to_der` — and
  Hex has no package for it, so the PFX is walked here: the DER structure by
  hand, `:crypto` for the ciphers.

  ## Scope

  Supported, each verified byte-for-byte against `openssl` output (and, for the
  first, a real A1 file):

    * bag encryption `pbeWithSHAAnd3-KeyTripleDES-CBC` (PKCS#12 KDF, SHA-1) —
      what ICP-Brasil issues today;
    * bag encryption PBES2 (PKCS#5 v2.1) with PBKDF2 and AES-128/192/256-CBC —
      the OpenSSL 3 export default. PBKDF2 PRFs: `hmacWithSHA1`,
      `hmacWithSHA256` and `hmacWithSHA512`;
    * the PKCS#12 MAC with SHA-1 or SHA-256.

  Anything else returns `{:error, {:unsupported_pbe, oid}}`, or
  `{:error, {:unsupported_mac, oid}}` for another digest, rather than an empty
  result that would read as a certificate with no key. Naming the algorithm
  matters: reporting a modern PFX as an invalid password would send the caller
  hunting for the wrong bug.

  The PKCS#12 MAC is required, not optional. Without it a wrong password is
  indistinguishable from a corrupt file, and both must fail before any SOAP
  call. It is compared in constant time.

  ## Hostile input

  The PFX and the password usually come from a user upload, so nothing in the
  file is trusted to size the work. Before any KDF or `:crypto` call:

    * the file is at most 65536 bytes (64 KiB) (a real A1 is about 7 KB) and holds
      at most 32 SafeBags and 32 ContentInfos;
    * every iteration count (MAC, PBES1, PBKDF2) is in `1..1_000_000` (real A1s
      use about 2000), and the sum over the whole file (MAC, PBES1 x3 passes, PBKDF2 x blocks) is at most 2_000_000;
    * a PBKDF2 `keyLength`, when present, equals the cipher's key size;
    * the cipher IV and ciphertext have the sizes the cipher requires.

  Violations return `{:error, {:limit_exceeded, :size | :bags | :iterations |
  :key_length}}`. Padding is checked strictly (PKCS#7, all pad bytes equal), and
  BER indefinite lengths are refused. Any other failure while walking the file
  collapses into `{:error, :invalid_certificate}`: `parse/2` rescues everything
  and never re-raises or keeps the stacktrace, because a `:crypto` error carries
  the derived key or the password in its arguments.

  ## Key and certificate pairing

  A PFX may carry several certificates in any order. The leaf is the one whose
  RSA public key equals the one derived from the private key, so a CA listed
  first is never mistaken for it. No match is `{:error, :key_cert_mismatch}`,
  more than one private key is `{:error, :multiple_keys}` and a non-RSA key is
  `{:error, {:unsupported_key, :ec | :other}}`. The chain holds the remaining
  certificates, issuer after subject where the names link up.

  ## Key derivation

  `kdf/5` is RFC 7292 appendix B.2 with SHA-1: a 20 byte digest over 64 byte
  blocks, diversified by 1 for the key, 2 for the IV and 3 for the MAC
  (appendix B.3). The password is a BMPString — UTF-16BE, surrogate pairs outside the
  BMP as OpenSSL does, with a two byte null terminator. Each block round is `I_j = (I_j + B + 1) mod 2^512`, where the
  modulo falls out of bitstring construction truncating to the declared size.
  """

  @data <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01>>
  @encrypted_data <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x06>>
  @cert_bag <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x03>>
  @shrouded_key_bag <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x02>>
  @key_bag <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x01>>
  @pbe_sha1_3des <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x01, 0x03>>
  @pbes2 <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D>>
  @pbkdf2 <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C>>

  @sha1 <<0x2B, 0x0E, 0x03, 0x02, 0x1A>>
  @sha256 <<0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01>>

  @hmac_sha1 <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x07>>
  @hmac_sha256 <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09>>
  @hmac_sha512 <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x0B>>

  @aes128_cbc <<0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x02>>
  @aes192_cbc <<0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x16>>
  @aes256_cbc <<0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A>>

  @v 64

  @id_key 1
  @id_iv 2
  @id_mac 3

  @max_size 64 * 1024
  @max_iterations 1_000_000
  # Per parse, over every KDF, PBKDF2 and MAC. A real A1 spends 10-20k.
  @max_total_iterations 2_000_000
  @max_bags 32

  @type parsed :: %{der: binary(), key: binary(), chain: [binary()]}

  @doc """
  Decodes `pfx` into the leaf certificate, the PKCS#8 private key and the chain.

  Errors:

    * `{:error, :invalid_password}` — the MAC does not verify, or `password` is
      not valid UTF-8. A MAC mismatch is indistinguishable from a tampered file,
      but a wrong password is by far the common cause.
    * `{:error, :invalid_certificate}` — anything structurally wrong, however it
      surfaces: it is bad input, never a crash.
    * `{:error, {:limit_exceeded, limit}}` — see the module documentation.
    * `{:error, {:unsupported_pbe, oid}}` / `{:error, {:unsupported_mac, oid}}`.
    * `{:error, :key_cert_mismatch | :multiple_keys | {:unsupported_key, kind}}`.
  """
  @spec parse(binary(), String.t()) :: {:ok, parsed()} | {:error, term()}
  def parse(pfx, password) when is_binary(pfx) and is_binary(password) do
    guarded(fn ->
      with {:ok, st} <- credentials(password),
           :ok <- check_size(pfx),
           {:ok, safe_der, mac} <- unwrap(pfx),
           {:ok, st} <- verify_mac(mac, safe_der, st),
           {:ok, bags, _st} <- safes(safe_der, st) do
        collect(bags)
      end
    end)
  end

  @doc false
  # The stage after the MAC: a SafeContents sequence of ContentInfos. Exposed so
  # tests can feed hand-built DER without having to forge a valid MAC.
  @spec decode_safe(binary(), String.t()) :: {:ok, [term()]} | {:error, term()}
  def decode_safe(safe_der, password) when is_binary(safe_der) and is_binary(password) do
    guarded(fn ->
      with {:ok, st} <- credentials(password),
           {:ok, bags, _st} <- safes(safe_der, st),
           do: {:ok, bags}
    end)
  end

  # Whatever goes wrong while walking an attacker's file is bad input. The
  # exception is dropped, not wrapped: a :crypto error carries the derived key or
  # the password in its arguments, and neither may reach a log.
  defp guarded(fun) do
    fun.()
  rescue
    _ -> {:error, :invalid_certificate}
  catch
    _kind, _reason -> {:error, :invalid_certificate}
  end

  defp credentials(password) do
    if String.valid?(password) do
      # BMPString: UTF-16BE, surrogate pairs outside the BMP, two byte terminator.
      bmp = :unicode.characters_to_binary(password, :utf8, {:utf16, :big}) <> <<0, 0>>
      {:ok, %{utf8: password, bmp: bmp, budget: @max_total_iterations}}
    else
      {:error, :invalid_password}
    end
  end

  defp check_size(pfx) when byte_size(pfx) > @max_size, do: {:error, {:limit_exceeded, :size}}
  defp check_size(_pfx), do: :ok

  defp unwrap(pfx) do
    {0x30, body, _} = der(pfx)
    [{2, <<3>>}, {0x30, auth_safe} | mac] = sequence(body)
    [{6, @data}, {0xA0, content}] = sequence(auth_safe)
    {4, safe_der, _} = der(content)
    {:ok, safe_der, mac}
  end

  defp verify_mac([], _safe_der, _pw), do: {:error, :invalid_certificate}

  defp verify_mac([{0x30, mac_data}], safe_der, st) do
    [{0x30, digest_info}, {4, salt} | rest] = sequence(mac_data)
    [{0x30, alg}, {4, expected}] = sequence(digest_info)

    with {:ok, iterations} <- mac_iterations(rest),
         {:ok, st} <- charge(st, iterations),
         :ok <- mac_for(sequence(alg), st, salt, iterations, safe_der, expected) do
      {:ok, st}
    end
  end

  defp mac_for([{6, @sha1} | _params], st, salt, iterations, safe_der, expected),
    do: mac(:sha, 20, st, salt, iterations, safe_der, expected)

  defp mac_for([{6, @sha256} | _params], st, salt, iterations, safe_der, expected),
    do: mac(:sha256, 32, st, salt, iterations, safe_der, expected)

  defp mac_for([{6, oid} | _params], _st, _salt, _iterations, _safe_der, _expected),
    do: {:error, {:unsupported_mac, oid}}

  # The cost of a KDF is accounted before it runs, so a file cannot spend the
  # budget by asking for it.
  defp charge(%{budget: budget} = st, cost) when cost <= budget,
    do: {:ok, %{st | budget: budget - cost}}

  defp charge(_st, _cost), do: {:error, {:limit_exceeded, :iterations}}

  defp mac_iterations([]), do: {:ok, 1}
  defp mac_iterations([{2, value}]), do: iterations(value)

  defp iterations(value) do
    case unsigned(value) do
      count when count in 1..@max_iterations//1 -> {:ok, count}
      _out_of_range -> {:error, {:limit_exceeded, :iterations}}
    end
  end

  defp mac(digest, size, st, salt, iterations, safe_der, expected)
       when byte_size(expected) == size do
    key = kdf(st.bmp, salt, @id_mac, iterations, size, digest)

    if :crypto.hash_equals(:crypto.mac(:hmac, digest, key, safe_der), expected) do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  # A digest of the wrong length cannot be a MAC under that algorithm.
  defp mac(_digest, _size, _pw, _salt, _iterations, _safe_der, _expected),
    do: {:error, :invalid_certificate}

  defp safes(safe_der, st) do
    {0x30, list, _} = der(safe_der)

    with {:ok, infos} <- bounded(sequence(list)) do
      reduce_ok(infos, st, &add_content_info/3)
    end
  end

  defp add_content_info({0x30, content_info}, acc, st) do
    with {:ok, bags, st} <- content_info(content_info, st),
         :ok <- check_bag_count(length(acc) + length(bags)) do
      {:ok, Enum.reverse(bags, acc), st}
    end
  end

  defp bounded(items) when length(items) > @max_bags, do: {:error, {:limit_exceeded, :bags}}
  defp bounded(items), do: {:ok, items}

  defp check_bag_count(count) when count > @max_bags, do: {:error, {:limit_exceeded, :bags}}
  defp check_bag_count(_count), do: :ok

  defp content_info(content_info, st) do
    case sequence(content_info) do
      [{6, @data}, {0xA0, content}] ->
        {4, safe_contents, _} = der(content)
        bags(safe_contents, st)

      [{6, @encrypted_data}, {0xA0, content}] ->
        {0x30, encrypted, _} = der(content)
        [{2, _version}, {0x30, enc_content_info}] = sequence(encrypted)
        [{6, @data}, {0x30, alg}, {0x80, ciphertext}] = sequence(enc_content_info)

        with {:ok, plain, st} <- decrypt(alg, ciphertext, st), do: bags(plain, st)

      _unknown ->
        {:error, :invalid_certificate}
    end
  end

  defp bags(safe_contents, st) do
    {0x30, list, _} = der(safe_contents)

    with {:ok, items} <- bounded(sequence(list)) do
      reduce_ok(items, st, &add_bag/3)
    end
  end

  defp add_bag({0x30, bag}, acc, st) do
    with {:ok, found, st} <- bag(bag, st), do: {:ok, Enum.reverse(found, acc), st}
  end

  defp bag(bag, st) do
    case sequence(bag) do
      [{6, @cert_bag}, {0xA0, value} | _attrs] ->
        {0x30, cert_bag, _} = der(value)
        [{6, _x509}, {0xA0, wrapped}] = sequence(cert_bag)
        {4, cert, _} = der(wrapped)
        {:ok, [{:cert, cert}], st}

      [{6, @shrouded_key_bag}, {0xA0, value} | _attrs] ->
        {0x30, epki, _} = der(value)
        [{0x30, alg}, {4, ciphertext}] = sequence(epki)

        with {:ok, key, st} <- decrypt(alg, ciphertext, st), do: {:ok, [{:key, key}], st}

      [{6, @key_bag}, {0xA0, value} | _attrs] ->
        {0x30, key, _} = der(value)
        {:ok, [{:key, key}], st}

      _other ->
        {:ok, [], st}
    end
  end

  defp decrypt(alg, ciphertext, st) do
    case sequence(alg) do
      [{6, @pbe_sha1_3des}, {0x30, params}] -> pbes1(params, ciphertext, st)
      [{6, @pbes2}, {0x30, params}] -> pbes2(params, ciphertext, st)
      # A known algorithm with the wrong parameters is a broken file, not an
      # algorithm we have not met.
      [{6, oid} | _params] when oid in [@pbe_sha1_3des, @pbes2] -> {:error, :invalid_certificate}
      [{6, oid} | _params] -> {:error, {:unsupported_pbe, oid}}
    end
  end

  defp pbes1(params, ciphertext, st) do
    [{4, salt}, {2, count}] = sequence(params)

    with {:ok, iterations} <- iterations(count),
         :ok <- check_cbc(ciphertext, 8),
         # 24 key bytes take two SHA-1 blocks, the 8 byte IV one more.
         {:ok, st} <- charge(st, 3 * iterations) do
      key = kdf(st.bmp, salt, @id_key, iterations, 24, :sha)
      iv = kdf(st.bmp, salt, @id_iv, iterations, 8, :sha)

      with {:ok, plain} <- cbc(:des_ede3_cbc, key, iv, ciphertext, 8), do: {:ok, plain, st}
    end
  end

  # PBES2 keys the cipher from PKCS#5 PBKDF2 over the UTF-8 password, not from
  # the PKCS#12 KDF over a BMPString. Different derivation, same file format.
  defp pbes2(params, ciphertext, st) do
    [{0x30, kdf_alg}, {0x30, cipher_alg}] = sequence(params)

    with {:ok, cipher, key_size, iv} <- pbes2_cipher(cipher_alg),
         :ok <- check_cbc(ciphertext, 16),
         {:ok, key, st} <- pbkdf2(kdf_alg, st, key_size),
         {:ok, plain} <- cbc(cipher, key, iv, ciphertext, 16) do
      {:ok, plain, st}
    end
  end

  defp pbes2_cipher(alg) do
    case sequence(alg) do
      [{6, @aes128_cbc}, {4, <<_::binary-16>> = iv}] ->
        {:ok, :aes_128_cbc, 16, iv}

      [{6, @aes192_cbc}, {4, <<_::binary-16>> = iv}] ->
        {:ok, :aes_192_cbc, 24, iv}

      [{6, @aes256_cbc}, {4, <<_::binary-16>> = iv}] ->
        {:ok, :aes_256_cbc, 32, iv}

      [{6, oid} | _params] when oid in [@aes128_cbc, @aes192_cbc, @aes256_cbc] ->
        {:error, :invalid_certificate}

      [{6, oid} | _params] ->
        {:error, {:unsupported_pbe, oid}}
    end
  end

  defp pbkdf2(alg, st, key_size) do
    case sequence(alg) do
      [{6, @pbkdf2}, {0x30, params}] ->
        [{4, salt}, {2, count} | rest] = sequence(params)
        {key_length, prf_alg} = pbkdf2_options(rest)

        with {:ok, iterations} <- iterations(count),
             :ok <- check_key_length(key_length, key_size),
             {:ok, prf} <- prf(prf_alg),
             {:ok, st} <- charge(st, iterations * ceil(key_size / hash_size(prf))) do
          {:ok, :crypto.pbkdf2_hmac(prf, st.utf8, salt, iterations, key_size), st}
        end

      [{6, oid} | _params] ->
        {:error, {:unsupported_pbe, oid}}
    end
  end

  # PBKDF2-params: salt, iterationCount, keyLength OPTIONAL, prf DEFAULT sha1.
  defp pbkdf2_options([{2, length}, {0x30, prf}]), do: {length, prf}
  defp pbkdf2_options([{2, length}]), do: {length, nil}
  defp pbkdf2_options([{0x30, prf}]), do: {nil, prf}
  defp pbkdf2_options([]), do: {nil, nil}

  defp check_key_length(nil, _key_size), do: :ok

  defp check_key_length(length, key_size) do
    if unsigned(length) == key_size, do: :ok, else: {:error, {:limit_exceeded, :key_length}}
  end

  defp hash_size(:sha), do: 20
  defp hash_size(:sha256), do: 32
  defp hash_size(:sha512), do: 64

  defp prf(nil), do: {:ok, :sha}

  defp prf(alg) do
    case sequence(alg) do
      [{6, @hmac_sha1} | _params] -> {:ok, :sha}
      [{6, @hmac_sha256} | _params] -> {:ok, :sha256}
      [{6, @hmac_sha512} | _params] -> {:ok, :sha512}
      [{6, oid} | _params] -> {:error, {:unsupported_pbe, oid}}
    end
  end

  defp check_cbc(ciphertext, block)
       when ciphertext != "" and rem(byte_size(ciphertext), block) == 0,
       do: :ok

  defp check_cbc(_ciphertext, _block), do: {:error, :invalid_certificate}

  defp cbc(cipher, key, iv, ciphertext, block) do
    cipher
    |> :crypto.crypto_one_time(key, iv, ciphertext, false)
    |> unpad(block)
  end

  # PKCS#7: 1..block pad bytes, each holding the pad length. The MAC already
  # passed, so a bad pad means a wrong privacy password or corrupt data.
  defp unpad(plain, block) do
    pad = :binary.last(plain)
    body_size = byte_size(plain) - pad

    with true <- pad in 1..block//1,
         <<body::binary-size(^body_size), tail::binary>> <- plain,
         true <- tail == :binary.copy(<<pad>>, pad) do
      {:ok, body}
    else
      _bad_padding -> {:error, :invalid_certificate}
    end
  end

  defp kdf(bmp, salt, id, iterations, needed, digest) do
    d = :binary.copy(<<id>>, @v)
    i = pad_to_block(salt) <> pad_to_block(bmp)
    derive(d, i, iterations, needed, <<>>, digest)
  end

  defp derive(_d, _i, _iterations, needed, acc, _digest) when byte_size(acc) >= needed,
    do: binary_part(acc, 0, needed)

  defp derive(d, i, iterations, needed, acc, digest) do
    a = Enum.reduce(1..iterations//1, d <> i, fn _round, x -> :crypto.hash(digest, x) end)
    b = repeat_to(a, @v)
    i = for <<block::binary-size(@v) <- i>>, into: <<>>, do: add_mod(block, b)
    derive(d, i, iterations, needed, acc <> a, digest)
  end

  defp add_mod(block, b) do
    sum = unsigned(block) + unsigned(b) + 1
    <<sum::big-size(@v)-unit(8)>>
  end

  defp pad_to_block(<<>>), do: <<>>
  defp pad_to_block(bin), do: repeat_to(bin, ceil(byte_size(bin) / @v) * @v)

  defp repeat_to(bin, size) do
    bin
    |> :binary.copy(ceil(size / byte_size(bin)))
    |> binary_part(0, size)
  end

  @doc false
  # Picks the leaf by key, not by position: the certificate whose RSA public key
  # is the one the private key derives. Exposed so tests can reorder bags.
  @spec collect([{:cert | :key, binary()}]) :: {:ok, parsed()} | {:error, term()}
  def collect(bags) do
    case {for({:key, key} <- bags, do: key), for({:cert, der} <- bags, do: der)} do
      {[_first, _second | _more], _certs} -> {:error, :multiple_keys}
      {[], _certs} -> {:error, :invalid_certificate}
      {_keys, []} -> {:error, :invalid_certificate}
      {[key], certs} -> pair(key, certs)
    end
  end

  defp pair(key, certs) do
    with {:ok, public} <- public_numbers(key),
         {:ok, leaf} <- find_leaf(certs, public) do
      {:ok, %{der: leaf, key: key, chain: order_chain(leaf, List.delete(certs, leaf))}}
    end
  end

  defp public_numbers(key) do
    case :public_key.der_decode(:PrivateKeyInfo, key) do
      {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _dp, _dq, _qi, _others} ->
        {:ok, {modulus, exponent}}

      record when is_tuple(record) and elem(record, 0) == :ECPrivateKey ->
        {:error, {:unsupported_key, :ec}}

      _other ->
        {:error, {:unsupported_key, :other}}
    end
  rescue
    _ -> {:error, :invalid_certificate}
  end

  defp find_leaf(certs, public) do
    case Enum.find(certs, &(rsa_public(&1) == public)) do
      nil -> {:error, :key_cert_mismatch}
      leaf -> {:ok, leaf}
    end
  end

  # A certificate OTP cannot read, or that holds another key type, simply is not
  # the leaf; it must not sink a PFX whose real leaf is fine.
  defp rsa_public(der) do
    {:OTPCertificate, tbs, _alg, _signature} = :public_key.pkix_decode_cert(der, :otp)
    {:OTPTBSCertificate, _v, _sn, _sig, _issuer, _validity, _subject, spki, _i, _s, _e} = tbs
    {:OTPSubjectPublicKeyInfo, _alg, {:RSAPublicKey, modulus, exponent}} = spki
    {modulus, exponent}
  rescue
    _ -> nil
  end

  # Leaf, then its issuer, then that one's issuer. Anything that does not link
  # up keeps its original order at the end.
  defp order_chain(subject, pool) do
    case Enum.find(pool, &issuer?(subject, &1)) do
      nil -> pool
      issuer -> [issuer | order_chain(issuer, List.delete(pool, issuer))]
    end
  end

  defp issuer?(subject, candidate) do
    :public_key.pkix_is_issuer(subject, candidate)
  rescue
    _ -> false
  end

  defp der(<<tag, rest::binary>>), do: length_of(tag, rest)

  defp length_of(tag, <<0::1, size::7, rest::binary>>), do: take(tag, size, rest)

  # 0x80 is BER indefinite length, which DER forbids; it has no clause on purpose
  # (a FunctionClauseError, rescued as an invalid file) rather than reading as 0.
  defp length_of(tag, <<1::1, bytes::7, rest::binary>>) when bytes in 1..4//1 do
    <<size::big-size(^bytes)-unit(8), rest::binary>> = rest
    take(tag, size, rest)
  end

  defp take(tag, size, bin) do
    <<value::binary-size(^size), rest::binary>> = bin
    {tag, value, rest}
  end

  defp sequence(bin), do: sequence(bin, [])
  defp sequence(<<>>, acc), do: Enum.reverse(acc)

  defp sequence(bin, acc) do
    {tag, value, rest} = der(bin)
    sequence(rest, [{tag, value} | acc])
  end

  defp unsigned(bin), do: :binary.decode_unsigned(bin)

  # Accumulates newest-first; the callbacks prepend, and this puts the order back.
  # The state (with the iteration budget) is threaded through every step.
  defp reduce_ok(list, st, fun) do
    result =
      Enum.reduce_while(list, {:ok, [], st}, fn item, {:ok, acc, st} ->
        case fun.(item, acc, st) do
          {:ok, next, st} -> {:cont, {:ok, next, st}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, acc, st} <- result, do: {:ok, Enum.reverse(acc), st}
  end
end
