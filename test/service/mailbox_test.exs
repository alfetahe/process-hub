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

  test "receive response 2" do
    send(self(), {:child_start_resp, :child_id, {:ok, self()}, node()})

    handler = fn a, b, c ->
      {:handler_resp, a, b, c}
    end

    assert Mailbox.receive_response(:child_start_resp, handler, 100) ===
             {:child_id, {:handler_resp, :child_id, {:ok, self()}, node()}}
  end

  test "collect start", %{hub: hub} do
    assert Mailbox.collect_start_results(hub, timeout: 1) ===
             %ProcessHub.StartResult{
               status: :error,
               started: [],
               errors: [{:undefined, node(), :node_receive_timeout}],
               rollback: false
             }

    send(self(), {:collect_start_results, [{"child_id1", {:ok, :somepid}}], node()})
    send(self(), {:collect_start_results, [{"child_id2", {:ok, :somepid}}], :somenode})
    send(self(), {:collect_start_results, [{"child_id2", {:ok, :somepid}}], :no_collect})
    opts = [collect_from: [node(), :somenode], timeout: 1]

    assert Mailbox.collect_start_results(hub, opts) === %ProcessHub.StartResult{
             status: :ok,
             started: [
               {"child_id2", [somenode: :somepid]},
               {"child_id1", [{node(), :somepid}]}
             ],
             errors: [],
             rollback: false
           }

    opts = [{:receive_key, :custom_recv_key} | opts]
    send(self(), {:custom_recv_key, [{"child_id1", {:error, :someerror}}], node()})
    send(self(), {:custom_recv_key, [{"child_id2", {:ok, :somepid}}], :somenode})

    assert Mailbox.collect_start_results(hub, opts) === %ProcessHub.StartResult{
             status: :error,
             started: [{"child_id2", [no_collect: :somepid]}],
             errors: [{:undefined, node(), :node_receive_timeout}],
             rollback: false
           }

    handler = fn _cid, _node, result ->
      case result do
        {:ok, _pid} -> {:ok, :myok}
        {:error, err} -> {:error, err}
      end
    end

    opts = [
      {:required_cids, ["child_id1", "timeout_cid"]},
      {:result_handler, handler},
      {:timeout, 1}
    ]

    send(self(), {:collect_start_results, [{"child_id1", {:ok, :pid}}], node()})

    assert Mailbox.collect_start_results(hub, opts) ===
             %ProcessHub.StartResult{
               status: :error,
               started: [{"child_id1", [{node(), :myok}]}],
               errors: [{:undefined, node(), :node_receive_timeout}],
               rollback: false
             }
  end

  test "collect stop", %{hub: hub} do
    assert Mailbox.collect_stop_results(hub, timeout: 1) ===
             %ProcessHub.StopResult{
               status: :error,
               stopped: [],
               errors: [{:undefined, node(), :node_receive_timeout}]
             }

    send(self(), {:collect_stop_results, [{"child_id1", :ok}], node()})
    send(self(), {:collect_stop_results, [{"child_id2", :ok}], :somenode})
    send(self(), {:collect_stop_results, [{"child_id2", :ok}], :no_collect})
    opts = [collect_from: [node(), :somenode], timeout: 1]

    assert Mailbox.collect_stop_results(hub, opts) ===
             %ProcessHub.StopResult{
               status: :ok,
               stopped: [{"child_id2", [:somenode]}, {"child_id1", [node()]}],
               errors: []
             }

    opts = [{:receive_key, :custom_recv_key} | opts]
    send(self(), {:custom_recv_key, [{"child_id1", {:error, :someerror}}], node()})
    send(self(), {:custom_recv_key, [{"child_id2", :ok}], :somenode})

    assert Mailbox.collect_stop_results(hub, opts) === %ProcessHub.StopResult{
             errors: [{:undefined, node(), :node_receive_timeout}],
             status: :error,
             stopped: [{"child_id2", [:no_collect]}]
           }

    handler = fn _cid, _node, result ->
      case result do
        :custom_ok -> :ok
        :err -> :err
      end
    end

    opts = [
      {:required_cids, ["child_id1", "timeout_cid"]},
      {:result_handler, handler},
      {:timeout, 1}
    ]

    send(self(), {:collect_stop_results, [{"child_id1", :custom_ok}], node()})

    assert Mailbox.collect_stop_results(hub, opts) === %ProcessHub.StopResult{
             errors: [{:undefined, node(), :node_receive_timeout}],
             status: :error,
             stopped: [{"child_id1", [node()]}]
           }
  end

  test "receive child resp" do
    assert Mailbox.receive_child_resp(
             [{node(), ["child_id_1", :child_id_2]}],
             :child_start_resp,
             fn _, _, _ -> :ok end,
             :child_start_timeout,
             1
           ) === [
             {:child_id_2, [error: {node(), :child_start_timeout}]},
             {"child_id_1", [error: {node(), :child_start_timeout}]}
           ]

    assert Mailbox.receive_child_resp(
             [{node(), ["child_id_1", :child_id_2]}],
             :child_stop_resp,
             fn _, _, _ -> :ok end,
             :child_stop_timeout,
             1
           ) === [
             {:child_id_2, [error: {node(), :child_stop_timeout}]},
             {"child_id_1", [error: {node(), :child_stop_timeout}]}
           ]

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
