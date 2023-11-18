defmodule Test.Utility.NameTest do
  alias ProcessHub.Utility.Name

  use ExUnit.Case

  test "concat names" do
    assert Name.concat_name([:test, :test2, :test3], ".") === :"hub.test.test2.test3"
    assert Name.concat_name(["test", "test2", :test3], ".") === :"hub.test.test2.test3"
    assert Name.concat_name(["test", "test2", "test3"], ".") === :"hub.test.test2.test3"
  end

  test "initializer" do
    assert Name.initializer(:test) === :"hub.test.initializer"
  end

  test "local event queue" do
    assert Name.local_event_queue(:test) === :"hub.test.#{node()}.local_event_queue"
  end

  test "global event queue" do
    assert Name.global_event_queue(:test) === :"hub.test.global_event_queue"
  end

  test "coordinator" do
    assert Name.coordinator(:test) === :"hub.test.coordinator"
  end

  test "distributed supervisor" do
    assert Name.distributed_supervisor(:test) === :"hub.test.distributed_supervisor"
  end

  test "task supervisor" do
    assert Name.task_supervisor(:test) === :"hub.test.task_supervisor"
  end

  test "worker queue" do
    assert Name.worker_queue(:test) === :"hub.test.worker_queue"
  end

  test "registry name" do
    assert Name.registry(:test) === :"hub.test.process_registry"
  end
end
