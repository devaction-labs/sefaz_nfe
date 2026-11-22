defmodule SefazNfe.Endpoints do
  @moduledoc """
  Resolves `{uf, environment, service}` to a SOAP URL, per document model.

  Snapshots in `priv/endpoints/nfe_4.00.json` (model 55) and
  `priv/endpoints/nfce_4.00.json` (model 65), both nfephp mirrors of the RFB
  tables. Source of truth remains
  https://www.nfe.fazenda.gov.br/portal/webServices.aspx

  The two tables share a schema: `authorizers` per authorizer and environment,
  `uf_authorizer` per UF. They differ in who serves a UF: for model 65 only
  AM, GO, MG, MS, MT, PR, RS and SP run their own, and SVRS serves every other
  UF (there is no SVAN for model 65), so BA resolves to a different host per
  model. The model 65 table also carries `qr_code` and `url_chave`, the two
  per-UF addresses printed on a DANFCE and written into `infNFeSupl`.
  """

  @type environment :: :homologation | :production
  @type model :: 55 | 65
  @type service ::
          :nfe_autorizacao
          | :nfe_ret_autorizacao
          | :nfe_consulta_protocolo
          | :nfe_status_servico
          | :nfe_recepcao_evento
          | :nfe_inutilizacao
          | :nfe_distribuicao_dfe
          | :nfe_consulta_cadastro

  @json_path Path.expand("../../priv/endpoints/nfe_4.00.json", __DIR__)
  @nfce_json_path Path.expand("../../priv/endpoints/nfce_4.00.json", __DIR__)
  @external_resource @json_path
  @external_resource @nfce_json_path
  @snapshot JSON.decode!(File.read!(@json_path))
  @nfce_snapshot JSON.decode!(File.read!(@nfce_json_path))
  @snapshots %{55 => @snapshot, 65 => @nfce_snapshot}

  @services ~w(nfe_autorizacao nfe_ret_autorizacao nfe_consulta_protocolo nfe_status_servico nfe_recepcao_evento nfe_inutilizacao nfe_distribuicao_dfe nfe_consulta_cadastro)a

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
  Resolves the SOAP URL for `{uf, environment, service}` under `model`
  (55 by default, or 65 for NFC-e).

  The failures are distinct on purpose: `{:unknown_endpoint, uf, service}`
  is a UF this snapshot cannot resolve, while `{:invalid_environment, _}` and
  `{:unknown_service, _}` mean the caller passed something that is not an
  environment or not a 4.00 service at all, and `{:unsupported_model, _}` a
  model other than 55 or 65.
  """
  @spec url(String.t() | atom(), environment(), service(), model()) ::
          {:ok, String.t()}
          | {:error, {:unknown_endpoint, String.t(), service()}}
          | {:error, {:invalid_environment, term()}}
          | {:error, {:unknown_service, term()}}
          | {:error, {:unsupported_model, term()}}
  def url(uf, environment, service, model \\ 55)

  def url(uf, environment, service, model)
      when environment in [:homologation, :production] and service in @services and
             is_map_key(@snapshots, model) do
    snapshot = Map.fetch!(@snapshots, model)
    uf = normalize_uf(uf)
    authorizer = authorizer_for(snapshot, uf, service)
    env = environment_key(environment)

    case get_in(snapshot, ["authorizers", authorizer, env, Atom.to_string(service)]) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, {:unknown_endpoint, uf, service}}
    end
  end

  def url(_uf, environment, _service, _model)
      when environment not in [:homologation, :production] do
    {:error, {:invalid_environment, environment}}
  end

  def url(_uf, _environment, service, _model) when service not in @services do
    {:error, {:unknown_service, service}}
  end

  def url(_uf, _environment, _service, model), do: {:error, {:unsupported_model, model}}

  @svc %{"SVCAN" => :svc_an, "SVCRS" => :svc_rs}
  @svc_authorizer %{svc_an: "SVCAN", svc_rs: "SVCRS"}

  @doc """
  The SVC (Sefaz Virtual de Contingência) that serves `uf`, model 55 only.

  Which one is data (`uf_contingency` in the snapshot, from the MOC): SVC-RS
  serves AM, BA, GO, MA, MS, MT, PE and PR, SVC-AN every other UF. Nothing here
  decides to use it; contingency is the caller's choice (AD-005).
  """
  @spec contingency_for(String.t() | atom()) ::
          {:ok, :svc_an | :svc_rs} | {:error, {:unknown_uf, String.t()}}
  def contingency_for(uf) do
    uf = normalize_uf(uf)

    case @svc[@snapshot["uf_contingency"][uf]] do
      nil -> {:error, {:unknown_uf, uf}}
      svc -> {:ok, svc}
    end
  end

  @doc """
  The URL of `service` on the SVC `svc` (`:svc_an` or `:svc_rs`), model 55.

  It does not check that `svc` serves any particular UF; see `contingency_for/1`.
  """
  @spec contingency_url(:svc_an | :svc_rs, environment(), service()) ::
          {:ok, String.t()} | {:error, term()}
  def contingency_url(svc, environment, service)
      when is_map_key(@svc_authorizer, svc) and environment in [:homologation, :production] and
             service in @services do
    authorizer = Map.fetch!(@svc_authorizer, svc)
    path = ["authorizers", authorizer, environment_key(environment), Atom.to_string(service)]

    case get_in(@snapshot, path) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, {:unknown_endpoint, authorizer, service}}
    end
  end

  def contingency_url(svc, _environment, _service) when not is_map_key(@svc_authorizer, svc),
    do: {:error, {:invalid_contingency, svc}}

  def contingency_url(_svc, environment, _service)
      when environment not in [:homologation, :production],
      do: {:error, {:invalid_environment, environment}}

  def contingency_url(_svc, _environment, service), do: {:error, {:unknown_service, service}}

  @doc """
  The QR code base URL of `uf`'s own SEFAZ, for model 65.

  Always the emitting UF's, even where SVRS authorizes the document: SVRS has
  no QR code address of its own.
  """
  @spec qr_code_url(String.t() | atom(), environment()) :: {:ok, String.t()} | {:error, term()}
  def qr_code_url(uf, environment), do: nfce_address("qr_code", :qr_code, uf, environment)

  @doc """
  The "consulta pela chave" address of `uf` for model 65, which `urlChave` and
  the DANFCE carry.

  Returned exactly as published: some entries have no scheme and some are
  plain http, and that is what SEFAZ expects to read back.
  """
  @spec url_chave(String.t() | atom(), environment()) :: {:ok, String.t()} | {:error, term()}
  def url_chave(uf, environment), do: nfce_address("url_chave", :url_chave, uf, environment)

  defp nfce_address(table, name, uf, environment)
       when environment in [:homologation, :production] do
    uf = normalize_uf(uf)

    case get_in(@nfce_snapshot, [table, environment_key(environment), uf]) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, {:unknown_endpoint, uf, name}}
    end
  end

  defp nfce_address(_table, _name, _uf, environment),
    do: {:error, {:invalid_environment, environment}}

  @doc """
  The SOAP operation `service` is called with on the authorizer serving `uf`,
  or `nil` for a service whose operation is fixed (see `SefazNfe.SOAP.Envelope`).

  `NFeConsultaCadastro` is the exception: its authorizers disagree on the
  operation name (`consultaCadastro` on BA, GO, MS, MT and SP;
  `consultaCadastro4` elsewhere), so the snapshot carries it as data under
  `"operations"`, keyed by service and then authorizer, with a `"default"`.
  """
  @spec operation(String.t() | atom(), service()) :: String.t() | nil
  def operation(uf, service) when service in @services do
    authorizer = authorizer_for(@snapshot, normalize_uf(uf), service)

    case @snapshot["operations"][Atom.to_string(service)] do
      %{"default" => default} = operations -> Map.get(operations, authorizer, default)
      nil -> nil
    end
  end

  defp authorizer_for(_snapshot, _uf, :nfe_distribuicao_dfe), do: "AN"

  defp authorizer_for(snapshot, uf, _service) do
    Map.get(snapshot["uf_authorizer"], uf, uf)
  end

  defp environment_key(:homologation), do: "homologation"
  defp environment_key(:production), do: "production"

  defp normalize_uf(uf) when is_atom(uf), do: uf |> Atom.to_string() |> normalize_uf()
  defp normalize_uf(uf) when is_binary(uf), do: String.upcase(uf)
end
