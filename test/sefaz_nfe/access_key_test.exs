defmodule SefazNfe.AccessKeyTest do
  use ExUnit.Case, async: true

  alias SefazNfe.AccessKey
  alias SefazNfe.NFeBuilder

  # Keys SEFAZ authorized (NF-e 55 and NFC-e 65, BA).
  @real_keys [
    "29261115223384000189550030000000271616599438",
    "29261115223384000189650010000000011737330891"
  ]

  @fields %{
    c_uf: 35,
    dh_emi: "2026-09-07T10:00:00-03:00",
    cnpj: "00000000000191",
    mod: 55,
    serie: 1,
    n_nf: 1,
    tp_emis: 1,
    c_nf: "12345679"
  }

  @alnum43 "35260112ABC34501DE3555001000000001187654321"

  describe "dv/1 and valid?/1" do
    test "the check digit of authorized keys verifies" do
      for key <- @real_keys do
        <<key43::binary-size(43), last>> = key
        assert AccessKey.dv(key43) == last - 48
        assert AccessKey.valid?(key)
      end
    end

    test "agrees with the independent test implementation on numeric keys" do
      for _ <- 1..200 do
        body = for _ <- 1..43, into: "", do: Integer.to_string(Enum.random(0..9))
        assert Integer.to_string(AccessKey.dv(body)) == NFeBuilder.check_digit(body)
      end
    end

    test "the alphanumeric CNPJ weighs each character as its ASCII code minus 48" do
      # Computed with NFePHP's Keys::verifyingDigit formula (ord - 48, weights
      # 4,3,2,9,...,2 from the left) ported line by line.
      assert AccessKey.dv(@alnum43) == 6
      assert AccessKey.dv("352601AAAAAAAAAAAA0055001000000001187654321") == 4

      assert AccessKey.valid?(@alnum43 <> "6")
      refute AccessKey.valid?(@alnum43 <> "5")
    end

    test "rejects what is not a key" do
      refute AccessKey.valid?("123")
      refute AccessKey.valid?(nil)
      refute AccessKey.valid?(String.replace_suffix(hd(@real_keys), "8", "7"))
      refute AccessKey.valid?("35260112abc34501de3555001000000001187654321" <> "6")
      refute AccessKey.valid?("35A60100000000000191550010000000011876543216")
    end
  end

  describe "build/1" do
    test "composes the 44 characters in MOC order" do
      assert {:ok, key} = AccessKey.build(@fields)

      assert <<"35", "2609", "00000000000191", "55", "001", "000000001", "1", "12345679", _dv>> =
               key

      assert AccessKey.valid?(key)
    end

    test "reproduces a real authorized key" do
      assert {:ok, "29261115223384000189550030000000271616599438"} =
               AccessKey.build(%{
                 c_uf: 29,
                 dh_emi: "2026-11-20T09:00:00-03:00",
                 cnpj: "15223384000189",
                 mod: 55,
                 serie: 3,
                 n_nf: 27,
                 tp_emis: 1,
                 c_nf: "61659943"
               })
    end

    test "accepts strings for the numbers" do
      strings = %{@fields | c_uf: "35", mod: "55", serie: "001", n_nf: "000000001", tp_emis: "1"}
      assert AccessKey.build(strings) == AccessKey.build(@fields)
    end

    test "a CPF emitter is left-padded with zeros to 14" do
      fields = @fields |> Map.delete(:cnpj) |> Map.put(:cpf, "12345678909")

      assert {:ok, key} = AccessKey.build(fields)
      assert binary_part(key, 6, 14) == "00012345678909"
      assert AccessKey.valid?(key)
    end

    test "an alphanumeric CNPJ is kept and its key is valid" do
      assert {:ok, key} = AccessKey.build(%{@fields | cnpj: "12ABC34501DE35"})
      assert binary_part(key, 6, 14) == "12ABC34501DE35"
      assert AccessKey.valid?(key)
    end

    test "generates cNF when absent, different from nNF" do
      assert {:ok, key} = AccessKey.build(Map.delete(@fields, :c_nf))
      c_nf = binary_part(key, 35, 8)
      assert c_nf =~ ~r/^\d{8}$/
      refute AccessKey.equals_n_nf?(c_nf, 1)
    end

    test "reports the field at fault" do
      bad_month = %{@fields | dh_emi: "2026-13-01T00:00:00-03:00"}

      assert {:error, {:c_uf, :required}} = AccessKey.build(Map.delete(@fields, :c_uf))
      assert {:error, {:c_uf, {:out_of_range, 5}}} = AccessKey.build(%{@fields | c_uf: 5})
      assert {:error, {:dh_emi, :invalid}} = AccessKey.build(bad_month)
      assert {:error, {:dh_emi, :required}} = AccessKey.build(Map.delete(@fields, :dh_emi))
      assert {:error, {:emitter, :required}} = AccessKey.build(Map.delete(@fields, :cnpj))
      assert {:error, {:cnpj, :invalid}} = AccessKey.build(%{@fields | cnpj: "123"})
      assert {:error, {:serie, {:out_of_range, 1000}}} = AccessKey.build(%{@fields | serie: 1000})
      assert {:error, {:n_nf, {:out_of_range, 0}}} = AccessKey.build(%{@fields | n_nf: 0})
      assert {:error, {:serie, :invalid}} = AccessKey.build(%{@fields | serie: "x"})
      assert {:error, {:c_nf, :invalid}} = AccessKey.build(%{@fields | c_nf: "123"})
      assert {:error, {:c_nf, :equals_n_nf}} = AccessKey.build(%{@fields | c_nf: "00000001"})
    end
  end

  describe "random_c_nf/2" do
    @forbidden ~w(00000000 11111111 22222222 33333333 44444444 55555555 66666666 77777777
                  88888888 99999999 12345678 23456789 34567890 45678901 56789012 67890123
                  78901234 89012345 90123456 01234567)

    test "is 8 digits, never forbidden and never nNF" do
      for n_nf <- [1, 12_345_678, 99_999_999, "000000042"], _ <- 1..500 do
        c_nf = AccessKey.random_c_nf(n_nf)
        assert c_nf =~ ~r/^\d{8}$/
        refute c_nf in @forbidden
        refute AccessKey.equals_n_nf?(c_nf, n_nf)
      end
    end

    test "rejects forbidden draws and tries again" do
      Process.put(:draws, [12_345_678, 11_111_111, 77, 55_555_555, 4_242_424])

      random = fn 8 ->
        [n | rest] = Process.get(:draws)
        Process.put(:draws, rest)
        <<n::unsigned-64>>
      end

      # 12345678, 11111111 and 55555555 are forbidden; 77 equals nNF.
      assert AccessKey.random_c_nf(77, random_bytes: random) == "04242424"
    end
  end
end
