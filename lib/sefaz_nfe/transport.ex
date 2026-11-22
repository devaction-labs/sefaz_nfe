defmodule SefazNfe.Transport do
  @moduledoc false

  # The plumbing every document facade (`SefazNfe`, `SefazNfe.CTe`,
  # `SefazNfe.MDFe`) shares: required options, the environment check and the one
  # path to `SefazNfe.SOAP.isolated_call/4`. Internal; hosts call the facades.

  alias SefazNfe.SOAP

  @spec require_keys(map(), [atom()]) :: :ok | {:error, {:missing_keys, [atom()]}}
  def require_keys(opts, keys) do
    missing = Enum.reject(keys, &Map.has_key?(opts, &1))

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_keys, keys}}
    end
  end

  @spec validate_environment(term()) :: :ok | {:error, :invalid_environment}
  def validate_environment(environment) when environment in [:homologation, :production], do: :ok
  def validate_environment(_), do: {:error, :invalid_environment}

  # `extra` carries per-call transport options; `operation:` is the one that
  # makes the SOAP action differ per authorizer (NFeConsultaCadastro only).
  @spec call(String.t(), iodata(), map(), atom(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def call(url, envelope, opts, service, extra \\ []) do
    telemetry = Map.get(opts, :telemetry_context, %{})

    SOAP.isolated_call(
      url,
      envelope,
      opts.cert,
      [
        uf: opts.uf |> to_string() |> String.upcase(),
        service: service,
        environment: telemetry[:environment],
        model: telemetry[:model],
        contingency: telemetry[:contingency],
        timeout: Map.get(opts, :timeout, to_timeout(second: 30)),
        connect_timeout: Map.get(opts, :connect_timeout, to_timeout(second: 10)),
        tls_options: Map.get(opts, :tls_options, [])
      ] ++ extra
    )
  end
end
