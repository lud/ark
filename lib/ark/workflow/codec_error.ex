defmodule Ark.Workflow.CodecError do
  defexception [:message, :key]

  @type t :: %__MODULE__{message: String.t(), key: tuple | nil}
end
