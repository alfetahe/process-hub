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
