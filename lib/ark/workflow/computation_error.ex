defmodule Ark.Workflow.ComputationError do
  defexception [:target, :causes]

  @impl true
  def message(e) do
    "todo error message: #{inspect(e.target)} "
  end
end
