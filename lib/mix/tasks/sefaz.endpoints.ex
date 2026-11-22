defmodule Mix.Tasks.Sefaz.Endpoints do
  @shortdoc "Audits the SEFAZ endpoint snapshot and prints the refresh procedure"

  @moduledoc """
  Audits `priv/endpoints/nfe_4.00.json` (model 55) and
  `priv/endpoints/nfce_4.00.json` (model 65).

      mix sefaz.endpoints
      mix sefaz.endpoints --max-age 90
      mix sefaz.endpoints --file priv/endpoints/nfce_4.00.json

  AD-004 makes the endpoint table data owned by the RFB, not by this repository,
  refreshed from the official portal. The portal blocks automated fetching, so
  this task deliberately does not scrape it: a scraper that silently returns a
  login page would replace a stale table with a wrong one. It audits what is
  vendored and prints the manual procedure instead.

  Reports a non-zero exit when the snapshot is older than `--max-age` days
  (default 180) or fails a structural check, so CI can fail on a stale table
  rather than a production call discovering it.

  ## The model 65 table

  It has the same shape as the model 55 one, so the webservice URLs follow the
  same rule: https and a `.gov.br` host. Beyond that, every UF must have an
  authorizer (its own or SVRS) and, in both environments, a `qr_code` and a
  `url_chave`. The IBGE codes live in the model 55 table only.

  The two address maps are held to a looser rule on purpose, because they are
  published that way and go into the XML as SEFAZ expects to read them back:

    * `url_chave` is not URL-checked at all. Some entries have no scheme
      (`www.sefaz.ac.gov.br/nfce/consulta`) and some are plain http; the
      only constraint is the XSD's own, 21 to 85 characters.
    * `qr_code` must be an http or https URL on a `.gov.br` host, or on a bare
      IPv4 literal (RR's homologation address is published as one). Several UFs
      still publish plain http QR addresses (AC, AL, BA, CE, DF among them),
      and the QR code is a link a consumer opens, not a channel this library
      sends a certificate over, so https is not demanded; the host rule still
      catches a hand-edit that points it at something that is not SEFAZ.

  ## Refresh procedure

  1. Open https://www.nfe.fazenda.gov.br/portal/webServices.aspx and read the
     table for layout 4.00, model 55.
  2. Update `priv/endpoints/nfe_4.00.json`: `authorizers` holds one entry per
     authorizer with `homologation` and `production` URLs per service,
     `uf_authorizer` maps each UF to its authorizer, `uf_code` the IBGE code
     the envelopes carry as `cUF`. `operations` holds the SOAP operation per
     authorizer for `nfe_consulta_cadastro`, the one service whose
     authorizers disagree on it (`default` plus overrides).
  3. Set `snapshot_date` to the date you read the portal.
  4. Run `mix sefaz.endpoints` and `mix test`.

  For model 65 read the NFC-e table and update `priv/endpoints/nfce_4.00.json`
  the same way, plus `qr_code` (the `NfeConsultaQR` address per UF) and
  `url_chave` (the consulta-por-chave address per UF), both keyed by
  environment and then UF.

  The nfephp `wsnfe_4.00_mod55.xml`, `wsnfe_4.00_mod65.xml` and
  `uri_consulta_nfce.json` mirrors are a useful cross-check, never the source
  of truth.
  """

  use Mix.Task

  @services ~w(nfe_autorizacao nfe_ret_autorizacao nfe_consulta_protocolo
               nfe_status_servico nfe_recepcao_evento nfe_inutilizacao)
  @default_max_age 180
  @default_files ["priv/endpoints/nfe_4.00.json", "priv/endpoints/nfce_4.00.json"]
  @environments ["homologation", "production"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [max_age: :integer, file: :string])
    files = if file = opts[:file], do: [file], else: @default_files
    max_age = Keyword.get(opts, :max_age, @default_max_age)

    results =
      for file <- files do
        snapshot = JSON.decode!(File.read!(file))
        {file, snapshot, audit(snapshot, max_age)}
      end

    Enum.each(results, fn {file, snapshot, problems} -> report(file, snapshot, problems) end)

    case Enum.flat_map(results, fn {_file, _snapshot, problems} -> problems end) do
      [] ->
        :ok

      problems ->
        Mix.raise(
          "endpoint snapshot has #{length(problems)} problem(s); see the refresh procedure"
        )
    end
  end

  @doc """
  Every problem found in `snapshot`, as human-readable strings. Empty means it
  is usable.
  """
  @spec audit(map(), pos_integer()) :: [String.t()]
  def audit(snapshot, max_age \\ @default_max_age) do
    age(snapshot, max_age) ++
      coverage(snapshot) ++ urls(snapshot) ++ operations(snapshot) ++ nfce(snapshot)
  end

  defp report(file, snapshot, []) do
    Mix.shell().info([
      :green,
      "endpoint snapshot ok",
      :reset,
      "  #{file}",
      "  date=#{snapshot["snapshot_date"]}",
      "  authorizers=#{map_size(snapshot["authorizers"])}",
      "  ufs=#{map_size(snapshot["uf_authorizer"])}"
    ])
  end

  defp report(file, _snapshot, problems) do
    Mix.shell().error("#{file}:")
    Enum.each(problems, &Mix.shell().error("  #{&1}"))
  end

  defp age(snapshot, max_age) do
    case Date.from_iso8601(snapshot["snapshot_date"] || "") do
      {:ok, date} -> stale(Date.diff(Date.utc_today(), date), max_age)
      {:error, _reason} -> ["snapshot_date is missing or not ISO 8601"]
    end
  end

  defp stale(days, max_age) when days > max_age do
    ["snapshot is #{days} days old (limit #{max_age}); re-read the portal"]
  end

  defp stale(_days, _max_age), do: []

  # Every UF must resolve to an authorizer that actually carries the six
  # per-UF services. A UF pointing at a missing authorizer is the failure mode
  # a hand-edited table produces, and it only shows up when someone emits.
  defp coverage(snapshot) do
    for {uf, authorizer} <- snapshot["uf_authorizer"],
        environment <- ["homologation", "production"],
        service <- @services,
        not present?(get_in(snapshot, ["authorizers", authorizer, environment, service])) do
      "#{uf} (#{authorizer}) has no #{environment} #{service}"
    end
  end

  defp present?(url), do: is_binary(url) and url != ""

  # `operations` holds the SOAP operation of the services whose authorizers
  # disagree on it (NFeConsultaCadastro). Each entry needs a "default", and an
  # override naming an authorizer that is not in the table is a typo that would
  # silently never apply. Such a service is optional per authorizer (AM and
  # SVAN do not offer it), so it is not part of coverage/1.
  defp operations(snapshot) do
    for {service, entries} <- Map.get(snapshot, "operations", %{}),
        problem <- operation_problems(snapshot, service, entries),
        do: problem
  end

  defp operation_problems(snapshot, service, entries) do
    default =
      if present?(entries["default"]), do: [], else: ["operations #{service} has no default"]

    unknown =
      for {authorizer, _operation} <- entries,
          authorizer != "default",
          not is_map_key(snapshot["authorizers"], authorizer),
          do: "operations #{service} names unknown authorizer #{authorizer}"

    default ++ unknown
  end

  defp urls(snapshot) do
    missing_codes =
      for {uf, _authorizer} <- snapshot["uf_authorizer"],
          snapshot["model"] != 65,
          not is_integer(snapshot["uf_code"][uf]),
          do: "#{uf} has no IBGE uf_code"

    # A blank URL is already reported by coverage/1; reporting it twice under a
    # second heading only obscures which entry actually needs editing.
    bad_urls =
      for {_authorizer, environments} <- snapshot["authorizers"],
          {_environment, services} <- environments,
          {service, url} <- services,
          present?(url),
          problem = url_problem(url),
          do: "#{service}: #{problem} (#{url})"

    missing_codes ++ bad_urls
  end

  # The model 65 table only: every UF needs a QR code and a urlChave address in
  # both environments. See the moduledoc for why they get a looser URL rule
  # than the webservice addresses.
  defp nfce(%{"model" => 65} = snapshot) do
    for {uf, _authorizer} <- snapshot["uf_authorizer"],
        environment <- @environments,
        problem <- nfce_address_problems(snapshot, uf, environment),
        do: problem
  end

  defp nfce(_snapshot), do: []

  defp nfce_address_problems(snapshot, uf, environment) do
    qr = get_in(snapshot, ["qr_code", environment, uf])
    chave = get_in(snapshot, ["url_chave", environment, uf])

    qr_problems =
      cond do
        not present?(qr) -> ["#{uf} has no #{environment} qr_code"]
        problem = qr_problem(qr) -> ["#{uf} #{environment} qr_code: #{problem} (#{qr})"]
        true -> []
      end

    chave_problems =
      cond do
        not present?(chave) ->
          ["#{uf} has no #{environment} url_chave"]

        String.length(chave) not in 21..85 ->
          ["#{uf} #{environment} url_chave: not 21 to 85 characters (#{chave})"]

        true ->
          []
      end

    qr_problems ++ chave_problems
  end

  defp qr_problem(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> "not http or https"
      not is_binary(uri.host) -> "no host"
      ipv4?(uri.host) -> nil
      not String.ends_with?(uri.host, ".gov.br") -> "host is not a government address"
      true -> nil
    end
  end

  # RR still publishes its homologation QR code address as a bare IPv4 literal.
  defp ipv4?(host),
    do: match?({:ok, _address}, :inet.parse_ipv4_address(String.to_charlist(host)))

  defp url_problem(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" -> "not https"
      not is_binary(uri.host) -> "no host"
      not String.ends_with?(uri.host, ".gov.br") -> "host is not a government address"
      true -> nil
    end
  end
end
