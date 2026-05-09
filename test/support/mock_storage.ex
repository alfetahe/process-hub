defmodule Test.Support.MockStorage do
  @moduledoc """
  In-memory `ProcessHub.Service.Storage.Behaviour` implementation used
  for testing custom-backend dispatch.

  Wraps a per-hub ETS table and records the most recent operation in a
  shared registry so tests can assert that calls reached the backend.
  """

  @behaviour ProcessHub.Service.Storage.Behaviour

  @ops_table :test_support_mock_storage_ops

  defp ensure_ops_table do
    case :ets.info(@ops_table) do
      :undefined ->
        try do
          :ets.new(@ops_table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp record(hub_id, op) do
    ensure_ops_table()
    :ets.insert(@ops_table, {hub_id, op})
  end

  @doc """
  Returns true if `open/2` has been called for `hub_id`.
  """
  def opened?(hub_id) do
    ensure_ops_table()

    case :ets.lookup(@ops_table, {:opened, hub_id}) do
      [] -> false
      _ -> true
    end
  end

  @doc "Returns the last recorded op for `hub_id`."
  def last_op(hub_id) do
    ensure_ops_table()

    case :ets.lookup(@ops_table, hub_id) do
      [] -> nil
      [{^hub_id, op}] -> op
    end
  end

  @impl true
  def open(hub_id, _opts) do
    ensure_ops_table()
    table = :ets.new(:"mock_storage_#{hub_id}", [:set, :public])
    :ets.insert(@ops_table, {{:opened, hub_id}, table})
    record(hub_id, :open)
    {:ok, table}
  end

  @impl true
  def close(ref) do
    if :ets.info(ref) !== :undefined, do: :ets.delete(ref)
    :ok
  end

  @impl true
  def insert(ref, key, value) do
    :ets.insert(ref, {key, value})
    record_for_ref(ref, :insert)
    :ok
  end

  @impl true
  def insert(ref, key, value, _opts) do
    :ets.insert(ref, {key, value})
    record_for_ref(ref, :insert)
    :ok
  end

  @impl true
  def get(ref, key) do
    record_for_ref(ref, :get)

    case :ets.lookup(ref, key) do
      [] -> nil
      [{_, value}] -> value
      [{_, value, _ttl}] -> value
    end
  end

  @impl true
  def exists?(ref, key) do
    record_for_ref(ref, :exists?)
    :ets.lookup(ref, key) !== []
  end

  @impl true
  def remove(ref, key) do
    :ets.delete(ref, key)
    record_for_ref(ref, :remove)
    :ok
  end

  @impl true
  def export_all(ref) do
    record_for_ref(ref, :export_all)
    :ets.tab2list(ref)
  end

  @impl true
  def foldl(ref, acc, fun) do
    record_for_ref(ref, :foldl)
    :ets.foldl(fun, acc, ref)
  end

  @impl true
  def match(ref, expr) do
    record_for_ref(ref, :match)
    ref |> :ets.match(expr) |> Enum.map(&List.to_tuple/1)
  end

  @impl true
  def clear_all(ref) do
    :ets.delete_all_objects(ref)
    record_for_ref(ref, :clear_all)
    :ok
  end

  defp record_for_ref(ref, op) do
    ensure_ops_table()
    # Reverse-look-up hub_id from ref via the {:opened, hub_id} entries.
    case :ets.match(@ops_table, {{:opened, :"$1"}, ref}) do
      [[hub_id]] -> record(hub_id, op)
      _ -> :ok
    end
  end
end
