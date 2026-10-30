defmodule Ark.Workflow.ComputationError do
  defexception [:target, :causes]

  @impl true
  def message(_e) do
    "todo error message"
  end
end
