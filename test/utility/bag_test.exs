defmodule Test.Utility.BagTest do
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Service.HookManager

  use ExUnit.Case

  test "hook erlang send" do
    assert Bag.hook_erlang_send("hook_data", self(), "msg") === {"msg", "hook_data"}
    assert_receive {"msg", "hook_data"}
  end

  test "timestamp" do
    seconds = Bag.timestamp()
    milliseconds = Bag.timestamp(:millisecond)
    assert is_integer(seconds) && seconds <= DateTime.utc_now() |> DateTime.to_unix(:second)

    assert is_integer(milliseconds) &&
             milliseconds <= DateTime.utc_now() |> DateTime.to_unix(:millisecond)
  end

  test "receive multiple" do
    assert_raise RuntimeError, "failed iteration: 1.", fn ->
      Bag.receive_multiple(1, :none, timeout: 1)
    end
  end

  test "gen child specs" do
    child_specs = Bag.gen_child_specs(10, prefix: "gen_test", id_type: :atom)

    assert length(child_specs) === 10

    Enum.reduce(child_specs, 1, fn child_spec, acc ->
      assert child_spec === %{
               id: :"gen_test#{acc}",
               start: {Test.Helper.TestServer, :start_link, [%{name: :"gen_test#{acc}"}]}
             }

      acc + 1
    end)
  end

  test "all messages" do
    assert Bag.all_messages() === []

    messages = [:hello, :world, :all, :messages, :test]

    Enum.each(messages, fn message ->
      send(self(), message)
    end)

    assert Bag.all_messages() === messages
  end

  test "generate hook receiver" do
    self = self()

    assert Bag.recv_hook(:recv_hook_key, self) === %HookManager{
             id: :recv_hook_key,
             m: ProcessHub.Utility.Bag,
             f: :hook_erlang_send,
             a: [:_, self, :recv_hook_key],
             p: 0
           }
  end

  test "get_by_key with atom keys" do
    list = [{:a, 1}, {:b, 2}, {:c, 3}]

    assert Bag.get_by_key(list, :a) === 1
    assert Bag.get_by_key(list, :b) === 2
    assert Bag.get_by_key(list, :c) === 3
  end

  test "get_by_key with string keys" do
    list = [{"key1", "value1"}, {"key2", "value2"}, {"key3", "value3"}]

    assert Bag.get_by_key(list, "key1") === "value1"
    assert Bag.get_by_key(list, "key2") === "value2"
    assert Bag.get_by_key(list, "key3") === "value3"
  end

  test "get_by_key with mixed key types" do
    list = [{:atom_key, "atom_value"}, {"string_key", :string_value}, {1, "number_value"}]

    assert Bag.get_by_key(list, :atom_key) === "atom_value"
    assert Bag.get_by_key(list, "string_key") === :string_value
    assert Bag.get_by_key(list, 1) === "number_value"
  end

  test "get_by_key with non-existing keys returns default" do
    list = [{:a, 1}, {:b, 2}]

    # Default to nil when not provided
    assert Bag.get_by_key(list, :non_existing) === nil

    # Custom default value
    assert Bag.get_by_key(list, :non_existing, :default) === :default
    assert Bag.get_by_key(list, :non_existing, "not found") === "not found"
    assert Bag.get_by_key(list, :non_existing, 42) === 42
  end

  test "get_by_key with empty list returns default" do
    assert Bag.get_by_key([], :any_key) === nil
    assert Bag.get_by_key([], :any_key, :default) === :default
    assert Bag.get_by_key([], "any_key", "default") === "default"
  end

  test "get_by_key returns first matching value" do
    # List with duplicate keys - should return first match
    list = [{:a, "first"}, {:b, 2}, {:a, "second"}]

    assert Bag.get_by_key(list, :a) === "first"
    assert Bag.get_by_key(list, :b) === 2
  end

  test "get_by_key with complex values" do
    list = [
      {:config, %{setting: "value"}},
      {:list, [1, 2, 3]},
      {:tuple, {:nested, :tuple}},
      {:pid, self()}
    ]

    assert Bag.get_by_key(list, :config) === %{setting: "value"}
    assert Bag.get_by_key(list, :list) === [1, 2, 3]
    assert Bag.get_by_key(list, :tuple) === {:nested, :tuple}
    assert Bag.get_by_key(list, :pid) === self()
  end

  test "get_by_key strict equality matching" do
    list = [{1, "integer"}, {"1", "string"}, {:one, "atom"}]

    # Should only match exact types (===)
    assert Bag.get_by_key(list, 1) === "integer"
    assert Bag.get_by_key(list, "1") === "string"
    assert Bag.get_by_key(list, :one) === "atom"

    # These should not match and return default
    assert Bag.get_by_key(list, 1.0, :not_found) === :not_found
    assert Bag.get_by_key(list, :"1", :not_found) === :not_found
  end

  test "get_by_key with nil values" do
    list = [{:nil_value, nil}, {:normal, "value"}]

    assert Bag.get_by_key(list, :nil_value) === nil
    assert Bag.get_by_key(list, :normal) === "value"

    # Should distinguish between nil value and missing key
    assert Bag.get_by_key(list, :nil_value, :default) === nil
    assert Bag.get_by_key(list, :missing, :default) === :default
  end

  describe "receive_until/4" do
    test "collects messages until halt condition" do
      # Send messages to self
      send(self(), {:test_key, 1})
      send(self(), {:test_key, 2})
      send(self(), {:test_key, 3})

      result =
        Bag.receive_until(
          :test_key,
          [],
          fn acc, data ->
            new_acc = [data | acc]
            if length(new_acc) >= 3, do: {:halt, Enum.reverse(new_acc)}, else: {:cont, new_acc}
          end, timeout: 1000)

      assert result === [1, 2, 3]
    end

    test "accumulates values correctly" do
      send(self(), {:sum_key, 10})
      send(self(), {:sum_key, 20})
      send(self(), {:sum_key, 30})

      result =
        Bag.receive_until(
          :sum_key,
          0,
          fn acc, data ->
            new_acc = acc + data
            if new_acc >= 60, do: {:halt, new_acc}, else: {:cont, new_acc}
          end, timeout: 1000)

      assert result === 60
    end

    test "raises on timeout" do
      assert_raise RuntimeError, "receive_until timeout", fn ->
        Bag.receive_until(
          :no_msg_key,
          :init,
          fn acc, _data ->
            {:cont, acc}
          end, timeout: 50)
      end
    end

    test "works with tuple receive key" do
      send(self(), {:key_a, :data_a})
      send(self(), {:key_b, :data_b})

      result =
        Bag.receive_until(
          {:key_a, :key_b},
          [],
          fn acc, data ->
            new_acc = [data | acc]
            if length(new_acc) >= 2, do: {:halt, Enum.reverse(new_acc)}, else: {:cont, new_acc}
          end, timeout: 1000)

      assert result === [:data_a, :data_b]
    end

    test "custom error message on timeout" do
      assert_raise RuntimeError, "custom timeout msg", fn ->
        Bag.receive_until(
          :no_msg,
          :init,
          fn acc, _data ->
            {:cont, acc}
          end, timeout: 50, error_msg: "custom timeout msg")
      end
    end
  end

  describe "await_cluster_join/2" do
    test "receives join messages for local scope" do
      # Simulate hook messages for 2 joining nodes
      send(self(), {ProcessHub.Constant.Hook.post_cluster_join(), %{joined_node: :node1}})
      send(self(), {ProcessHub.Constant.Hook.post_cluster_join(), %{joined_node: :node2}})

      result = Bag.await_cluster_join([:node1, :node2], scope: :local, timeout: 1000)

      assert length(result) === 2

      assert Enum.all?(result, fn
               {:ok, _data} -> true
               _ -> false
             end)
    end

    test "accepts integer count" do
      send(self(), {ProcessHub.Constant.Hook.post_cluster_join(), %{joined_node: :node1}})
      send(self(), {ProcessHub.Constant.Hook.post_cluster_join(), %{joined_node: :node2}})

      result = Bag.await_cluster_join(2, scope: :local, timeout: 1000)

      assert length(result) === 2
    end

    test "returns empty list for 0 joining nodes" do
      result = Bag.await_cluster_join([], scope: :local)
      assert result === []
    end

    test "global scope calculates correct message count" do
      # For global scope with 1 joining node and cluster_size 2:
      # count = 1 * (2 + 1) = 3 messages
      for _ <- 1..3 do
        send(self(), {ProcessHub.Constant.Hook.post_cluster_join(), %{joined_node: :new_node}})
      end

      result = Bag.await_cluster_join(1, scope: :global, cluster_size: 2, timeout: 1000)
      assert length(result) === 3
    end
  end

  describe "await_cluster_leave/2" do
    test "receives leave messages for local scope" do
      send(self(), {ProcessHub.Constant.Hook.post_cluster_leave(), %{removed_node: :node1}})

      result = Bag.await_cluster_leave([:node1], scope: :local, timeout: 1000)

      assert length(result) === 1
      assert [{:ok, %{removed_node: :node1}}] = result
    end

    test "returns empty list for 0 leaving nodes" do
      result = Bag.await_cluster_leave([], scope: :local)
      assert result === []
    end

    test "global scope calculates correct message count" do
      # For global scope with 1 leaving node and cluster_size 3:
      # count = 1 * (3 - 1) = 2 messages
      for _ <- 1..2 do
        send(self(), {ProcessHub.Constant.Hook.post_cluster_leave(), %{removed_node: :gone_node}})
      end

      result = Bag.await_cluster_leave(1, scope: :global, cluster_size: 3, timeout: 1000)
      assert length(result) === 2
    end
  end

  describe "await_child_ids/3" do
    test "collects all expected child_ids" do
      # Send messages containing child_ids in batches
      send(self(), {:hook_key, %{child_ids: [:child1, :child2]}})
      send(self(), {:hook_key, %{child_ids: [:child3]}})

      result = Bag.await_child_ids(:hook_key, [:child1, :child2, :child3], timeout: 1000)

      assert is_list(result)
      assert length(result) === 2

      all_received_ids =
        Enum.flat_map(result, fn data -> Map.get(data, :child_ids, []) end)

      assert :child1 in all_received_ids
      assert :child2 in all_received_ids
      assert :child3 in all_received_ids
    end

    test "halts as soon as all child_ids received" do
      # First message covers all expected ids
      send(self(), {:hook2, %{child_ids: [:a, :b, :c]}})
      # This message should not be consumed
      send(self(), {:hook2, %{child_ids: [:extra]}})

      result = Bag.await_child_ids(:hook2, [:a, :b, :c], timeout: 1000)

      assert length(result) === 1
      assert List.first(result).child_ids === [:a, :b, :c]
    end

    test "supports custom child_ids_key" do
      send(self(), {:custom_hook, %{my_ids: [:x, :y]}})

      result =
        Bag.await_child_ids(:custom_hook, [:x, :y],
          timeout: 1000,
          child_ids_key: :my_ids
        )

      assert length(result) === 1
      assert List.first(result).my_ids === [:x, :y]
    end

    test "raises on timeout when not all ids received" do
      send(self(), {:timeout_hook, %{child_ids: [:partial]}})

      assert_raise RuntimeError, "await_child_ids timeout", fn ->
        Bag.await_child_ids(:timeout_hook, [:partial, :missing], timeout: 100)
      end
    end
  end

  test "get_by_key edge cases" do
    # Single element list
    assert Bag.get_by_key([{:only, "value"}], :only) === "value"
    assert Bag.get_by_key([{:only, "value"}], :missing) === nil

    # List with non-tuple elements should not crash and won't match
    # (though this would be invalid input in practice)
    mixed_list = [{:valid, "value"}, :not_a_tuple, {:another, "value2"}]
    assert Bag.get_by_key(mixed_list, :valid) === "value"
    assert Bag.get_by_key(mixed_list, :another) === "value2"
    # Non-tuple elements should be ignored
    assert Bag.get_by_key([:not_a_tuple, {:key, "value"}], :key) === "value"

    # Empty tuples and single-element tuples should be ignored
    weird_list = [{}, {:single}, {:key, "value"}]
    assert Bag.get_by_key(weird_list, :key) === "value"
    assert Bag.get_by_key(weird_list, :missing, :default) === :default
  end
end
