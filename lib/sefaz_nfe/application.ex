defmodule SefazNfe.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    start_httpc_profile()

    children = [
      {Task.Supervisor, name: SefazNfe.TaskSupervisor},
      {Registry, keys: :unique, name: SefazNfe.Registry},
      {DynamicSupervisor, name: SefazNfe.DistDFe.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SefazNfe.Supervisor)
  end

  # A private :httpc profile, so the library never reads or mutates the host's
  # global HTTP settings. Already started is fine: releases restart applications.
  defp start_httpc_profile do
    case :inets.start(:httpc, profile: :sefaz_nfe) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
