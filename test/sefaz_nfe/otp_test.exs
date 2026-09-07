defmodule SefazNfe.OTPTest do
  use ExUnit.Case, async: false

  @cert elem(SefazNfe.Certificate.load(<<"pkcs12-placeholder">>, "secret"), 1)

  test "DistDFe poller is labelled and registered per CNPJ" do
    cnpj = "00000000000191"

    assert {:ok, pid} =
             SefazNfe.start_dist_dfe_poller(
               cnpj: cnpj,
               cert: @cert,
               ambiente: :homologacao,
               interval: Duration.new!(day: 1)
             )

    assert Process.get_label(pid) == {:sefaz_nfe, :dist_dfe, cnpj}
    assert [{^pid, _}] = Registry.lookup(SefazNfe.Registry, {:dist_dfe, cnpj})

    assert {:error, {:already_started, ^pid}} =
             SefazNfe.start_dist_dfe_poller(cnpj: cnpj, cert: @cert)
  after
    stop_poller("00000000000191")
  end

  test "isolated SOAP crash does not take down the caller" do
    previous = Application.get_env(:sefaz_nfe, :soap)
    Application.put_env(:sefaz_nfe, :soap, SefazNfe.OTPTest.Boom)

    try do
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:soap_crash, _}} =
                 SefazNfe.SOAP.isolated_call("https://example.test", "<nfe/>", @cert)
      end)
    after
      restore_soap(previous)
    end
  end

  test "JSON.encode Result without xml body" do
    result = %SefazNfe.Result{
      status: :autorizada,
      c_stat: 100,
      x_motivo: "Autorizado o uso da NF-e",
      ch_nfe: String.duplicate("1", 44)
    }

    map = JSON.decode!(JSON.encode!(result))
    assert map["c_stat"] == 100
    refute Map.has_key?(map, "xml")
  end

  defp stop_poller(cnpj) do
    case Registry.lookup(SefazNfe.Registry, {:dist_dfe, cnpj}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(SefazNfe.DistDFe.Supervisor, pid)
      [] -> :ok
    end
  end

  defp restore_soap(nil), do: Application.delete_env(:sefaz_nfe, :soap)
  defp restore_soap(mod), do: Application.put_env(:sefaz_nfe, :soap, mod)

  defmodule Boom do
    @behaviour SefazNfe.SOAP
    @impl SefazNfe.SOAP
    def call(_endpoint, _body, _cert, _opts), do: raise("sefaz down")
  end
end
