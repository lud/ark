defmodule Ark.Workflow.ComputationError do
  defexception [:target, :causes]

  @impl true
  def message(e) do
    inspect_target =
      case e.target do
        {:default, name, params} -> {name, params}
        target -> target
      end

    "todo error message: #{inspect(inspect_target)}"
  end
end
