defmodule Ark.Workflow.ClearFailure do
  @moduledoc false

  def clear(store, roots) do
    %{results: results, attempts: attempts} = store

    # Index all dependency failures from the state, regardless of what roots are
    # asked. Key is a dependency key, value is the [{dependent_key,
    # alternative}] list from transitive failures (failed because of that
    # dependedency).
    index =
      for {dependent, alts} <- attempts, {alt, {:dep_failed, dep}} <- alts, reduce: %{} do
        acc -> Map.update(acc, dep, [{dependent, alt}], &[{dependent, alt} | &1])
      end

    results = Map.drop(results, roots)
    # Drop all failures of all alternatives for the roots that were asked
    attempts = Map.drop(attempts, roots)

    {results, attempts} =
      clear_dependents(roots, index, results, attempts)

    %{store | results: results, attempts: attempts}
  end

  defp clear_dependents([cleared | queue], index, results, attempts) do
    {queue, results, attempts} =
      index
      |> Map.get(cleared, [])
      |> Enum.reduce({queue, results, attempts}, fn
        {dependent, alt}, {queue, results, attempts} ->
          # Delete the alt of "dependent" that failed because of our cleared failure
          attempts = maybe_delete_alt(attempts, dependent, alt)

          # if dependent was failed we remove its failure
          case results do
            %{^dependent => {:failed, _}} ->
              {[dependent | queue], Map.delete(results, dependent), attempts}

            _ ->
              {queue, results, attempts}
          end
      end)

    clear_dependents(queue, index, results, attempts)
  end

  defp clear_dependents([], _index, results, attempts) do
    {results, attempts}
  end

  # Relaxed: the alternative may already be gone when the dependent is itself a
  # root, as its attempts were dropped after the index was built. Drops the
  # dependent's entry when its last alternative is deleted.
  defp maybe_delete_alt(attempts, dependent, alt) do
    case attempts do
      %{^dependent => alts} when is_map_key(alts, alt) ->
        if map_size(alts) == 1 do
          Map.delete(attempts, dependent)
        else
          Map.put(attempts, dependent, Map.delete(alts, alt))
        end

      _ ->
        attempts
    end
  end
end
