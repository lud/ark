defmodule Ark.Workflow.Middleware do
  def innermost(_call) do
    raise "todo"
  end

  def update_args(_call, _fun) do
    raise "todo"
  end

  def log(_kind, _meta, _call) do
    raise "todo"
  end

  def telemetry(_kind, _meta, _call) do
    raise "todo"
  end
end
