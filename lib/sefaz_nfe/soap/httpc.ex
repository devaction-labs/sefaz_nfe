defmodule SefazNfe.SOAP.HTTPC do
  @moduledoc """
  Default `SefazNfe.SOAP` client: an mTLS POST over `:httpc`.

  `:httpc` ships with OTP, so a host embedding this library gains no transitive
  dependency for the one HTTP call the library makes. The Erlang API stays
  inside this module.

  ## Isolation

  Requests run on a named `:httpc` profile rather than the default one, so the
  library never inherits or mutates the host's global HTTP settings — proxies,
  cookies, connection limits. The profile is started by
  `SefazNfe.Application`.

  ## TLS

  SEFAZ requires the A1 as a client certificate and the peer is verified
  against the system CA bundle: `verify_none` against a fiscal authority would
  defeat the point of mTLS. `:customize_hostname_check` is set because several
  SEFAZ hosts serve wildcard certificates.

  TLS 1.2 is pinned as the floor. Some UF endpoints still fail the 1.3
  handshake, and a silent downgrade is worse than a named error.
  """

  @behaviour SefazNfe.SOAP

  @profile :sefaz_nfe
  @content_type ~c"application/soap+xml; charset=utf-8"

  @impl SefazNfe.SOAP
  def call(endpoint, body, cert, opts) do
    request = {String.to_charlist(endpoint), headers(), @content_type, IO.iodata_to_binary(body)}

    http_options = [
      ssl: ssl_options(cert, opts),
      timeout: Keyword.get(opts, :timeout, to_timeout(second: 30)),
      connect_timeout: Keyword.get(opts, :connect_timeout, to_timeout(second: 10))
    ]

    :httpc.request(:post, request, http_options, [body_format: :binary], @profile)
    |> handle()
  end

  defp handle({:ok, {{_version, status, _reason}, _headers, body}}) when status in 200..299 do
    {:ok, body}
  end

  defp handle({:ok, {{_version, status, _reason}, _headers, body}}) do
    {:error, {:http, status, truncate(body)}}
  end

  defp handle({:error, {:failed_connect, details}}), do: {:error, connect_error(details)}
  defp handle({:error, :timeout}), do: {:error, :timeout}
  defp handle({:error, reason}), do: {:error, {:http, reason}}

  @doc """
  Names why a connection failed.

  A TLS alert is reported as `{:tls, alert}` rather than a generic
  `:unreachable`, because the two need opposite responses: `:unknown_ca` means
  the trust store is missing a root and no amount of retrying fixes it, while
  an unreachable host is worth backing off on. Several SEFAZ UFs — SP and MT
  among them — serve certificates chained to an ICP-Brasil root that is not in
  any OS bundle; see `SefazNfe.Certificate` for supplying it.
  """
  @spec connect_error(term()) :: :unreachable | {:tls, atom()} | {:dns, atom()}
  def connect_error(details) when is_list(details) do
    details
    |> Enum.find_value(:unreachable, fn
      {:inet, _transports, {:tls_alert, {alert, _description}}} -> {:tls, alert}
      {:inet, _transports, :nxdomain} -> {:dns, :nxdomain}
      {:inet, _transports, :timeout} -> :timeout
      _other -> nil
    end)
  end

  def connect_error(_details), do: :unreachable

  @doc """
  Client options for an mTLS connection, with `:tls_options` from `opts`
  merged over the defaults.

  The escape hatch exists because SEFAZ TLS stacks vary by UF, and a host
  should not have to fork the library to add a cipher or a CA.
  """
  @spec ssl_options(SefazNfe.Certificate.t(), keyword()) :: keyword()
  def ssl_options(cert, opts \\ []) do
    defaults =
      SefazNfe.Certificate.ssl_options(cert) ++
        [
          verify: :verify_peer,
          depth: 5,
          versions: [:"tlsv1.2", :"tlsv1.3"],
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]

    Keyword.merge(defaults, Keyword.get(opts, :tls_options, []))
  end

  defp headers do
    [{~c"accept", ~c"application/soap+xml"}, {~c"user-agent", ~c"sefaz_nfe"}]
  end

  # A SOAP fault or an HTML error page can be large; the caller needs enough to
  # diagnose, not the whole document in a log line or a telemetry label.
  defp truncate(body) when is_binary(body), do: binary_part(body, 0, min(byte_size(body), 500))
  defp truncate(body), do: body
end
