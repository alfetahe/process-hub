defmodule ProcessHub.Request.PostAction do
  @moduledoc """
  Represents a post-action to be executed after children are started on the target node.

  Post-actions are attached to `StartChildrenRequest` and executed after children
  are successfully started. They use an MFA (module, function, args) pattern to
  allow any module to define post-action behavior.

  The callback function will be invoked as: `apply(m, f, [hub, results | a])`
  where `hub` is the Hub struct and `results` is the list of PostStartData structs.
  """

  @type t :: %__MODULE__{
          m: module(),
          f: atom(),
          a: list()
        }

  defstruct [:m, :f, a: []]

  @doc """
  Creates a new PostAction with the given module, function, and additional arguments.

  ## Parameters
    - `m` - The module containing the callback function
    - `f` - The function name to call
    - `a` - Additional arguments (hub and results will be prepended)

  ## Returns
    A new PostAction struct.
  """
  @spec new(module(), atom(), list()) :: t()
  def new(m, f, a \\ []) do
    %__MODULE__{m: m, f: f, a: a}
  end
end
