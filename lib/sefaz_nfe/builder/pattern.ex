defmodule SefazNfe.Builder.Pattern do
  @moduledoc """
  Translates the XSD regular expressions of the layout into PCRE sources the
  Erlang `re` module accepts (AD-025).

  An `xs:pattern` is implicitly anchored and has its own dialect. The NF-e
  package uses a small, PCRE-compatible subset of it, so this is a character
  walk, not a parser. Every pattern is wrapped as `\\A(?:...)\\z` (never `^`/`$`,
  because `$` also matches before a trailing newline) and compiled with
  `:unicode`, so `[!-ÿ]` ranges are by code point.

  ## Translated

    * `\\d` is `[0-9]`, `\\D` is `[^0-9]`, `\\s` is `[ \\t\\n\\r]`, `\\S` is
      `[^ \\t\\n\\r]` (the XSD sets are Unicode wide for `\\d`; the NF-e patterns
      only ever mean ASCII digits).
    * Inside a class `\\d` and `\\s` expand to their members.
    * `.` is `[^\\n\\r]`, as in XSD.
    * `^` and `$` outside a class are literals in XSD, so they are escaped.
    * `(` becomes `(?:`: XSD groups never capture.
    * `{n}`, `{n,}`, `{n,m}`, `?`, `*`, `+`, `|`, classes and ranges, `\\p{..}`
      and the single-character escapes pass through.

  ## Not supported (raised at compile time)

  Character class subtraction (`[a-z-[aeiou]]`), the XSD name classes `\\i`,
  `\\I`, `\\c`, `\\C`, and `\\D`/`\\S` inside a class. None occurs in PL_010, so
  a Nota Tecnica that introduces one fails the build instead of validating
  wrongly. `\\w` and `\\p{..}` are passed to PCRE as they are, which is close to
  but not identical with the XSD categories; the NF-e does not use them.
  """

  @doc "The PCRE source for an XSD pattern, anchored. Raises on an unsupported construct."
  @spec translate(String.t()) :: String.t()
  def translate(xsd), do: "\\A(?:" <> walk(xsd, []) <> ")\\z"

  @doc "The compiled, anchored regex for an XSD pattern."
  @spec compile!(String.t()) :: Regex.t()
  def compile!(xsd), do: xsd |> translate() |> Regex.compile!([:unicode])

  defp walk(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp walk(<<"\\", c, _rest::binary>>, _acc) when c in [?i, ?I, ?c, ?C],
    do: unsupported!("\\#{<<c>>}")

  defp walk(<<"\\d", rest::binary>>, acc), do: walk(rest, ["[0-9]" | acc])
  defp walk(<<"\\D", rest::binary>>, acc), do: walk(rest, ["[^0-9]" | acc])
  defp walk(<<"\\s", rest::binary>>, acc), do: walk(rest, ["[ \\t\\n\\r]" | acc])
  defp walk(<<"\\S", rest::binary>>, acc), do: walk(rest, ["[^ \\t\\n\\r]" | acc])

  defp walk(<<"\\", c::utf8, rest::binary>>, acc), do: walk(rest, [<<"\\", c::utf8>> | acc])
  defp walk(<<"(", rest::binary>>, acc), do: walk(rest, ["(?:" | acc])
  defp walk(<<".", rest::binary>>, acc), do: walk(rest, ["[^\\n\\r]" | acc])
  defp walk(<<"^", rest::binary>>, acc), do: walk(rest, ["\\^" | acc])
  defp walk(<<"$", rest::binary>>, acc), do: walk(rest, ["\\$" | acc])

  defp walk(<<"[", rest::binary>>, acc) do
    {class, rest} = class(rest, ["["])
    walk(rest, [class | acc])
  end

  defp walk(<<c::utf8, rest::binary>>, acc), do: walk(rest, [<<c::utf8>> | acc])

  # A character class, copied member by member until its closing bracket.
  defp class(<<"]", rest::binary>>, acc),
    do: {acc |> then(&["]" | &1]) |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp class(<<"-[", _rest::binary>>, _acc),
    do: raise(ArgumentError, "XSD character class subtraction is not supported")

  defp class(<<"\\d", rest::binary>>, acc), do: class(rest, ["0-9" | acc])
  defp class(<<"\\s", rest::binary>>, acc), do: class(rest, [" \\t\\n\\r" | acc])

  defp class(<<"\\", c, _rest::binary>>, _acc) when c in [?D, ?S, ?i, ?I, ?c, ?C],
    do: unsupported!("\\#{<<c>>} in a class")

  defp class(<<"\\", c::utf8, rest::binary>>, acc), do: class(rest, [<<"\\", c::utf8>> | acc])
  defp class(<<"[", rest::binary>>, acc), do: class(rest, ["\\[" | acc])
  defp class(<<c::utf8, rest::binary>>, acc), do: class(rest, [<<c::utf8>> | acc])

  defp class(<<>>, _acc), do: raise(ArgumentError, "unterminated character class in XSD pattern")

  defp unsupported!(what),
    do: raise(ArgumentError, "XSD pattern construct not supported: #{what}")
end
