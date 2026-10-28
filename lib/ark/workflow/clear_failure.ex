defmodule Ark.Workflow.ClearFailure do
  @moduledoc false

  alias Ark.Workflow.Codec

  def clear(wf, keys) do
    wf =
      Enum.reduce(keys, wf, fn key, wf ->
        %{wf | failed: Map.delete(wf.failed, key), attempts: Map.delete(wf.attempts, key)}
      end)

    propagate(wf, Enum.map(keys, &id/1), %{})
  end

  defp propagate(wf, [], _seen) do
    wf
  end

  defp propagate(wf, [id | rest], seen) when is_map_key(seen, id) do
    propagate(wf, rest, seen)
  end

  defp propagate(wf, [id | rest], seen) do
    {wf, live} = clear_live(wf, id)
    {wf, orphans} = clear_orphans(wf, id)
    propagate(wf, rest ++ live ++ orphans, Map.put(seen, id, true))
  end

  defp clear_live(wf, id) do
    Enum.reduce(wf.attempts, {wf, []}, fn {key, attempts}, {wf, newly} ->
      kept = Map.reject(attempts, fn {_, record} -> depends_on?(record, id) end)

      if map_size(kept) == map_size(attempts) do
        {wf, newly}
      else
        wf = %{wf | attempts: put_attempts(wf.attempts, key, kept)}
        failed? = is_map_key(wf.failed, key)
        wf = %{wf | failed: Map.delete(wf.failed, key)}

        {wf, add_if(failed?, id(key), newly)}
      end
    end)
  end

  defp add_if(true, id, ids) do
    [id | ids]
  end

  defp add_if(false, _id, ids) do
    ids
  end

  defp put_attempts(attempts, key, kept) when map_size(kept) == 0 do
    Map.delete(attempts, key)
  end

  defp put_attempts(attempts, key, kept) do
    Map.put(attempts, key, kept)
  end

  defp clear_orphans(wf, id) do
    {orphans, newly} =
      Enum.reduce(wf.orphans, {wf.orphans, []}, fn {oid, entry}, {orphans, newly} ->
        list = Map.get(entry, "attempts", [])
        kept = Enum.reject(list, &orphan_depends_on?(&1, id))

        if length(kept) == length(list) do
          {orphans, newly}
        else
          entry = entry |> put_orphan_attempts(kept) |> Map.delete("failure")
          failed? = is_map_key(Map.fetch!(orphans, oid), "failure")

          {Map.put(orphans, oid, entry), add_if(failed?, oid, newly)}
        end
      end)

    {%{wf | orphans: orphans}, newly}
  end

  defp put_orphan_attempts(entry, []) do
    Map.delete(entry, "attempts")
  end

  defp put_orphan_attempts(entry, kept) do
    Map.put(entry, "attempts", kept)
  end

  defp depends_on?({:dep_failed, key}, id) do
    id(key) == id
  end

  defp depends_on?(_, _) do
    false
  end

  defp orphan_depends_on?(
         %{
           "record" => %{
             "t" => "dep_failed",
             "key" => %{"ns" => ns, "name" => name, "params" => params}
           }
         },
         id
       ) do
    {ns, name, params} == id
  end

  defp orphan_depends_on?(_, _) do
    false
  end

  defp id({ns, name, params}) do
    {to_string(ns), to_string(name), Codec.encode(params)}
  end
end
