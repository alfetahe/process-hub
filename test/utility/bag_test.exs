defmodule Test.Utility.BagTest do
  alias ProcessHub.Utility.Bag

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
    child_specs = Bag.gen_child_specs(10, "gen_test")

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
end
