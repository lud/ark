defmodule Ark.Workflow.ComputationError do
  defexception [:message, :target, :causes]

  @type cause :: %{key: tuple, alternative: atom | binary, error: map}
  @type t :: %__MODULE__{message: String.t(), target: tuple, causes: [cause]}

  @doc false
  def new(target, causes, tree) do
    %__MODULE__{
      message: "could not compute #{Ark.Workflow.format_key(target)}:\n" <> tree,
      target: target,
      causes: causes
    }
  end
end
