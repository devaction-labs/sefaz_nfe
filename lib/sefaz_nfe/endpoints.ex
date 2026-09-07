defmodule SefazNfe.Endpoints do
  @moduledoc """
  Resolves `{uf, ambiente, service}` to a SOAP URL.

  Snapshot in `priv/endpoints/nfe_4.00.json` (nfephp mirror of the RFB table).
  Source of truth remains https://www.nfe.fazenda.gov.br/portal/webServices.aspx
  """

  @type ambiente :: :homologacao | :producao
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

  @spec url(String.t() | atom(), ambiente(), service()) ::
          {:ok, String.t()} | {:error, {:unknown_endpoint, String.t(), service()}}
  def url(uf, ambiente, service)
      when ambiente in [:homologacao, :producao] and service in @services do
    uf = normalize_uf(uf)
    autorizador = autorizador_for(uf, service)
    env = ambiente_key(ambiente)

    case get_in(@snapshot, ["autorizadores", autorizador, env, Atom.to_string(service)]) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, {:unknown_endpoint, uf, service}}
    end
  end

  def url(uf, _ambiente, service) when is_atom(service) do
    {:error, {:unknown_endpoint, normalize_uf(uf), service}}
  end

  defp autorizador_for(_uf, :nfe_distribuicao_dfe), do: "AN"

  defp autorizador_for(uf, _service) do
    Map.get(@snapshot["uf_autorizador"], uf, uf)
  end

  defp ambiente_key(:homologacao), do: "homologacao"
  defp ambiente_key(:producao), do: "producao"

  defp normalize_uf(uf) when is_atom(uf), do: uf |> Atom.to_string() |> normalize_uf()
  defp normalize_uf(uf) when is_binary(uf), do: String.upcase(uf)
end
