defmodule SefazNfe.DistDFe.Poller do
  @moduledoc """
  One process per CNPJ for `NFeDistribuicaoDFe`.

  The library does not persist `ult_nsu` — the host does. This process only
  owns the poll loop and a process label for Observer.
  """

  use GenServer

  @default_interval Duration.new!(minute: 5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    cnpj = Keyword.fetch!(opts, :cnpj)
    GenServer.start_link(__MODULE__, opts, name: via(cnpj))
  end

  @spec via(String.t()) :: {:via, module(), term()}
  def via(cnpj) when is_binary(cnpj) do
    {:via, Registry, {SefazNfe.Registry, {:dist_dfe, cnpj}}}
  end

  @impl true
  def init(opts) do
    cnpj = Keyword.fetch!(opts, :cnpj)
    Process.set_label({:sefaz_nfe, :dist_dfe, cnpj})

    state = %{
      cnpj: cnpj,
      cert: Keyword.fetch!(opts, :cert),
      ambiente: Keyword.get(opts, :ambiente, :homologacao),
      ult_nsu: Keyword.get(opts, :ult_nsu, "0"),
      interval: Keyword.get(opts, :interval, @default_interval)
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    _ =
      SefazNfe.dist_dfe(%{
        cert: state.cert,
        ambiente: state.ambiente,
        ult_nsu: state.ult_nsu
      })

    {:noreply, schedule(state)}
  end

  defp schedule(state) do
    Process.send_after(self(), :poll, to_timeout(state.interval))
    state
  end
end
