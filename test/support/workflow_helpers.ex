defmodule Ark.Test.WorkflowHelpers do
  alias Ark.Workflow
  alias Ark.Workflow.ComputationError

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

  def shadowing_exposures({:shadowing, exposure_a, exposure_b}) do
    MapSet.new([exposure_a, exposure_b])
  end

  def without_reasons(%{at: _, kind: _, message: _, reason: _} = cleaned) do
    %{cleaned | reason: nil}
  end

  def without_reasons(%ComputationError{causes: causes} = e) do
    %{e | causes: without_reasons(causes)}
  end

  def without_reasons(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, without_reasons(v)} end)
  end

  def without_reasons(list) when is_list(list) do
    Enum.map(list, &without_reasons/1)
  end

  def without_reasons(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> without_reasons() |> List.to_tuple()
  end

  def without_reasons(term) do
    term
  end

  def roundtrip(wf, fresh) do
    {:ok, data} = Workflow.dump(wf)
    data = data |> JSON.encode!() |> JSON.decode!()
    {:ok, wf} = Workflow.load(fresh, data)
    wf
  end
end
