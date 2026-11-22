defmodule SefazNfe.GatewayCommon do
  @moduledoc false
  # Test support shared by `SefazNfe.GatewayCtePayload` and `SefazNfe.GatewayMdfePayload`
  # (the NF-e mapping, `SefazNfe.GatewayPayload`, keeps its own copies): the UF tables of
  # NFePHP\Common (`UFList`, `TimeZoneByUF`) and the FORMAT rule every NFePHP `Make` applies,
  # `conditionalNumberFormatting` (`number_format($v, $places, '.', '')`, in
  # sped-cte MakeCTe.php l.5850 and sped-mdfe Make.php): pad to the places of the field.

  @uf_codes %{
    "RO" => 11,
    "AC" => 12,
    "AM" => 13,
    "RR" => 14,
    "PA" => 15,
    "AP" => 16,
    "TO" => 17,
    "MA" => 21,
    "PI" => 22,
    "CE" => 23,
    "RN" => 24,
    "PB" => 25,
    "PE" => 26,
    "AL" => 27,
    "SE" => 28,
    "BA" => 29,
    "MG" => 31,
    "ES" => 32,
    "RJ" => 33,
    "SP" => 35,
    "PR" => 41,
    "SC" => 42,
    "RS" => 43,
    "MS" => 50,
    "MT" => 51,
    "GO" => 52,
    "DF" => 53
  }

  # Offsets of TimeZoneByUF::get (no daylight saving since 2019).
  @uf_offsets %{"AC" => -5, "AM" => -4, "RO" => -4, "RR" => -4, "MT" => -4, "MS" => -4}

  @spec uf_code(String.t()) :: pos_integer()
  def uf_code(uf), do: Map.fetch!(@uf_codes, uf)

  @doc """
  The issue time in the timezone of `uf`, as `Y-m-d\\TH:i:sP`
  (`$issuedAt->setTimezone(TimeZoneByUF::get($uf))->format(...)`).
  """
  @spec issued_at(String.t(), String.t()) :: String.t()
  def issued_at(text, uf) do
    {:ok, utc, _} = text |> String.replace(" ", "T", global: false) |> DateTime.from_iso8601()
    hours = Map.get(@uf_offsets, uf, -3)
    local = DateTime.add(utc, hours * 3600, :second)
    sign = if hours < 0, do: "-", else: "+"

    Calendar.strftime(local, "%Y-%m-%dT%H:%M:%S") <> "#{sign}#{pad2(abs(hours))}:00"
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  FORMAT: pads a decimal string to `places` (NFePHP `number_format`), never rounds: a value
  with more places than the field holds raises.
  """
  @spec dec(nil | integer() | String.t(), non_neg_integer()) :: nil | String.t()
  def dec(nil, _places), do: nil
  def dec(value, places) when is_integer(value), do: dec(Integer.to_string(value), places)

  def dec(value, places) when is_binary(value) do
    [int | frac] = String.split(value, ".", parts: 2)
    frac = List.first(frac, "")
    {kept, dropped} = String.split_at(frac, places)

    if String.trim(dropped, "0") != "" do
      raise ArgumentError,
            "#{inspect(value)} has more than #{places} places; the mapping never rounds"
    end

    case places do
      0 -> int
      _ -> int <> "." <> String.pad_trailing(kept, places, "0")
    end
  end

  @doc "PHP `$value > 0` for a numeric string (nil is not positive)."
  @spec positive?(nil | String.t() | integer()) :: boolean()
  def positive?(nil), do: false
  def positive?(value), do: Decimal.compare(Decimal.new(value), 0) == :gt

  @spec reject_nil(map()) :: map()
  def reject_nil(map) when is_map(map) do
    map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end
end
