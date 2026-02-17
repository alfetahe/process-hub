defmodule ProcessHub.Service.LoggerService do
  @moduledoc """
  Logging service for ProcessHub with Drupal-style placeholder-based formatting.

  Provides simple functions (no macros) for logging with automatic `[ProcessHub]` prefix
  and optional custom prefix support. Each log message includes metadata (current node)
  appended at the end.

  ## Placeholder Syntax

  Uses `@key` placeholders that are replaced with values from the replacements map:

      LoggerService.error("Child @child_id failed", %{
        "child_id" => "my_child"
      })
      # => "[ProcessHub] Child my_child failed | node: :foo@bar"

  ## Custom Prefix

  Add a custom prefix after `[ProcessHub]` using the `:prefix` option:

      LoggerService.warning("Timeout occurred", %{}, prefix: "Coordinator")
      # => "[ProcessHub][Coordinator] Timeout occurred | node: :foo@bar"

  ## Available Functions

  - `debug/3` - Debug level
  - `info/3` - Info level
  - `notice/3` - Notice level
  - `warning/3` - Warning level
  - `error/3` - Error level

  All functions have the signature: `level(message, replacements \\\\ %{}, opts \\\\ [])`
  """

  require Logger

  @doc """
  Logs a debug message with optional placeholders and prefix.

  ## Parameters
    - `message` - The log message with optional `@key` placeholders
    - `replacements` - Map of placeholder keys to values (default: `%{}`)
    - `opts` - Keyword list of options (default: `[]`)
      - `:prefix` - Optional string to add after `[ProcessHub]`

  ## Examples

      LoggerService.debug("Processing @item", %{"item" => "foo"})
      LoggerService.debug("Starting up", %{}, prefix: "Worker")
  """
  @spec debug(String.t(), map(), keyword()) :: :ok
  def debug(message, replacements \\ %{}, opts \\ []) do
    Logger.debug(format_message(message, replacements, opts))
  end

  @doc """
  Logs an info message with optional placeholders and prefix.

  ## Parameters
    - `message` - The log message with optional `@key` placeholders
    - `replacements` - Map of placeholder keys to values (default: `%{}`)
    - `opts` - Keyword list of options (default: `[]`)
      - `:prefix` - Optional string to add after `[ProcessHub]`

  ## Examples

      LoggerService.info("System started")
      LoggerService.info("Connected to @host", %{"host" => "localhost"})
  """
  @spec info(String.t(), map(), keyword()) :: :ok
  def info(message, replacements \\ %{}, opts \\ []) do
    Logger.info(format_message(message, replacements, opts))
  end

  @doc """
  Logs a notice message with optional placeholders and prefix.

  ## Parameters
    - `message` - The log message with optional `@key` placeholders
    - `replacements` - Map of placeholder keys to values (default: `%{}`)
    - `opts` - Keyword list of options (default: `[]`)
      - `:prefix` - Optional string to add after `[ProcessHub]`

  ## Examples

      LoggerService.notice("Cache cleared")
      LoggerService.notice("User @user logged in", %{"user" => "admin"})
  """
  @spec notice(String.t(), map(), keyword()) :: :ok
  def notice(message, replacements \\ %{}, opts \\ []) do
    Logger.notice(format_message(message, replacements, opts))
  end

  @doc """
  Logs a warning message with optional placeholders and prefix.

  ## Parameters
    - `message` - The log message with optional `@key` placeholders
    - `replacements` - Map of placeholder keys to values (default: `%{}`)
    - `opts` - Keyword list of options (default: `[]`)
      - `:prefix` - Optional string to add after `[ProcessHub]`

  ## Examples

      LoggerService.warning("Connection timeout")
      LoggerService.warning("Retrying @count times", %{"count" => 3}, prefix: "Client")
  """
  @spec warning(String.t(), map(), keyword()) :: :ok
  def warning(message, replacements \\ %{}, opts \\ []) do
    Logger.warning(format_message(message, replacements, opts))
  end

  @doc """
  Logs an error message with optional placeholders and prefix.

  ## Parameters
    - `message` - The log message with optional `@key` placeholders
    - `replacements` - Map of placeholder keys to values (default: `%{}`)
    - `opts` - Keyword list of options (default: `[]`)
      - `:prefix` - Optional string to add after `[ProcessHub]`

  ## Examples

      LoggerService.error("Failed to connect")
      LoggerService.error("Process @pid crashed", %{"pid" => self()}, prefix: "Supervisor")
  """
  @spec error(String.t(), map(), keyword()) :: :ok
  def error(message, replacements \\ %{}, opts \\ []) do
    Logger.error(format_message(message, replacements, opts))
  end

  @doc """
  Formats a message with prefix, placeholder replacement, and metadata.

  ## Parameters
    - `message` - The log message with optional `@key` placeholders
    - `replacements` - Map of placeholder keys to values
    - `opts` - Keyword list of options
      - `:prefix` - Optional string to add after `[ProcessHub]`

  ## Examples

      iex> LoggerService.format_message("Hello @name", %{"name" => "World"}, [])
      "[ProcessHub] Hello World | node: :nonode@nohost"

      iex> LoggerService.format_message("Test", %{}, prefix: "Module")
      "[ProcessHub][Module] Test | node: :nonode@nohost"
  """
  @spec format_message(String.t(), map(), keyword()) :: String.t()
  def format_message(message, replacements, opts) do
    prefix = build_prefix(opts)
    replaced_message = replace_placeholders(message, replacements)
    metadata = build_metadata()
    "#{prefix} #{replaced_message} | #{metadata}"
  end

  @doc """
  Replaces `@key` placeholders in a message with values from the replacements map.

  Values are converted to strings using `inspect/1` for non-string values.

  ## Parameters
    - `message` - The message string with `@key` placeholders
    - `replacements` - Map of string keys to replacement values

  ## Examples

      iex> LoggerService.replace_placeholders("Hello @name", %{"name" => "World"})
      "Hello World"

      iex> LoggerService.replace_placeholders("Node @node", %{"node" => :foo@bar})
      "Node :foo@bar"
  """
  @spec replace_placeholders(String.t(), map()) :: String.t()
  def replace_placeholders(message, replacements) when map_size(replacements) == 0 do
    message
  end

  def replace_placeholders(message, replacements) do
    Enum.reduce(replacements, message, fn {key, value}, acc ->
      placeholder = "@#{key}"
      replacement = format_value(value)
      String.replace(acc, placeholder, replacement)
    end)
  end

  # Builds the prefix string based on options.
  @spec build_prefix(keyword()) :: String.t()
  defp build_prefix(opts) do
    case Keyword.get(opts, :prefix) do
      nil -> "[ProcessHub]"
      prefix -> "[ProcessHub][#{prefix}]"
    end
  end

  # Formats a value for placeholder replacement.
  @spec format_value(term()) :: String.t()
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)

  # Builds the metadata string appended to each log message.
  @spec build_metadata() :: String.t()
  defp build_metadata do
    "node: #{inspect(node())}"
  end
end
