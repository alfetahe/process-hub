defmodule Test.FutureTest do
  use ExUnit.Case, async: false

  alias ProcessHub.Future

  describe "await/1 with error tuple" do
    test "returns error unchanged" do
      assert Future.await({:error, :some_reason}) == {:error, :some_reason}
      assert Future.await({:error, :timeout}) == {:error, :timeout}
      assert Future.await({:error, "string reason"}) == {:error, "string reason"}
    end
  end

  describe "await/1 with invalid input" do
    test "returns error for non-future values" do
      assert Future.await(:invalid) == {:error, :invalid_argument}
      assert Future.await(nil) == {:error, :invalid_argument}
      assert Future.await(42) == {:error, :invalid_argument}
      assert Future.await("not a future") == {:error, :invalid_argument}
    end
  end

  describe "await/1 with {:ok, future} tuple" do
    test "delegates to await/1 with invalid resolver" do
      future = %Future{
        future_resolver: :not_valid,
        ref: make_ref(),
        timeout: 100
      }

      assert Future.await({:ok, future}) == {:error, :invalid_argument}
    end
  end

  describe "await/1 with Future struct" do
    test "returns error for invalid future_resolver" do
      future = %Future{
        future_resolver: :not_a_tuple,
        ref: make_ref(),
        timeout: 100
      }

      assert Future.await(future) == {:error, :invalid_argument}
    end

    test "returns error for nonexistent process" do
      future = %Future{
        future_resolver: {:nonexistent_hub_xyz, node()},
        ref: make_ref(),
        timeout: 100
      }

      assert Future.await(future) == {:error, :noproc}
    end
  end

  describe "await/1 with timeout" do
    test "returns timeout error when GenServer.call times out" do
      pid =
        spawn(fn ->
          receive do
            _ ->
              receive do
                :stop -> :ok
              end
          end
        end)

      Process.register(pid, :timeout_test_hub)

      future = %Future{
        future_resolver: {:timeout_test_hub, node()},
        ref: make_ref(),
        timeout: 0
      }

      assert Future.await(future) == {:error, :timeout}

      Process.exit(pid, :kill)
    end
  end

  describe "Future struct defaults" do
    test "action defaults to :start" do
      future = %Future{future_resolver: nil, ref: nil, timeout: nil}
      assert future.action == :start
    end
  end
end
