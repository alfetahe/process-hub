defmodule Test.Utility.NameTest do
  alias ProcessHub.Utility.Name

  use ExUnit.Case

  test "initializer" do
    assert Name.initializer(:test) === :"hub.test.initializer"
  end

  test "event queue" do
    assert Name.event_queue(:test) === :"hub.test.event_queue"
  end

  test "distributed supervisor" do
    assert Name.distributed_supervisor(:test) ===
             {:via, Registry, {:"hub.test.system_registry", "dist_sup"}}
  end

  test "task supervisor" do
    assert Name.task_supervisor(:test) ===
             {:via, Registry, {:"hub.test.system_registry", "task_sup"}}
  end

  test "worker queue" do
    assert Name.worker_queue(:test) ===
             {:via, Registry, {:"hub.test.system_registry", "worker_queue"}}
  end

  test "hook registry" do
    assert Name.hook_registry(:test) === :"hub.test.hook_registry"
  end

  test "janitor" do
    assert Name.janitor(:test) === {:via, Registry, {:"hub.test.system_registry", "janitor"}}
  end
end
