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

  test "event queue" do
    assert Name.event_queue(:test) === :"hub.test.event_queue"
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

  test "hook registry" do
    assert Name.hook_registry(:test) === :"hub.test.hook_registry"
  end
end
