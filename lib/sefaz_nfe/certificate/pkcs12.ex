defmodule SefazNfe.Certificate.PKCS12 do
  @moduledoc """
  PKCS#12 (RFC 7292) reader for ICP-Brasil A1 files. Internal to
  `SefazNfe.Certificate`.

  OTP 29 ships no PKCS#12 support — `:public_key` has no `pkcs12_to_der` — and
  Hex has no package for it, so the PFX is walked here: the DER structure by
  hand, `:crypto` for the ciphers.

  ## Scope

  Only algorithms verified byte-for-byte against a real A1 file are accepted:
  `pbeWithSHAAnd3-KeyTripleDES-CBC`, which is what ICP-Brasil issues today.
  Anything else returns `{:error, {:unsupported_pbe, oid}}`, or
  `{:error, {:unsupported_mac, oid}}` for a digest other than SHA-1, rather than
  an empty result that would read as a certificate with no key. Naming the
  algorithm matters: reporting a modern PFX as an invalid password would send
  the caller hunting for the wrong bug.

  The PKCS#12 MAC is required, not optional. Without it a wrong password is
  indistinguishable from a corrupt file, and both must fail before any SOAP
  call.

  ## Key derivation

  `kdf/5` is RFC 7292 appendix B.2 with SHA-1: a 20 byte digest over 64 byte
  blocks, diversified by 1 for the key, 2 for the IV and 3 for the MAC
  (appendix B.3). The password is a BMPString — UTF-16BE with a two byte null
  terminator. Each block round is `I_j = (I_j + B + 1) mod 2^512`, where the
  modulo falls out of bitstring construction truncating to the declared size.
  """

  @data <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01>>
  @encrypted_data <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x06>>
  @cert_bag <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x03>>
  @shrouded_key_bag <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x02>>
  @key_bag <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x01>>
  @pbe_sha1_3des <<0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x01, 0x03>>
  @sha1 <<0x2B, 0x0E, 0x03, 0x02, 0x1A>>

  @u 20
  @v 64

  @id_key 1
  @id_iv 2
  @id_mac 3

  @type parsed :: %{der: binary(), key: binary(), chain: [binary()]}

  @doc """
  Decodes `pfx` into the leaf certificate, the PKCS#8 private key and the chain.

  A structurally broken PFX fails pattern matching deep in the DER walk; that is
  bad input rather than a caller bug, so it is rescued into
  `{:error, :invalid_certificate}` like a wrong password.
  """
  @spec parse(binary(), String.t()) :: {:ok, parsed()} | {:error, term()}
  def parse(pfx, password) when is_binary(pfx) and is_binary(password) do
    bmp = bmp_string(password)

    with {:ok, safe_der, mac} <- unwrap(pfx),
         :ok <- verify_mac(mac, safe_der, bmp),
         {:ok, bags} <- safes(safe_der, bmp) do
      collect(bags)
    end
  rescue
    _ in [MatchError, ArgumentError, FunctionClauseError] ->
      {:error, :invalid_certificate}
  end

  defp unwrap(pfx) do
    {0x30, body, _} = der(pfx)
    [{2, _version}, {0x30, auth_safe} | mac] = sequence(body)
    [{6, @data}, {0xA0, content}] = sequence(auth_safe)
    {4, safe_der, _} = der(content)
    {:ok, safe_der, mac}
  end

  defp verify_mac([], _safe_der, _bmp), do: {:error, :invalid_certificate}

  defp verify_mac([{0x30, mac_data}], safe_der, bmp) do
    [{0x30, digest_info}, {4, salt} | rest] = sequence(mac_data)
    [{0x30, alg}, {4, expected}] = sequence(digest_info)

    iterations =
      case rest do
        [{2, value}] -> unsigned(value)
        [] -> 1
      end

    case sequence(alg) do
      [{6, @sha1} | _params] ->
        key = kdf(bmp, salt, @id_mac, iterations, @u)

        case :crypto.mac(:hmac, :sha, key, safe_der) do
          ^expected -> :ok
          _mismatch -> {:error, :invalid_certificate}
        end

      [{6, oid} | _params] ->
        {:error, {:unsupported_mac, oid}}
    end
  end

  defp safes(safe_der, bmp) do
    {0x30, list, _} = der(safe_der)

    list
    |> sequence()
    |> reduce_ok(fn {0x30, content_info}, acc ->
      with {:ok, bags} <- content_info(content_info, bmp), do: {:ok, acc ++ bags}
    end)
  end

  defp content_info(content_info, bmp) do
    case sequence(content_info) do
      [{6, @data}, {0xA0, content}] ->
        {4, safe_contents, _} = der(content)
        bags(safe_contents, bmp)

      [{6, @encrypted_data}, {0xA0, content}] ->
        {0x30, encrypted, _} = der(content)
        [{2, _version}, {0x30, enc_content_info}] = sequence(encrypted)
        [{6, @data}, {0x30, alg}, {0x80, ciphertext}] = sequence(enc_content_info)

        with {:ok, plain} <- decrypt(alg, ciphertext, bmp), do: bags(plain, bmp)
    end
  end

  defp bags(safe_contents, bmp) do
    {0x30, list, _} = der(safe_contents)

    list
    |> sequence()
    |> reduce_ok(fn {0x30, bag}, acc ->
      with {:ok, found} <- bag(bag, bmp), do: {:ok, acc ++ found}
    end)
  end

  defp bag(bag, bmp) do
    case sequence(bag) do
      [{6, @cert_bag}, {0xA0, value} | _attrs] ->
        {0x30, cert_bag, _} = der(value)
        [{6, _x509}, {0xA0, wrapped}] = sequence(cert_bag)
        {4, cert, _} = der(wrapped)
        {:ok, [{:cert, cert}]}

      [{6, @shrouded_key_bag}, {0xA0, value} | _attrs] ->
        {0x30, epki, _} = der(value)
        [{0x30, alg}, {4, ciphertext}] = sequence(epki)

        with {:ok, key} <- decrypt(alg, ciphertext, bmp), do: {:ok, [{:key, key}]}

      [{6, @key_bag}, {0xA0, value} | _attrs] ->
        {0x30, key, _} = der(value)
        {:ok, [{:key, key}]}

      _other ->
        {:ok, []}
    end
  end

  defp decrypt(alg, ciphertext, bmp) do
    case sequence(alg) do
      [{6, @pbe_sha1_3des}, {0x30, params}] ->
        [{4, salt}, {2, iterations}] = sequence(params)
        iterations = unsigned(iterations)
        key = kdf(bmp, salt, @id_key, iterations, 24)
        iv = kdf(bmp, salt, @id_iv, iterations, 8)

        {:ok, unpad(:crypto.crypto_one_time(:des_ede3_cbc, key, iv, ciphertext, false))}

      [{6, oid} | _params] ->
        {:error, {:unsupported_pbe, oid}}
    end
  end

  defp kdf(bmp, salt, id, iterations, needed) do
    d = :binary.copy(<<id>>, @v)
    i = pad_to_block(salt) <> pad_to_block(bmp)
    derive(d, i, iterations, needed, <<>>)
  end

  defp derive(_d, _i, _iterations, needed, acc) when byte_size(acc) >= needed,
    do: binary_part(acc, 0, needed)

  defp derive(d, i, iterations, needed, acc) do
    a = Enum.reduce(1..iterations, d <> i, fn _round, x -> :crypto.hash(:sha, x) end)
    b = repeat_to(a, @v)
    i = for <<block::binary-size(@v) <- i>>, into: <<>>, do: add_mod(block, b)
    derive(d, i, iterations, needed, acc <> a)
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

  defp bmp_string(password) do
    encoded = for <<codepoint::utf8 <- password>>, into: <<>>, do: <<codepoint::big-16>>
    encoded <> <<0, 0>>
  end

  defp collect(bags) do
    certs = for {:cert, der} <- bags, do: der

    case {Enum.find(bags, &match?({:key, _}, &1)), certs} do
      {{:key, key}, [leaf | chain]} -> {:ok, %{der: leaf, key: key, chain: chain}}
      {nil, _certs} -> {:error, :invalid_certificate}
      {_key, []} -> {:error, :invalid_certificate}
    end
  end

  defp der(<<tag, rest::binary>>), do: length_of(tag, rest)

  defp length_of(tag, <<0::1, size::7, rest::binary>>), do: take(tag, size, rest)

  defp length_of(tag, <<1::1, bytes::7, rest::binary>>) do
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

  defp unpad(bin) do
    padding = :binary.last(bin)
    binary_part(bin, 0, byte_size(bin) - padding)
  end

  defp reduce_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
