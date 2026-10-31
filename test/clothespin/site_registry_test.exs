defmodule Clothespin.SiteRegistryTest do
  use ExUnit.Case, async: true

  alias Clothespin.SiteRegistry

  test "register, sites, pids, replace, and automatic DOWN cleanup" do
    room = "room-registry-test"
    parent = self()

    {:ok, bridge} =
      Task.start(fn ->
        receive do
          :stop -> :ok
        end
      end)

    :ok = SiteRegistry.register(room, "alpha", bridge)
    assert SiteRegistry.sites(room) == ["alpha"]
    assert SiteRegistry.pids(room) == [bridge]

    {:ok, other} =
      Task.start(fn ->
        receive do
          :stop -> :ok
        end
      end)

    :ok = SiteRegistry.register(room, "beta", other)
    assert Enum.sort(SiteRegistry.sites(room)) == ["alpha", "beta"]
    assert length(SiteRegistry.pids(room)) == 2
    assert SiteRegistry.pids_except(room, "alpha") == [other]
    assert SiteRegistry.pids_except(room, nil) |> length() == 2

    # Re-register the same site: replaces the pid.
    :ok = SiteRegistry.register(room, "alpha", other)
    assert SiteRegistry.site_pid(room, "alpha") == other
    assert Enum.sort(SiteRegistry.sites(room)) == ["alpha", "beta"]

    # Manual unregister.
    :ok = SiteRegistry.unregister(room, "beta")
    assert SiteRegistry.sites(room) == ["alpha"]

    # Process death clears its registrations.
    ref = Process.monitor(bridge)
    send(bridge, :stop)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      1_000 -> flunk("bridge did not exit")
    end

    # DOWN is async; give the registry a beat.
    wait_until(fn -> SiteRegistry.sites(room) == [] end)

    send(other, :stop)
  end

  defp wait_until(fun, tries \\ 10) do
    if fun.() or tries == 0 do
      :ok
    else
      Process.sleep(50)
      wait_until(fun, tries - 1)
    end
  end
end
