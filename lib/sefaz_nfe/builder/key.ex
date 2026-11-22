defmodule SefazNfe.Builder.Key do
  @moduledoc false
  # The access key part of the builder: generates `cNF`, `cDV` and `Id` when
  # they are absent and checks the ones the caller gave. It only reads the
  # inputs the key needs; whatever is missing or malformed is reported by the
  # layout walk, so it is never reported here as well.

  alias SefazNfe.AccessKey

  @doc """
  Returns `{input, errors, key}`. `key` is `nil` when the inputs do not allow
  one, and then `errors` has only what is certain without it.
  """
  @spec prepare(map()) :: {map(), [SefazNfe.Builder.error()], String.t() | nil}
  def prepare(input) do
    ide = get(input, :ide)
    emit = get(input, :emit)

    if plain_map?(ide) and plain_map?(emit) do
      fields = %{
        c_uf: get(ide, :c_uf),
        dh_emi: get(ide, :dh_emi),
        cnpj: get(emit, :cnpj),
        cpf: get(emit, :cpf),
        mod: get(ide, :mod),
        serie: get(ide, :serie),
        n_nf: get(ide, :n_nf),
        tp_emis: get(ide, :tp_emis),
        c_nf: get(ide, :c_nf)
      }

      case AccessKey.build(fields) do
        {:ok, key} -> with_key(input, ide, key)
        {:error, {:c_nf, :equals_n_nf}} -> {input, [{[:ide, :c_nf], :equals_n_nf}], nil}
        {:error, _field} -> {input, [], nil}
      end
    else
      {input, [], nil}
    end
  end

  @doc """
  The paths `prepare/1` would generate, among `id`, `ide.c_nf` and `ide.c_dv`:
  the ones the caller left out.
  """
  @spec absent(map()) :: [[atom()]]
  def absent(input) do
    ide = get(input, :ide)
    ide = if plain_map?(ide), do: ide, else: %{}

    Enum.filter([[:id], [:ide, :c_nf], [:ide, :c_dv]], fn
      [:id] -> get(input, :id) == nil
      [:ide, key] -> get(ide, key) == nil
    end)
  end

  defp with_key(input, ide, key) do
    dv = String.last(key)
    id = "NFe" <> key

    errors =
      Enum.reject(
        [
          given_mismatch(get(ide, :c_dv), dv, [:ide, :c_dv]),
          given_mismatch(get(input, :id), id, [:id])
        ],
        &is_nil/1
      )

    ide = ide |> put_absent(:c_nf, String.slice(key, 35, 8)) |> put_absent(:c_dv, dv)

    {input |> put_absent(:id, id) |> put(:ide, ide), errors, key}
  end

  defp given_mismatch(nil, _expected, _path), do: nil

  defp given_mismatch(given, expected, path) do
    if to_string(given) == expected, do: nil, else: {path, {:mismatch, expected}}
  end

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  # Atom or string key, whichever the caller used.
  defp get(map, key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp put_absent(map, key, value),
    do: if(get(map, key) == nil, do: put(map, key, value), else: map)

  defp put(map, key, value) do
    if Map.has_key?(map, Atom.to_string(key)),
      do: Map.put(map, Atom.to_string(key), value),
      else: Map.put(map, key, value)
  end
end
