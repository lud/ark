defmodule Ark.Workflow.ComputationError do
  alias Ark.Workflow.GraphError

  @enforce_keys [:target]
  defexception [:target]

  @impl true
  def message(e) do
    "target #{GraphError.format_key(e.target)} could not be computed"
  end
end
