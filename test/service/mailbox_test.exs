defmodule Test.Service.MailboxTest do
  alias ProcessHub.Service.Mailbox

  use ExUnit.Case

  setup do
    Test.Helper.SetupHelper.setup_base(%{}, :messenger_test)
  end

  test "receive response" do
    send(self(), {:child_start_resp, :child_id, {:ok, self()}, node()})

    handler = fn a, b, c ->
      {:handler_resp, a, b, c}
    end

    assert Mailbox.receive_response(:child_start_resp, :child_id, node(), handler, 100, :error) ===
             {:child_id, {:handler_resp, :child_id, {:ok, self()}, node()}}
  end

  test "receives start resp" do
    assert Mailbox.receive_start_resp([{node(), [:none]}], timeout: 1) ===
             {:error, [none: [error: {node(), :child_start_timeout}]]}

    send(self(), {:child_start_resp, :child_id, {:ok, self()}, node()})

    assert Mailbox.receive_start_resp([{node(), [:child_id]}], timeout: 1) ===
             {:ok, [child_id: [{node(), self()}]]}
  end

  test "receive stop resp" do
    assert Mailbox.receive_stop_resp([{:node, [:none]}], timeout: 1) ===
             {:error, [none: [error: {:node, :child_stop_timeout}]]}

    send(self(), {:child_stop_resp, :child_id, :ok, node()})

    assert Mailbox.receive_stop_resp([{node(), [:child_id]}], timeout: 1) ===
             {:ok, [child_id: [node()]]}
  end

  test "receive child resp" do
    assert Mailbox.receive_child_resp(
             [{node(), [:child_id]}],
             :child_start_resp,
             fn _, _, _ -> :ok end,
             :child_start_timeout,
             1
           ) === [child_id: [error: {node(), :child_start_timeout}]]

    assert Mailbox.receive_child_resp(
             [{node(), [:child_id]}],
             :child_stop_resp,
             fn _, _, _ -> :ok end,
             :child_stop_timeout,
             1
           ) === [child_id: [error: {node(), :child_stop_timeout}]]

    send(self(), {:child_start_resp, :child_id, {:ok, self()}, node()})
    send(self(), {:child_stop_resp, :child_id, :ok, node()})

    assert Mailbox.receive_child_resp(
             [{node(), [:child_id]}],
             :child_start_resp,
             fn child_id, resp, node ->
               {:handler_response, child_id, resp, node}
             end,
             :child_start_resp,
             1
           ) === [child_id: [{:handler_response, :child_id, {:ok, self()}, node()}]]

    assert Mailbox.receive_child_resp(
             [{node(), [:child_id]}],
             :child_stop_resp,
             fn _child_id, resp, node ->
               {node, resp}
             end,
             :child_stop_timeout,
             1
           ) === [child_id: [{node(), :ok}]]
  end
end
