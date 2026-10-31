defmodule Ark.Workflow.ComputationError do
  defexception [:message, :target]

  @type t :: %__MODULE__{message: String.t(), target: tuple}

  @doc false
  def new(target) do
    %__MODULE__{
      message: "could not compute #{Ark.Workflow.format_key(target)}",
      target: target
    }
  end
end
