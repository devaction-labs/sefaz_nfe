defmodule SefazNfe.Telemetry do
  @moduledoc """
  The `:telemetry` events this library emits, per operation and per UF.

  There are three families. `events/0` lists every name, for
  `:telemetry.attach_many/4`.

  ## Operation span: `[:sefaz_nfe, :operation, :start | :stop | :exception]`

  One span around every public operation of `SefazNfe`: `:authorize`,
  `:authorization_result`, `:service_status`, `:consult_protocol`, `:cancel`,
  `:cce`, `:manifest`, `:void_numbers`, `:dist_dfe`, `:consult_taxpayer` and
  `:epec`; `SefazNfe.CTe` and `SefazNfe.MDFe` add `:cte_service_status` (model
  57, or 67) and `:mdfe_service_status` (model 58). It covers the whole call,
  so an answer refused before the network
  (a missing key, a bad CNPJ, `tpAmb` against `:environment`) still emits
  `:start` and `:stop`, with the failure as `:outcome`: callers can count
  validation errors the same way they count SEFAZ ones. Building the metadata
  is a handful of map reads, never an XML parse.

  Measurements are the standard `:telemetry.span/3` ones: `:system_time` on
  `:start`; `:duration` (native time units) and `:monotonic_time` on `:stop`
  and `:exception`.

  Metadata on `:start`:

    * `:operation` - atom, one of the names above;
    * `:uf` - `String.t() | nil`: the UF the call is about, upper case. `"AN"`
      for what the Ambiente Nacional serves (`:dist_dfe`, `:manifest`, `:epec`).
      `nil` when the caller gave none, or gave something that is not a UF;
    * `:environment` - `:production | :homologation | nil`;
    * `:model` - `55 | 65 | 57 | 67 | 58 | nil`: read from `<mod>` for `:authorize`, from the
      access key for `:consult_protocol`, `:cancel` and `:cce`, from `:model`
      (default 55) for the services that take no document. `nil` where it does
      not apply (`:dist_dfe`, `:consult_taxpayer`);
    * `:contingency` - `nil | :svc_an | :svc_rs | :epec`. For `:authorize` it
      follows `tpEmis` (6, 7 and 4); `:epec` is the EPEC event itself; the rest
      take the caller's `:contingency` option. Never inferred from an access key.

  `:stop` carries the same keys and adds:

    * `:outcome` - `:ok` for `{:ok, _}`; otherwise the tag of the error, the
      same rule `[:sefaz_nfe, :soap]` uses (`:timeout`, `:missing_keys`,
      `:invalid_tax_id`, `:circuit_open`, ...), or `:error` when it has none;
    * `:status` - `SefazNfe.Result.status/0` (`:authorized`, `:rejected`, ...),
      `nil` when the answer is not a `SefazNfe.Result` or the call failed;
    * `:c_stat` - the SEFAZ `cStat` as an integer, from a `SefazNfe.Result`, a
      `SefazNfe.DistDFe` or a `SefazNfe.TaxpayerLookup`; `nil` otherwise.

  `:outcome` is the transport and validation verdict: a rejection is
  `outcome: :ok` with `status: :rejected`, because SEFAZ answered.

  ### What is never in the metadata

  No certificate, password, CSC, signed or unsigned XML, access key (`chNFe`),
  CNPJ/CPF or state registration. The first four are secrets, and metadata goes
  to loggers, APM agents and third-party dashboards. The last three are
  unbounded: as a metric label each value is a new time series, which is how a
  Prometheus gets taken down. `:uf`, `:host`, `:environment`, `:model` and `:outcome`
  are all small closed sets, which is what makes them safe tags.

  ## SOAP span: `[:sefaz_nfe, :soap, :start | :stop | :exception]`

  One per request actually sent, with `:endpoint`, `:host`, `:uf` and `:service`
  (`:nfe_autorizacao`, ...), plus `:environment`, `:model` and `:contingency`
  as above, and `:outcome` on `:stop`. `:host` is `"scheme://host:port"` of the
  endpoint, lower case: the server actually called, which is what the breaker
  is keyed by (about forty of them, so safe as a tag). A call refused by the circuit breaker
  emits no SOAP span: see the breaker events. Only the total duration exists on
  the default transport; see `SefazNfe.SOAP`.

  ## Circuit breaker

    * `[:sefaz_nfe, :circuit_breaker, :open]` - a host's breaker tripped (it
      reached the failure threshold, or a trial call failed after the cooldown);
    * `[:sefaz_nfe, :circuit_breaker, :close]` - a call reached SEFAZ and closed
      a breaker that was open;
    * `[:sefaz_nfe, :circuit_breaker, :rejected]` - a call was refused, fast,
      because the breaker is open.

  Measurements are `%{count: 1}` and, for `:open` and `:close`, also
  `:system_time`. Metadata is `%{host: String.t()}`: the breaker is per server, not per UF,
  because one UF reaches several servers by model and many share SVRS.

  The breaker is ETS plus atomic counters and is deliberately not linearised
  (see `SefazNfe.CircuitBreaker`), so concurrent failures at the threshold can
  produce a duplicate `:open`. Treat `:open` as "at least once per trip".

  ## Telemetry.Metrics / PromEx

  `telemetry_metrics` is not a dependency of this library; this is for the
  host's own `Telemetry.Metrics` list, or a `PromEx` plugin's `event_metrics`:

      import Telemetry.Metrics

      [
        counter("sefaz_nfe.operation.count",
          event_name: [:sefaz_nfe, :operation, :stop],
          tags: [:operation, :uf, :outcome]
        ),
        distribution("sefaz_nfe.operation.duration",
          event_name: [:sefaz_nfe, :operation, :stop],
          measurement: :duration,
          unit: {:native, :millisecond},
          tags: [:operation, :uf],
          reporter_options: [buckets: [50, 100, 250, 500, 1_000, 2_500, 5_000, 15_000, 30_000]]
        ),
        counter("sefaz_nfe.circuit_breaker.open.count",
          event_name: [:sefaz_nfe, :circuit_breaker, :open],
          tags: [:host]
        ),
        counter("sefaz_nfe.circuit_breaker.rejected.count",
          event_name: [:sefaz_nfe, :circuit_breaker, :rejected],
          tags: [:host]
        ),
        last_value("sefaz_nfe.circuit_breaker.open.system_time",
          event_name: [:sefaz_nfe, :circuit_breaker, :open],
          measurement: :system_time,
          unit: {:native, :second},
          tags: [:host]
        )
      ]

  A `nil` tag value (`:uf` of a call that gave none) is reported as an empty
  label by most reporters; use `tag_values:` to map it if that matters.
  """

  @events [
    [:sefaz_nfe, :operation, :start],
    [:sefaz_nfe, :operation, :stop],
    [:sefaz_nfe, :operation, :exception],
    [:sefaz_nfe, :soap, :start],
    [:sefaz_nfe, :soap, :stop],
    [:sefaz_nfe, :soap, :exception],
    [:sefaz_nfe, :circuit_breaker, :open],
    [:sefaz_nfe, :circuit_breaker, :close],
    [:sefaz_nfe, :circuit_breaker, :rejected]
  ]

  @an_operations [:dist_dfe, :manifest, :epec]
  @environments [:production, :homologation]
  @contingencies [:svc_an, :svc_rs]

  @doc "Every event name this library emits."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc false
  # Runs `fun` (given `opts` plus the context the SOAP span reuses) inside the
  # operation span.
  @spec span(atom(), map(), (map() -> result)) :: result when result: term()
  def span(operation, opts, fun) do
    context = context(operation, opts)
    start = Map.put(context, :operation, operation)

    :telemetry.span([:sefaz_nfe, :operation], start, fn ->
      result = fun.(Map.put(opts, :telemetry_context, context))
      {result, Map.merge(start, stop_fields(result))}
    end)
  end

  @doc false
  # The low-cardinality tag of a result, shared with the SOAP span.
  @spec outcome(term()) :: atom()
  def outcome({:ok, _body}), do: :ok
  def outcome({:error, reason}) when is_atom(reason), do: reason
  def outcome({:error, {tag, _detail}}) when is_atom(tag), do: tag
  def outcome({:error, {tag, _detail, _more}}) when is_atom(tag), do: tag
  def outcome({:error, _reason}), do: :error

  defp stop_fields({:ok, %{c_stat: c_stat} = answer}) when is_integer(c_stat) do
    %{outcome: :ok, status: Map.get(answer, :status), c_stat: c_stat}
  end

  defp stop_fields(result), do: %{outcome: outcome(result), status: nil, c_stat: nil}

  defp context(operation, opts) do
    %{
      uf: uf(operation, opts),
      environment: environment(opts),
      model: model(operation, opts),
      contingency: contingency(operation, opts)
    }
  end

  defp uf(operation, _opts) when operation in @an_operations, do: "AN"

  defp uf(_operation, opts) do
    with uf when is_binary(uf) or is_atom(uf) <- Map.get(opts, :uf),
         uf = uf |> to_string() |> String.upcase(),
         {:ok, _code} <- SefazNfe.Endpoints.uf_code(uf) do
      uf
    else
      _ -> nil
    end
  end

  defp environment(opts) do
    case Map.get(opts, :environment) do
      environment when environment in @environments -> environment
      _ -> nil
    end
  end

  defp model(operation, opts) when operation in [:authorize, :epec] do
    case xml_tag(Map.get(opts, :xml), "mod") do
      "55" -> 55
      "65" -> 65
      _ when operation == :epec -> 55
      _ -> nil
    end
  end

  defp model(operation, opts) when operation in [:consult_protocol, :cancel, :cce] do
    case Map.get(opts, :ch_nfe) do
      <<_::binary-size(20), "55", _::binary>> -> 55
      <<_::binary-size(20), "65", _::binary>> -> 65
      _ -> nil
    end
  end

  defp model(:manifest, _opts), do: 55
  defp model(:mdfe_service_status, _opts), do: 58

  defp model(:cte_service_status, opts) do
    case Map.get(opts, :model, 57) do
      model when model in [57, 67] -> model
      _ -> nil
    end
  end

  defp model(operation, _opts) when operation in [:dist_dfe, :consult_taxpayer], do: nil

  defp model(_operation, opts) do
    case Map.get(opts, :model, 55) do
      model when model in [55, 65] -> model
      _ -> nil
    end
  end

  defp contingency(:epec, _opts), do: :epec

  defp contingency(:authorize, opts) do
    case xml_tag(Map.get(opts, :xml), "tpEmis") do
      "4" -> :epec
      "6" -> :svc_an
      "7" -> :svc_rs
      _ -> nil
    end
  end

  defp contingency(operation, _opts) when operation in [:dist_dfe, :manifest], do: nil

  defp contingency(_operation, opts) do
    case Map.get(opts, :contingency) do
      svc when svc in @contingencies -> svc
      _ -> nil
    end
  end

  # The first occurrence, which in a NF-e is `ide`'s. Not a parse: the operation
  # span must stay cheap on a call that is about to be refused anyway.
  defp xml_tag(xml, tag) when is_binary(xml) do
    case Regex.run(~r|<#{tag}>([^<]*)</#{tag}>|, xml, capture: :all_but_first) do
      [value] -> value
      nil -> nil
    end
  end

  defp xml_tag(_xml, _tag), do: nil
end
