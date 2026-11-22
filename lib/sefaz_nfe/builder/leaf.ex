defmodule SefazNfe.Builder.Leaf do
  @moduledoc false
  # Turns one caller value into the text of a leaf and validates it against the
  # facets of its layout type (AD-025). Never rounds, never fills a value.
  #
  # Accepted values: binaries (kept as they are), integers (stringified; for a
  # `TDec*` type they get the type's places), `Decimal` for a `TDec*` type, with
  # the places of the type and never a dropped digit. Floats are refused.

  alias SefazNfe.Builder.Index
  alias SefazNfe.Builder.Pattern

  # Every XSD pattern in the layout, translated while compiling (so one that
  # cannot be, or does not compile, fails the build). A compiled regex is not a
  # literal on OTP 28+: kept in a module attribute it would be rebuilt at every
  # use. So the sources are compiled once, when the module loads, and kept in
  # `:persistent_term`, where a lookup is a pointer read.
  @sources Map.new(Index.patterns(), &{&1, Pattern.translate(&1)})
  @extra %{
    invalid_xml: ~S"[\x00-\x08\x0B\x0C\x0E-\x1F\x{FFFE}\x{FFFF}]",
    year_month: ~S"\A[0-9]{4}-(0[1-9]|1[0-2])\z"
  }
  for source <- Map.values(@sources) ++ Map.values(@extra), do: Regex.compile!(source, [:unicode])

  @on_load :load_regexes
  @places Index.decimal_places()
  @xml_escapes ["&", "<", ">", "\"", "'", "\r"]

  @type reason ::
          :invalid_type
          | :float_not_allowed
          | :invalid_utf8
          | :invalid_xml_char
          | :invalid_base64
          | :out_of_range
          | {:precision, pos_integer()}
          | {:enum, [String.t()]}
          | {:length, non_neg_integer()}
          | {:min_length, non_neg_integer()}
          | {:max_length, non_neg_integer()}
          | {:pattern, String.t()}
          | {:min_inclusive, String.t()}
          | {:max_inclusive, String.t()}

  @doc false
  def load_regexes do
    for {key, source} <- Map.merge(@sources, @extra) do
      :persistent_term.put({__MODULE__, key}, Regex.compile!(source, [:unicode]))
    end

    :ok
  end

  defp regex(key), do: :persistent_term.get({__MODULE__, key})

  @doc "The validated text of `value` for the leaf type `leaf`."
  @spec text(map(), term()) :: {:ok, String.t()} | {:error, reason()}
  def text(leaf, value) do
    with {:ok, text} <- coerce(leaf, value),
         :ok <- check(leaf, text) do
      {:ok, text}
    end
  end

  @doc "XML-escapes element or attribute text. Nothing else is altered."
  @spec escape(String.t()) :: iodata()
  def escape(text) do
    case :binary.match(text, @xml_escapes) do
      :nomatch -> text
      _found -> String.replace(text, @xml_escapes, &entity/1)
    end
  end

  defp entity("&"), do: "&amp;"
  defp entity("<"), do: "&lt;"
  defp entity(">"), do: "&gt;"
  defp entity("\""), do: "&quot;"
  defp entity("'"), do: "&apos;"
  defp entity("\r"), do: "&#13;"

  # Coercion ---------------------------------------------------------------

  defp coerce(_leaf, value) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, :invalid_utf8}
      Regex.match?(regex(:invalid_xml), value) -> {:error, :invalid_xml_char}
      true -> {:ok, value}
    end
  end

  defp coerce(_leaf, value) when is_float(value), do: {:error, :float_not_allowed}

  defp coerce(leaf, value) when is_integer(value) do
    case Map.get(@places, leaf.name) do
      nil -> {:ok, Integer.to_string(value)}
      {min, _max} -> {:ok, Integer.to_string(value) <> "." <> String.duplicate("0", min)}
    end
  end

  # Bounds, checked on the struct fields alone, before any Decimal call: a
  # `1e1000000000` would otherwise make `to_string(:normal)` allocate gigabytes
  # (decimal 2.x advisory EEF-CVE-2026-32686). `:inf` and `:NaN` are not
  # numbers a field can hold.
  @max_decimal_digits 40
  @max_decimal_exp 40

  defp coerce(leaf, %{__struct__: Decimal, coef: coef, exp: exp} = decimal)
       when is_integer(coef) and is_integer(exp) do
    case Map.get(@places, leaf.name) do
      nil -> {:error, :invalid_type}
      _places when abs(exp) > @max_decimal_exp -> {:error, :out_of_range}
      places -> bounded_decimal_text(decimal, coef, places)
    end
  end

  defp coerce(leaf, %{__struct__: Decimal, coef: coef}) when coef in [:inf, :NaN] do
    case Map.get(@places, leaf.name) do
      nil -> {:error, :invalid_type}
      _places -> {:error, :out_of_range}
    end
  end

  defp coerce(_leaf, _value), do: {:error, :invalid_type}

  defp bounded_decimal_text(decimal, coef, places) do
    if digits(coef, 0) > @max_decimal_digits,
      do: {:error, :out_of_range},
      else: decimal_text(decimal, places)
  end

  defp digits(coef, count) when coef < 10, do: count + 1
  defp digits(coef, count), do: digits(div(coef, 10), count + 1)

  # The least places the type allows, more only when the value needs them.
  # `Decimal.normalize/1` drops trailing zeros, so the scale left is exactly
  # what the value needs; a value that needs more than the type allows is an
  # error, never rounded.
  defp decimal_text(decimal, {min, max}) do
    plain = decimal |> Decimal.normalize() |> Decimal.to_string(:normal)

    {whole, fraction} =
      case String.split(plain, ".") do
        [whole] -> {whole, ""}
        [whole, fraction] -> {whole, fraction}
      end

    case byte_size(fraction) do
      needed when needed > max -> {:error, {:precision, max}}
      needed -> {:ok, whole <> "." <> String.pad_trailing(fraction, max(min, needed), "0")}
    end
  end

  # Validation -------------------------------------------------------------

  defp check(leaf, text) do
    value = collapse(leaf.white_space, text)

    with {:ok, size} <- size(leaf.base, value),
         :ok <- check_enum(leaf.enum, value),
         :ok <- check_length(leaf, size),
         :ok <- check_patterns([leaf.pattern | leaf.inherited_patterns], value) do
      check_range(leaf, value)
    end
  end

  # whiteSpace only shapes what is validated; the caller's text is emitted as is.
  defp collapse(:replace, text), do: String.replace(text, ["\t", "\n", "\r"], " ")

  defp collapse(:collapse, text),
    do:
      text
      |> String.replace(["\t", "\n", "\r"], " ")
      |> String.split(" ", trim: true)
      |> Enum.join(" ")

  defp collapse(_preserve, text), do: text

  # Lengths are in characters; for base64Binary they are in decoded octets.
  defp size(:base64_binary, value) do
    case Base.decode64(value, ignore: :whitespace) do
      {:ok, bytes} -> {:ok, byte_size(bytes)}
      :error -> {:error, :invalid_base64}
    end
  end

  defp size(_base, value), do: {:ok, characters(value, 0)}

  defp characters(<<>>, count), do: count
  defp characters(<<_::utf8, rest::binary>>, count), do: characters(rest, count + 1)

  defp check_enum(nil, _value), do: :ok
  defp check_enum([], _value), do: :ok

  defp check_enum(allowed, value),
    do: if(value in allowed, do: :ok, else: {:error, {:enum, allowed}})

  defp check_length(leaf, size) do
    cond do
      leaf.length && size != leaf.length -> {:error, {:length, leaf.length}}
      leaf.min_length && size < leaf.min_length -> {:error, {:min_length, leaf.min_length}}
      leaf.max_length && size > leaf.max_length -> {:error, {:max_length, leaf.max_length}}
      true -> :ok
    end
  end

  defp check_patterns([], _value), do: :ok
  defp check_patterns([nil | rest], value), do: check_patterns(rest, value)

  defp check_patterns([pattern | rest], value) do
    if Regex.match?(regex(pattern), value),
      do: check_patterns(rest, value),
      else: {:error, {:pattern, pattern}}
  end

  # gYearMonth is the only base here with an ordered range (cRegTrib/compet).
  defp check_range(%{base: :g_year_month} = leaf, value) do
    cond do
      not Regex.match?(regex(:year_month), value) ->
        {:error, {:pattern, "gYearMonth"}}

      leaf.min_inclusive && value < leaf.min_inclusive ->
        {:error, {:min_inclusive, leaf.min_inclusive}}

      leaf.max_inclusive && value > leaf.max_inclusive ->
        {:error, {:max_inclusive, leaf.max_inclusive}}

      true ->
        :ok
    end
  end

  defp check_range(_leaf, _value), do: :ok
end
