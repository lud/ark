defmodule Ark.Workflow.ClearFailure do
  @moduledoc false

  def clear(wf, keys) do
    wf =
      Enum.reduce(keys, wf, fn key, wf ->
        %{wf | failed: Map.delete(wf.failed, key), attempts: Map.delete(wf.attempts, key)}
      end)

    propagate(wf, keys)
  end

  defp propagate(wf, []) do
    wf
  end

  defp propagate(wf, [cleared | rest]) do
    {wf, newly} = clear_consumers(wf, cleared)
    propagate(wf, rest ++ newly)
  end

  defp clear_consumers(wf, cleared) do
    Enum.reduce(wf.attempts, {wf, []}, fn {key, attempts}, {wf, newly} ->
      kept = Map.reject(attempts, fn {_, record} -> record == {:dep_failed, cleared} end)

      if map_size(kept) == map_size(attempts) do
        {wf, newly}
      else
        wf = %{wf | attempts: put_attempts(wf.attempts, key, kept)}
        failed? = is_map_key(wf.failed, key)
        wf = %{wf | failed: Map.delete(wf.failed, key)}

        {wf, add_if(failed?, key, newly)}
      end
    end)
  end

  defp add_if(true, key, keys) do
    [key | keys]
  end

  defp add_if(false, _key, keys) do
    keys
  end

  defp put_attempts(attempts, key, kept) when map_size(kept) == 0 do
    Map.delete(attempts, key)
  end

  defp put_attempts(attempts, key, kept) do
    Map.put(attempts, key, kept)
  end
end
