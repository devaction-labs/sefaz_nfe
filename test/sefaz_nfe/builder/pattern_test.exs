defmodule SefazNfe.Builder.PatternTest do
  use ExUnit.Case, async: true

  alias SefazNfe.Builder.Index
  alias SefazNfe.Builder.Pattern

  defp accepts?(xsd, text), do: Regex.match?(Pattern.compile!(xsd), text)

  test "an XSD pattern is anchored at both ends" do
    assert accepts?("[0-9]{2}", "12")
    refute accepts?("[0-9]{2}", "123")
    refute accepts?("[0-9]{2}", "a12")
    refute accepts?("[0-9]{2}", "12\n")
  end

  test "alternatives are anchored as a whole" do
    assert accepts?("0|0\\.[0-9]{2}", "0")
    assert accepts?("0|0\\.[0-9]{2}", "0.10")
    refute accepts?("0|0\\.[0-9]{2}", "0.1")
    refute accepts?("0|0\\.[0-9]{2}", "00")
  end

  test "\\d and \\s" do
    assert accepts?("\\d{3}", "123")
    refute accepts?("\\d{3}", "12a")
    assert accepts?("a\\sb", "a b")
    assert accepts?("a\\sb", "a\tb")
    refute accepts?("a\\sb", "a b")
    assert accepts?("[\\d,]+", "1,2")
    assert accepts?("[\\s]", "\n")
  end

  test "a dot is any character but a line break" do
    assert accepts?("[0-9]{2}.[0-9]{2}", "01.02")
    assert accepts?("[0-9]{2}.[0-9]{2}", "01x02")
    refute accepts?("a.b", "a\nb")
  end

  test "^ and $ are literals outside a class" do
    assert accepts?("a\\^b", "a^b")
    assert accepts?("a^b", "a^b")
    assert accepts?("a$", "a$")
  end

  test "ranges are by code point" do
    assert accepts?("[!-ÿ]{1}[ -ÿ]{0,}[!-ÿ]{1}|[!-ÿ]{1}", "Ação")
    refute accepts?("[!-ÿ]{1}[ -ÿ]{0,}[!-ÿ]{1}|[!-ÿ]{1}", " A")
    refute accepts?("[!-ÿ]{1}[ -ÿ]{0,}[!-ÿ]{1}|[!-ÿ]{1}", "Ā")
  end

  test "a range that starts at a symbol, and a class with a comma" do
    assert accepts?("[A-Za-z0-9.:+-/)(]{5,20}", "ab.:+,/)(1")
    assert accepts?("[1,2,3,5,6,7]{1}[0-9]{3}", "1000")
  end

  test "groups do not capture and quantifiers pass through" do
    assert accepts?("(ab){2}(c)?", "abab")
    assert accepts?("(ab){2}(c)?", "ababc")
    assert Regex.run(Pattern.compile!("(ab)(c)"), "abc") == ["abc"]
  end

  test "class subtraction and the XSD name classes are refused, not mistranslated" do
    assert_raise ArgumentError, ~r/subtraction/, fn -> Pattern.translate("[a-z-[aeiou]]") end
    assert_raise ArgumentError, ~r/not supported/, fn -> Pattern.translate("\\i\\c*") end
    assert_raise ArgumentError, ~r/not supported/, fn -> Pattern.translate("[\\D]") end
    assert_raise ArgumentError, ~r/unterminated/, fn -> Pattern.translate("[abc") end
  end

  test "every pattern of the layout translates and compiles" do
    for pattern <- Index.patterns() do
      assert %Regex{} = Pattern.compile!(pattern)
    end
  end
end
