defmodule Ark.Test.WorkflowHelpers do
  alias Ark.Workflow

  def rule(deps, body) do
    %{alts: [default: %{deps: deps, body: body}]}
  end

  def const_rule(value) do
    rule([], ok_body(value))
  end

  def failing_rule(reason \\ :failed) do
    rule([], error_body(reason))
  end

  def ok_body(value) do
    fn _, _, _ -> {:ok, value} end
  end

  def error_body(reason \\ :failed) do
    fn _, _, _ -> {:error, reason} end
  end

  def deps_body do
    fn _, deps, _ -> {:ok, deps} end
  end

  def params_body do
    fn params, _, _ -> {:ok, params} end
  end

  def fetch!(wf, key) do
    case Workflow.fetch(wf, key) do
      {:ok, value} -> value
      other -> raise "expected #{inspect(key)} to have a value, got: #{inspect(other)}"
    end
  end

  def run!(wf, targets, opts \\ []) do
    case Workflow.run(wf, targets, opts) do
      {:ok, wf} -> wf
      {:error, e, _} -> raise "expected run to succeed, got: #{inspect(e)}"
    end
  end

  def roundtrip(wf, fresh) do
    {:ok, data} = Workflow.dump(wf)
    data = data |> JSON.encode!() |> JSON.decode!()
    {:ok, wf} = Workflow.load(fresh, data)
    wf
  end
end
