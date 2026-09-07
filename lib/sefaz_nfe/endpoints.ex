defmodule SefazNfe.Endpoints do
  @moduledoc """
  Resolves `{uf, environment, service}` to a SOAP URL.

  Snapshot in `priv/endpoints/nfe_4.00.json` (nfephp mirror of the RFB table).
  Source of truth remains https://www.nfe.fazenda.gov.br/portal/webServices.aspx
  """

  @type environment :: :homologation | :production
  @type service ::
          :nfe_autorizacao
          | :nfe_ret_autorizacao
          | :nfe_consulta_protocolo
          | :nfe_status_servico
          | :nfe_recepcao_evento
          | :nfe_inutilizacao
          | :nfe_distribuicao_dfe

  @json_path Path.expand("../../priv/endpoints/nfe_4.00.json", __DIR__)
  @external_resource @json_path
  @snapshot JSON.decode!(File.read!(@json_path))

  @services ~w(nfe_autorizacao nfe_ret_autorizacao nfe_consulta_protocolo nfe_status_servico nfe_recepcao_evento nfe_inutilizacao nfe_distribuicao_dfe)a

  @spec snapshot_date() :: String.t()
  def snapshot_date, do: @snapshot["snapshot_date"]

  @doc """
  IBGE code for `uf`, which the 4.00 envelopes carry as `cUF`.

  The Ambiente Nacional is 91.
  """
  @spec uf_code(String.t() | atom()) :: {:ok, pos_integer()} | {:error, {:unknown_uf, String.t()}}
  def uf_code(uf) do
    uf = normalize_uf(uf)

    case @snapshot["uf_code"][uf] do
      code when is_integer(code) -> {:ok, code}
      nil -> {:error, {:unknown_uf, uf}}
    end
  end

  @doc """
  Resolves the SOAP URL for `{uf, environment, service}`.

  The three failures are distinct on purpose: `{:unknown_endpoint, uf, service}`
  is a UF this snapshot cannot resolve, while `{:invalid_environment, _}` and
  `{:unknown_service, _}` mean the caller passed something that is not an
  environment or not a 4.00 service at all.
  """
  @spec url(String.t() | atom(), environment(), service()) ::
          {:ok, String.t()}
          | {:error, {:unknown_endpoint, String.t(), service()}}
          | {:error, {:invalid_environment, term()}}
          | {:error, {:unknown_service, term()}}
  def url(uf, environment, service)
      when environment in [:homologation, :production] and service in @services do
    uf = normalize_uf(uf)
    authorizer = authorizer_for(uf, service)
    env = environment_key(environment)

    case get_in(@snapshot, ["authorizers", authorizer, env, Atom.to_string(service)]) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, {:unknown_endpoint, uf, service}}
    end
  end

  def url(_uf, environment, _service) when environment not in [:homologation, :production] do
    {:error, {:invalid_environment, environment}}
  end

  def url(_uf, _environment, service) do
    {:error, {:unknown_service, service}}
  end

  defp authorizer_for(_uf, :nfe_distribuicao_dfe), do: "AN"

  defp authorizer_for(uf, _service) do
    Map.get(@snapshot["uf_authorizer"], uf, uf)
  end

  defp environment_key(:homologation), do: "homologation"
  defp environment_key(:production), do: "production"

  defp normalize_uf(uf) when is_atom(uf), do: uf |> Atom.to_string() |> normalize_uf()
  defp normalize_uf(uf) when is_binary(uf), do: String.upcase(uf)
end
