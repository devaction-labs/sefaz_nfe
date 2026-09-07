defmodule Mix.Tasks.Sefaz.Endpoints do
  @shortdoc "Audits the SEFAZ endpoint snapshot and prints the refresh procedure"

  @moduledoc """
  Audits `priv/endpoints/nfe_4.00.json`.

      mix sefaz.endpoints
      mix sefaz.endpoints --max-age 90

  AD-004 makes the endpoint table data owned by the RFB, not by this repository,
  refreshed from the official portal. The portal blocks automated fetching, so
  this task deliberately does not scrape it: a scraper that silently returns a
  login page would replace a stale table with a wrong one. It audits what is
  vendored and prints the manual procedure instead.

  Reports a non-zero exit when the snapshot is older than `--max-age` days
  (default 180) or fails a structural check, so CI can fail on a stale table
  rather than a production call discovering it.

  ## Refresh procedure

  1. Open https://www.nfe.fazenda.gov.br/portal/webServices.aspx and read the
     table for layout 4.00, model 55.
  2. Update `priv/endpoints/nfe_4.00.json`: `authorizers` holds one entry per
     authorizer with `homologation` and `production` URLs per service,
     `uf_authorizer` maps each UF to its authorizer, `uf_code` the IBGE code
     the envelopes carry as `cUF`.
  3. Set `snapshot_date` to the date you read the portal.
  4. Run `mix sefaz.endpoints` and `mix test`.

  The nfephp `wsnfe_4.00_mod55.xml` mirror is a useful cross-check, never the
  source of truth.
  """

  use Mix.Task

  @services ~w(nfe_autorizacao nfe_ret_autorizacao nfe_consulta_protocolo
               nfe_status_servico nfe_recepcao_evento nfe_inutilizacao)
  @default_max_age 180

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [max_age: :integer, file: :string])
    file = Keyword.get(opts, :file, "priv/endpoints/nfe_4.00.json")
    max_age = Keyword.get(opts, :max_age, @default_max_age)

    snapshot = JSON.decode!(File.read!(file))

    report(snapshot, audit(snapshot, max_age))
  end

  @doc """
  Every problem found in `snapshot`, as human-readable strings. Empty means it
  is usable.
  """
  @spec audit(map(), pos_integer()) :: [String.t()]
  def audit(snapshot, max_age \\ @default_max_age) do
    age(snapshot, max_age) ++ coverage(snapshot) ++ urls(snapshot)
  end

  defp report(snapshot, []) do
    Mix.shell().info([
      :green,
      "endpoint snapshot ok",
      :reset,
      "  date=#{snapshot["snapshot_date"]}",
      "  authorizers=#{map_size(snapshot["authorizers"])}",
      "  ufs=#{map_size(snapshot["uf_authorizer"])}"
    ])
  end

  defp report(_snapshot, problems) do
    Enum.each(problems, &Mix.shell().error("  #{&1}"))
    Mix.raise("endpoint snapshot has #{length(problems)} problem(s); see the refresh procedure")
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

  defp urls(snapshot) do
    missing_codes =
      for {uf, _authorizer} <- snapshot["uf_authorizer"],
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
