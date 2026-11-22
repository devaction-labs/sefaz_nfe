defmodule SefazNfe.AccessKey do
  @moduledoc """
  The 44 character access key (`chNFe`) of an NF-e or NFC-e.

  Layout, fixed by the MOC: `cUF`(2) `AAMM`(4) emitter CNPJ(14) `mod`(2)
  `serie`(3) `nNF`(9) `tpEmis`(1) `cNF`(8) `cDV`(1).

  The CT-e (model 57), CT-e OS (67) and MDF-e (58) keys have the same 44
  characters and the same check digit (`CTe` / `MDFe` `Id` prefix aside):
  `nNF` is then `nCT` or `nMDF` and `cNF` is `cCT` or `cMDF`, so the fields
  keep the names `:n_nf` and `:c_nf`. NFePHP's `MakeCTe`, `MakeCTeOS` and
  `Make` (MDF-e) take the code from the caller and rebuild the key with the
  same `Keys::build`, so the random code follows the same `cNF` rules.

  The rules mirror NFePHP `sped-common` `NFePHP\\Common\\Keys`:

    * **Emitter**: a CNPJ is 14 characters, alphanumeric in the first 12
      (NT 2025.001) and numeric in the two check digits. A CPF (11 digits) is
      left-padded with zeros to 14, exactly as `Keys::build` does.
    * **cDV** (`Keys::verifyingDigit`): the sum of `(ASCII code - 48) * weight`,
      weights 2 to 9 cycling from the right. So `0`..`9` weigh as themselves and
      `A` is 17. The digit is `0` when the remainder modulo 11 is 0 or 1, else
      `11 - remainder`.
    * **cNF** (`Keys::random` and `Keys::cNFIsValid`, NT 2019.001, `cStat` 897):
      8 digits, never equal to `nNF` (compared as integers) and never one of
      `00000000` to `99999999` (all digits equal) nor the ascending runs
      `12345678`, `23456789`, `34567890`, `45678901`, `56789012`, `67890123`,
      `78901234`, `89012345`, `90123456`, `01234567`.
    * **valid?** (`Keys::isValid`): 44 characters matching
      `^[0-9]{6}[A-Z0-9]{12}[0-9]{26}$` and a correct `cDV`.
  """

  @forbidden_c_nf ~w(
    00000000 11111111 22222222 33333333 44444444 55555555 66666666 77777777
    88888888 99999999 12345678 23456789 34567890 45678901 56789012 67890123
    78901234 89012345 90123456 01234567
  )

  @key_pattern ~r/^[0-9]{6}[A-Z0-9]{12}[0-9]{26}$/
  @cnpj_pattern ~r/^[A-Z0-9]{12}[0-9]{2}$/
  @cpf_pattern ~r/^[0-9]{11}$/
  @dh_emi_pattern ~r/^\d{2}(\d{2})-(\d{2})-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/
  @months ~w(01 02 03 04 05 06 07 08 09 10 11 12)

  @type field :: :c_uf | :dh_emi | :cnpj | :cpf | :mod | :serie | :n_nf | :tp_emis | :c_nf
  @type fields :: %{optional(field()) => term()}

  @doc """
  Builds the key from `fields`, each an integer or a string:

    * `:c_uf`, `:mod`, `:serie`, `:n_nf`, `:tp_emis` - numbers, zero-padded;
    * `:dh_emi` - `"YYYY-MM-DDThh:mm:ss+hh:mm"`; only year and month are used;
    * `:cnpj` or `:cpf` - the emitter;
    * `:c_nf` - 8 digits; random (see `random_c_nf/2`) when absent.

  The check digit is always computed. `{:error, {field, reason}}` names the
  first field that is missing or out of range.
  """
  @spec build(fields()) :: {:ok, String.t()} | {:error, {atom(), term()}}
  def build(fields) when is_map(fields) do
    with {:ok, c_uf} <- number(fields, :c_uf, 2, 11..99),
         {:ok, aamm} <- aamm(Map.get(fields, :dh_emi)),
         {:ok, emitter} <- emitter(fields),
         {:ok, mod} <- number(fields, :mod, 2, 0..99),
         {:ok, serie} <- number(fields, :serie, 3, 0..999),
         {:ok, n_nf} <- number(fields, :n_nf, 9, 1..999_999_999),
         {:ok, tp_emis} <- number(fields, :tp_emis, 1, 0..9),
         {:ok, c_nf} <- c_nf(fields, n_nf) do
      body = c_uf <> aamm <> emitter <> mod <> serie <> n_nf <> tp_emis <> c_nf
      {:ok, body <> Integer.to_string(dv(body))}
    end
  end

  @doc """
  The check digit of the first 43 characters of a key.
  """
  @spec dv(String.t()) :: 0..9
  def dv(<<_::binary-size(43)>> = key43) do
    sum =
      key43
      |> :binary.bin_to_list()
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {code, index}, acc -> acc + (code - 48) * (rem(index, 8) + 2) end)

    case rem(sum, 11) do
      remainder when remainder < 2 -> 0
      remainder -> 11 - remainder
    end
  end

  @doc """
  A random `cNF` that SEFAZ accepts: 8 digits, not equal to `n_nf` and not one
  of the trivial sequences (see the module doc).

  Option `:random_bytes` is a function from a byte count to that many bytes
  (default `:crypto.strong_rand_bytes/1`); tests use it to drive the rejection.
  """
  @spec random_c_nf(pos_integer() | String.t(), keyword()) :: String.t()
  def random_c_nf(n_nf, opts \\ []) do
    random = Keyword.get(opts, :random_bytes, &:crypto.strong_rand_bytes/1)
    <<n::unsigned-64>> = random.(8)

    candidate = n |> rem(100_000_000) |> Integer.to_string() |> String.pad_leading(8, "0")

    if candidate not in @forbidden_c_nf and not equals_n_nf?(candidate, n_nf),
      do: candidate,
      else: random_c_nf(n_nf, opts)
  end

  @doc """
  Whether `c_nf` equals `n_nf` as integers (the `cStat` 897 case).
  """
  @spec equals_n_nf?(String.t(), pos_integer() | String.t()) :: boolean()
  def equals_n_nf?(c_nf, n_nf) do
    with {c, ""} <- Integer.parse(c_nf),
         {n, ""} <- Integer.parse(to_string(n_nf)) do
      c == n
    else
      _ -> false
    end
  end

  @doc """
  Whether `key` is a well-formed 44 character key with a correct check digit.
  """
  @spec valid?(term()) :: boolean()
  def valid?(<<key43::binary-size(43), last>> = key) do
    Regex.match?(@key_pattern, key) and last - 48 == dv(key43)
  end

  def valid?(_key), do: false

  # Fields -------------------------------------------------------------------

  defp number(fields, name, width, range) do
    given = Map.get(fields, name)

    case integer(given) do
      {:ok, n} ->
        if n in range,
          do: {:ok, n |> Integer.to_string() |> String.pad_leading(width, "0")},
          else: {:error, {name, {:out_of_range, n}}}

      :error ->
        {:error, {name, if(given == nil, do: :required, else: :invalid)}}
    end
  end

  defp integer(n) when is_integer(n), do: {:ok, n}

  defp integer(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp integer(_), do: :error

  defp aamm(nil), do: {:error, {:dh_emi, :required}}

  defp aamm(dh_emi) when is_binary(dh_emi) do
    case Regex.run(@dh_emi_pattern, dh_emi) do
      [_, year, month] when month in @months -> {:ok, year <> month}
      _ -> {:error, {:dh_emi, :invalid}}
    end
  end

  defp aamm(_), do: {:error, {:dh_emi, :invalid}}

  defp emitter(%{cnpj: cnpj}) when is_binary(cnpj) do
    if Regex.match?(@cnpj_pattern, cnpj), do: {:ok, cnpj}, else: {:error, {:cnpj, :invalid}}
  end

  defp emitter(%{cpf: cpf}) when is_binary(cpf) do
    if Regex.match?(@cpf_pattern, cpf),
      do: {:ok, String.pad_leading(cpf, 14, "0")},
      else: {:error, {:cpf, :invalid}}
  end

  defp emitter(_fields), do: {:error, {:emitter, :required}}

  defp c_nf(%{c_nf: c_nf}, n_nf) when c_nf != nil do
    case c_nf do
      c_nf when is_binary(c_nf) ->
        cond do
          not Regex.match?(~r/^[0-9]{8}$/, c_nf) -> {:error, {:c_nf, :invalid}}
          equals_n_nf?(c_nf, n_nf) -> {:error, {:c_nf, :equals_n_nf}}
          true -> {:ok, c_nf}
        end

      _other ->
        {:error, {:c_nf, :invalid}}
    end
  end

  defp c_nf(_fields, n_nf), do: {:ok, random_c_nf(n_nf)}
end
