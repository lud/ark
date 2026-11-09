defmodule Ark.Workflow.ComputationError do
  @moduledoc """
  Error returned by `Ark.Workflow.run/3` when a target could not be computed.

  The `:target` field holds the full `{namespace, name, params}` key of the
  first failed target. `Ark.Workflow.blame/2` returns the failure records
  leading to the root causes.
  """

  alias Ark.Workflow.GraphError

  @enforce_keys [:target]
  @type t :: %__MODULE__{target: Ark.Workflow.full_key()}

  defexception [:target]

  @impl true
  def message(e) do
    "target #{GraphError.format_key(e.target)} could not be computed"
  end
end
