defmodule Ark.Workflow.CodecError do
  defexception [:key, :reason]

  @impl true
  def message(_e) do
    "todo error message"
  end
end
