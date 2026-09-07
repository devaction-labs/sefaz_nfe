defmodule SefazNfe.OTPTest do
  use ExUnit.Case, async: false

  @cert SefazNfe.Fixtures.cert()

  @tax_id "00000000000191"

  test "DistDFe poller is labelled and registered per tax_id" do
    assert {:ok, pid} = start_poller(handler: fn _page -> :ok end)

    assert Process.get_label(pid) == {:sefaz_nfe, :dist_dfe, @tax_id}
    assert [{^pid, _}] = Registry.lookup(SefazNfe.Registry, {:dist_dfe, @tax_id})

    assert {:error, {:already_started, ^pid}} = start_poller(handler: fn _page -> :ok end)
  after
    stop_poller(@tax_id)
  end

  test "poller sends tax_id downstream and hands the page to the handler" do
    test = self()

    {:ok, pid} =
      start_poller(
        ult_nsu: "000000000000010",
        handler: fn page ->
          send(test, {:page, page})
          :ok
        end
      )

    send(pid, :poll)

    assert_receive {:fetched, opts}
    assert opts.tax_id == @tax_id
    assert opts.ult_nsu == "000000000000010"

    assert_receive {:page, %SefazNfe.DistDFe{c_stat: 138}}
  after
    stop_poller(@tax_id)
  end

  test "handler owns the cursor: the next poll starts where it committed" do
    {:ok, pid} = start_poller(handler: fn _page -> {:ok, "000000000000042"} end)

    send(pid, :poll)
    assert_receive {:fetched, %{ult_nsu: "0"}}

    send(pid, :poll)
    assert_receive {:fetched, %{ult_nsu: "000000000000042"}}

    refute_received {:fetched, _}
    assert Process.alive?(pid)
  after
    stop_poller(@tax_id)
  end

  test "handler returning :stop stops the poller normally" do
    {:ok, pid} = start_poller(handler: fn _page -> :stop end)
    ref = Process.monitor(pid)

    send(pid, :poll)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "a transport error keeps the cursor and does not crash the poller" do
    {:ok, pid} =
      start_poller(
        fetch: fn _opts -> {:error, :timeout} end,
        handler: fn _page -> flunk("handler must not see a transport error") end
      )

    ref = Process.monitor(pid)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, :poll)
        _ = :sys.get_state(pid)
      end)

    assert log =~ "DistDFe poll failed"
    assert log =~ ":timeout"
    # LGPD: the identifier is masked to its last four characters.
    assert log =~ "**********0191"
    refute log =~ @tax_id
    refute_receive {:DOWN, ^ref, _, _, _}, 50
  after
    stop_poller(@tax_id)
  end

  test "poller refuses to start without a handler" do
    assert {:error, {%KeyError{key: :handler}, _}} =
             SefazNfe.start_dist_dfe_poller(tax_id: @tax_id, cert: @cert)
  end

  # The seam that keeps `mix test` off the network: a fetch stub that reports
  # what the poller asked for and answers a canned page (cursor caught up with
  # maxNSU, so the poller re-arms on :interval and not on the catch-up delay).
  defp start_poller(opts) do
    test = self()

    fetch = fn opts ->
      send(test, {:fetched, opts})

      {:ok,
       %SefazNfe.DistDFe{
         ult_nsu: "000000000000010",
         max_nsu: "000000000000010",
         c_stat: 138,
         documents: []
       }}
    end

    [tax_id: @tax_id, cert: @cert, interval: Duration.new!(day: 1), fetch: fetch]
    |> Keyword.merge(opts)
    |> SefazNfe.start_dist_dfe_poller()
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

  defp stop_poller(tax_id) do
    case Registry.lookup(SefazNfe.Registry, {:dist_dfe, tax_id}) do
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
