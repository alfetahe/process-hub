defmodule Test.ProcessHubLeadershipTest do
  @moduledoc """
  Increment 1 — opt-in leadership lifecycle + query.

  Runs synchronously (default, non-async): these tests start/stop the global
  `:elector` application, so they must not overlap with other tests.
  """
  use ExUnit.Case

  alias ProcessHub.Service.Leadership

  setup do
    # Guarantee a clean slate — leadership must not be started when a test begins.
    Leadership.stop()
    on_exit(fn -> Leadership.stop() end)
    :ok
  end

  test "leader/0 errors before start_leadership/0 and does not auto-start elector" do
    refute Leadership.started?()
    assert Process.whereis(:elector_state) == nil

    assert ProcessHub.leader() == {:error, :leadership_not_started}

    # The query must not have started elector as a side effect.
    assert Process.whereis(:elector_state) == nil
    refute Leadership.started?()
  end

  test "is_leader?/0 is false before start_leadership/0 and does not auto-start elector" do
    refute ProcessHub.is_leader?()
    assert Process.whereis(:elector_state) == nil
  end

  test "start_leadership/0 starts the local elector instance and elects the local node" do
    assert ProcessHub.start_leadership() == :ok

    assert Leadership.started?()
    assert Process.whereis(:elector_state) != nil

    assert ProcessHub.leader() == {:ok, node()}
    assert ProcessHub.is_leader?() == true
  end

  test "stop_leadership/0 stops the local elector instance" do
    assert ProcessHub.start_leadership() == :ok
    assert Leadership.started?()

    assert ProcessHub.stop_leadership() == :ok

    refute Leadership.started?()
    assert Process.whereis(:elector_state) == nil
    assert ProcessHub.leader() == {:error, :leadership_not_started}
    refute ProcessHub.is_leader?()
  end

  test "a hub with a non-elector distribution strategy does not start :global" do
    hub_id = :leadership_noelector_hub

    {:ok, pid} = ProcessHub.Initializer.start_link(%ProcessHub{hub_id: hub_id})
    :erlang.unlink(pid)
    on_exit(fn -> ProcessHub.Initializer.stop(hub_id) end)

    # The default ConsistentHashing strategy must not start elector/:global.
    assert Process.whereis(:elector_state) == nil
    refute ProcessHub.is_leader?()
    assert ProcessHub.leader() == {:error, :leadership_not_started}
  end

  # --- Increment 2: ergonomics (subscription, telemetry, on_leader) ----------

  test "start_leadership emits a [:process_hub, :leadership, :changed] telemetry transition" do
    ref = make_ref()
    parent = self()
    handler_id = {:leadership_telemetry, ref}

    :telemetry.attach(
      handler_id,
      [:process_hub, :leadership, :changed],
      fn _event, measurements, metadata, _config ->
        send(parent, {:telemetry, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert ProcessHub.start_leadership() == :ok

    assert_receive {:telemetry, ^ref, measurements, metadata}, 5000
    assert metadata.leader == node()
    assert metadata.previous == nil
    assert metadata.am_i_leader == true
    assert is_integer(measurements.system_time)
  end

  test "Leadership.subscribe/0 delivers an initial snapshot of the current leader" do
    assert ProcessHub.start_leadership() == :ok
    assert Leadership.subscribe() == :ok

    assert_receive {:processhub_leadership, %{leader: leader, previous: nil, am_i_leader: true}},
                   5000

    assert leader == node()
  end

  test "Leadership.unsubscribe/0 stops further leadership notifications" do
    assert ProcessHub.start_leadership() == :ok
    assert Leadership.subscribe() == :ok

    # Drain the initial snapshot, then unsubscribe.
    assert_receive {:processhub_leadership, _info}, 5000
    assert Leadership.unsubscribe() == :ok

    # Unsubscribing before leadership starts is also a safe no-op.
    assert Leadership.unsubscribe(self()) == :ok
  end

  test "on_leader/1 evaluates the function on the leader and returns its result" do
    assert ProcessHub.start_leadership() == :ok
    assert ProcessHub.is_leader?()

    assert ProcessHub.on_leader(fn -> :did_work end) == :did_work
  end

  test "on_leader/1 skips the function and returns {:error, :not_leader} when not the leader" do
    # Leadership not started -> local node is not the leader.
    refute ProcessHub.is_leader?()
    parent = self()

    assert ProcessHub.on_leader(fn ->
             send(parent, :should_not_run)
             :did_work
           end) == {:error, :not_leader}

    refute_receive :should_not_run, 200
  end
end
