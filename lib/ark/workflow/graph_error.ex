defmodule Ark.Workflow.GraphError do
  defexception [:kind, :message, :key, :alternative, :value, :stack]

  @type t :: %__MODULE__{
          kind: atom,
          message: String.t(),
          key: term,
          alternative: atom | nil,
          value: term,
          stack: [term] | nil
        }
end
