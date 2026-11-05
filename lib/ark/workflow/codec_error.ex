defmodule Ark.Workflow.CodecError do
  defexception [:message, :key, :reason]

  @type t :: %__MODULE__{message: String.t(), key: tuple | nil, reason: term}
end
