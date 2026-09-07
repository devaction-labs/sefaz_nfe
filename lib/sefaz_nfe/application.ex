defmodule SefazNfe.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: SefazNfe.TaskSupervisor},
      {Registry, keys: :unique, name: SefazNfe.Registry},
      {DynamicSupervisor, name: SefazNfe.DistDFe.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SefazNfe.Supervisor)
  end
end
