defmodule Test.Service.LoggerServiceTest do
  alias ProcessHub.Service.LoggerService

  use ExUnit.Case

  import ExUnit.CaptureLog

  describe "format_message/3" do
    test "formats message with default prefix" do
      result = LoggerService.format_message("Hello World", %{}, [])

      assert result =~ "[ProcessHub] Hello World"
      assert result =~ "| node:"
    end

    test "formats message with custom prefix" do
      result = LoggerService.format_message("Test message", %{}, prefix: "Coordinator")

      assert result =~ "[ProcessHub][Coordinator] Test message"
      assert result =~ "| node:"
    end

    test "replaces placeholders in message" do
      result = LoggerService.format_message("User @name logged in", %{"name" => "Alice"}, [])

      assert result =~ "[ProcessHub] User Alice logged in"
    end

    test "replaces multiple placeholders" do
      result =
        LoggerService.format_message(
          "Child @child_id started on @node",
          %{"child_id" => "my_child", "node" => "node1"},
          []
        )

      assert result =~ "Child my_child started on node1"
    end

    test "inspects non-string values" do
      result = LoggerService.format_message("Count: @count", %{"count" => 42}, [])

      assert result =~ "Count: 42"
    end

    test "inspects atoms" do
      result = LoggerService.format_message("Status: @status", %{"status" => :ok}, [])

      assert result =~ "Status: :ok"
    end

    test "inspects tuples" do
      result = LoggerService.format_message("Error: @error", %{"error" => {:error, :timeout}}, [])

      assert result =~ "Error: {:error, :timeout}"
    end

    test "inspects lists" do
      result = LoggerService.format_message("Nodes: @nodes", %{"nodes" => [:a, :b]}, [])

      assert result =~ "Nodes: [:a, :b]"
    end

    test "includes node metadata" do
      result = LoggerService.format_message("Test", %{}, [])
      current_node = node()

      assert result =~ "| node: #{inspect(current_node)}"
    end

    test "combines prefix, placeholders, and metadata" do
      result =
        LoggerService.format_message(
          "Processing @item",
          %{"item" => "task_123"},
          prefix: "Worker"
        )

      assert result =~ "[ProcessHub][Worker]"
      assert result =~ "Processing task_123"
      assert result =~ "| node:"
    end
  end

  describe "replace_placeholders/2" do
    test "returns message unchanged when replacements is empty" do
      result = LoggerService.replace_placeholders("Hello @name", %{})

      assert result == "Hello @name"
    end

    test "replaces single placeholder" do
      result = LoggerService.replace_placeholders("Hello @name", %{"name" => "World"})

      assert result == "Hello World"
    end

    test "replaces multiple placeholders" do
      result =
        LoggerService.replace_placeholders(
          "@greeting @name!",
          %{"greeting" => "Hello", "name" => "World"}
        )

      assert result == "Hello World!"
    end

    test "handles placeholder not in message" do
      result = LoggerService.replace_placeholders("Hello World", %{"name" => "Test"})

      assert result == "Hello World"
    end

    test "keeps string values as-is" do
      result = LoggerService.replace_placeholders("Value: @val", %{"val" => "test_string"})

      assert result == "Value: test_string"
    end

    test "inspects integer values" do
      result = LoggerService.replace_placeholders("Count: @num", %{"num" => 100})

      assert result == "Count: 100"
    end

    test "inspects atom values" do
      result = LoggerService.replace_placeholders("Node: @node", %{"node" => :foo@bar})

      assert result == "Node: :foo@bar"
    end

    test "inspects pid values" do
      pid = self()
      result = LoggerService.replace_placeholders("Pid: @pid", %{"pid" => pid})

      assert result == "Pid: #{inspect(pid)}"
    end
  end

  describe "logging functions" do
    # Note: These tests use warning/error level since the test environment
    # log level may be set higher than debug/info. The format_message tests
    # above thoroughly verify the formatting logic for all cases.

    test "warning/3 logs with correct format" do
      log =
        capture_log(fn ->
          LoggerService.warning("Warning message")
        end)

      assert log =~ "[warning]"
      assert log =~ "[ProcessHub] Warning message"
      assert log =~ "| node:"
    end

    test "error/3 logs with correct format" do
      log =
        capture_log(fn ->
          LoggerService.error("Error message")
        end)

      assert log =~ "[error]"
      assert log =~ "[ProcessHub] Error message"
      assert log =~ "| node:"
    end

    test "logging with placeholders" do
      log =
        capture_log(fn ->
          LoggerService.error("User @user failed", %{"user" => "admin"})
        end)

      assert log =~ "User admin failed"
    end

    test "logging with prefix" do
      log =
        capture_log(fn ->
          LoggerService.warning("Timeout", %{}, prefix: "Connection")
        end)

      assert log =~ "[ProcessHub][Connection] Timeout"
    end

    test "logging includes node metadata" do
      log =
        capture_log(fn ->
          LoggerService.error("Test error")
        end)

      current_node = node()
      assert log =~ "| node: #{inspect(current_node)}"
    end

    test "all logging functions return :ok" do
      # Capture to suppress output, but verify return values
      capture_log(fn ->
        assert LoggerService.debug("test") == :ok
        assert LoggerService.info("test") == :ok
        assert LoggerService.notice("test") == :ok
        assert LoggerService.warning("test") == :ok
        assert LoggerService.error("test") == :ok
      end)
    end
  end
end
