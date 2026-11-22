defmodule SefazNfe.Certificate do
  @moduledoc """
  A1 (PKCS#12) handle.

  `load/3` decodes the PFX, so a wrong password or an expired certificate fails
  here — before any SOAP call. The password is never kept on the struct and
  `Inspect` never prints the key or the DER.

  The fields are shaped for the two consumers: `:der` + `:key` + `:chain` feed
  `:ssl` client options for mTLS, and `:der` + `:key` feed XMLDSig. The
  leaf's validity window and the holder's tax ID are read from the certificate
  as well:

    * `:not_before` / `:not_after` — `DateTime` in UTC.
    * `:tax_id` — the holder's CNPJ or CPF, or `nil` when none can be found. It
      comes from the ICP-Brasil `subjectAltName` otherName `2.16.76.1.3.3`
      (CNPJ) or `2.16.76.1.3.1` (CPF, after the 8 digit birth date) and falls
      back to the suffix after the last `":"` in the CN when that is 11 or 14
      characters of `[A-Z0-9]`.

  ## Errors

  `load/3` returns:

    * `{:error, :invalid_password}` — the password is empty, is not valid UTF-8
      or the PKCS#12 MAC does not verify. A MAC mismatch is cryptographically indistinguishable
      from a tampered file, but a wrong password is by far the common cause.
    * `{:error, :invalid_certificate}` — the input is empty or not a binary, or
      the file is structurally broken, has no MAC, no private key or no
      certificate.
    * `{:error, {:unsupported_pbe, oid}}` / `{:error, {:unsupported_mac, oid}}` —
      an algorithm this reader has not been verified against.
    * `{:error, {:limit_exceeded, :size | :bags | :iterations | :key_length}}` —
      the file asks for more work or space than a real A1 ever does (see
      `SefazNfe.Certificate.PKCS12`).
    * `{:error, :key_cert_mismatch}` — no certificate in the file carries the
      public key of the private key; `{:error, :multiple_keys}` — the file holds
      more than one private key; `{:error, {:unsupported_key, :ec | :other}}` —
      the key is not RSA.
    * `{:error, {:expired, not_after}}` / `{:error, {:not_yet_valid,
      not_before}}` — the validity window does not contain the current time,
      unless `allow_expired: true`.
  """

  alias SefazNfe.Certificate.PKCS12

  @type t :: %__MODULE__{
          der: binary(),
          key: binary(),
          chain: [binary()],
          not_before: DateTime.t() | nil,
          not_after: DateTime.t() | nil,
          tax_id: String.t() | nil
        }

  @type load_error ::
          :invalid_password
          | :invalid_certificate
          | {:unsupported_pbe, binary()}
          | {:unsupported_mac, binary()}
          | {:limit_exceeded, :size | :bags | :iterations | :key_length}
          | :key_cert_mismatch
          | :multiple_keys
          | {:unsupported_key, :ec | :other}
          | {:expired, DateTime.t()}
          | {:not_yet_valid, DateTime.t()}

  @enforce_keys [:der, :key]
  defstruct [:der, :key, :not_before, :not_after, :tax_id, chain: []]

  @oid_cnpj {2, 16, 76, 1, 3, 3}
  @oid_cpf {2, 16, 76, 1, 3, 1}
  @oid_san {2, 5, 29, 17}
  @oid_cn {2, 5, 4, 3}

  @doc """
  Decodes an A1 PFX.

  ## Options

    * `:allow_expired` — load a certificate outside its validity window anyway
      (to inspect it, or to tell the user when it expired). Default `false`.
    * `:now` — a `DateTime` that replaces the clock, for tests. Default
      `DateTime.utc_now()`.

  See the module documentation for the error contract.
  """
  @spec load(binary(), String.t(), keyword()) :: {:ok, t()} | {:error, load_error()}
  def load(pfx, password, opts \\ [])

  def load(pfx, password, opts) when is_binary(pfx) and is_binary(password) do
    cond do
      password == "" ->
        {:error, :invalid_password}

      pfx == "" ->
        {:error, :invalid_certificate}

      true ->
        with {:ok, parts} <- PKCS12.parse(pfx, password),
             {:ok, cert} <- build(parts),
             :ok <- check_validity(cert, opts) do
          {:ok, cert}
        end
    end
  end

  def load(_pfx, _password, _opts), do: {:error, :invalid_certificate}

  @doc "Whether `now` is past the leaf's `not_after`."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{} = cert, now \\ DateTime.utc_now()) do
    DateTime.compare(now, cert.not_after) == :gt
  end

  @doc "Whole days from `now` until `not_after`; negative once expired."
  @spec days_until_expiry(t(), DateTime.t()) :: integer()
  def days_until_expiry(%__MODULE__{} = cert, now \\ DateTime.utc_now()) do
    cert.not_after |> DateTime.diff(now, :second) |> Integer.floor_div(86_400)
  end

  defp check_validity(cert, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    cond do
      Keyword.get(opts, :allow_expired, false) -> :ok
      expired?(cert, now) -> {:error, {:expired, cert.not_after}}
      DateTime.compare(now, cert.not_before) == :lt -> {:error, {:not_yet_valid, cert.not_before}}
      true -> :ok
    end
  end

  defp build(parts) do
    with {:ok, details} <- details(parts.der) do
      {:ok, struct!(__MODULE__, Map.merge(parts, details))}
    end
  end

  # A leaf OTP cannot decode is bad input, the same as a broken PKCS#12. The
  # exception is dropped, never re-raised, so no stacktrace carries the DER.
  defp details(der) do
    {:OTPCertificate, tbs, _alg, _signature} = :public_key.pkix_decode_cert(der, :otp)
    {:OTPTBSCertificate, _v, _sn, _sig, _issuer, validity, subject, _spki, _i, _s, exts} = tbs
    {:Validity, not_before, not_after} = validity

    {:ok,
     %{
       not_before: to_datetime(not_before),
       not_after: to_datetime(not_after),
       tax_id: tax_id(exts, subject)
     }}
  rescue
    _ -> {:error, :invalid_certificate}
  catch
    _kind, _reason -> {:error, :invalid_certificate}
  end

  # RFC 5280: utcTime has a two digit year, 50..99 meaning 19xx and 00..49 20xx.
  defp to_datetime({:utcTime, chars}) do
    <<yy::binary-2, rest::binary>> = List.to_string(chars)
    year = String.to_integer(yy)
    century = if year >= 50, do: "19", else: "20"
    to_datetime({:generalTime, String.to_charlist(century <> yy <> rest)})
  end

  defp to_datetime({:generalTime, chars}) do
    <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, "Z">> =
      List.to_string(chars)

    [year, month, day, hour, minute, second] =
      Enum.map([y, mo, d, h, mi, s], &String.to_integer/1)

    {:ok, naive} = NaiveDateTime.new(year, month, day, hour, minute, second)
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  defp tax_id(exts, subject) do
    other_names = other_names(exts)

    cnpj(other_names) || cpf(other_names) || common_name_suffix(subject)
  end

  defp other_names(exts) when is_list(exts) do
    for {:Extension, @oid_san, _critical, names} when is_list(names) <- exts,
        {:otherName, {_type, oid, value}} <- names,
        into: %{},
        do: {oid, der_string(value)}
  end

  defp other_names(_exts), do: %{}

  # The otherName value is a DER string: UTF8String, PrintableString or IA5String.
  defp der_string(<<tag, len, text::binary-size(len)>>)
       when tag in [0x0C, 0x13, 0x16] and len < 128,
       do: text

  defp der_string(_other), do: nil

  defp cnpj(%{@oid_cnpj => <<id::binary-14>>}), do: valid_id(id)
  defp cnpj(_other_names), do: nil

  defp cpf(%{@oid_cpf => <<_birth::binary-8, id::binary-11, _rest::binary>>}), do: valid_id(id)
  defp cpf(_other_names), do: nil

  defp common_name_suffix({:rdnSequence, rdns}) do
    Enum.find_value(rdns, fn rdn ->
      Enum.find_value(rdn, fn
        {:AttributeTypeAndValue, @oid_cn, value} -> cn_id(directory_string(value))
        _other -> nil
      end)
    end)
  end

  defp common_name_suffix(_subject), do: nil

  defp cn_id(text) when is_binary(text) do
    case String.split(text, ":") do
      [_name, _ | _] = parts -> valid_id(List.last(parts))
      _no_colon -> nil
    end
  end

  defp cn_id(_other), do: nil

  defp directory_string({_type, text}) when is_binary(text), do: text
  defp directory_string({_type, text}) when is_list(text), do: List.to_string(text)
  defp directory_string(_other), do: nil

  defp valid_id(id) when byte_size(id) in [11, 14] do
    if id =~ ~r/\A[A-Z0-9]+\z/, do: id
  end

  defp valid_id(_id), do: nil

  @doc """
  Client options for an mTLS connection to SEFAZ.

  The private key is handed to `:ssl` as a `PrivateKeyInfo` DER, which is what
  the PKCS#12 shrouded key bag already contains. The leaf and the A1's own
  chain go into `:cert` as the client chain to present. They are deliberately
  **not** in `:cacerts`: there `:ssl` keeps the trust store that verifies the
  *server*, and the PFX is usually an upload, so every certificate inside it
  would otherwise become a trusted root.

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
      cert: [cert.der | cert.chain],
      key: {:PrivateKeyInfo, cert.key},
      cacerts: extra_cacerts() ++ :public_key.cacerts_get()
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
      nil -> read_pem(path, key)
      ders -> ders
    end
  end

  # Only a successful, non-empty read is cached: a file that was missing or
  # unreadable a moment ago must be tried again, not pinned as "no anchors".
  defp read_pem(path, key) do
    with {:ok, pem} <- File.read(path),
         [_first | _rest] = ders <-
           for({:Certificate, der, :not_encrypted} <- pem_decode(pem), do: der) do
      :persistent_term.put(key, ders)
      ders
    else
      _unreadable_or_empty -> []
    end
  end

  defp pem_decode(pem) do
    :public_key.pem_decode(pem)
  rescue
    _ -> []
  end

  defimpl Inspect do
    def inspect(%SefazNfe.Certificate{}, _opts), do: "#SefazNfe.Certificate<redacted>"
  end
end
