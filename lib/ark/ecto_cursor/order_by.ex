if Code.ensure_loaded?(Ecto.Query) do
  defmodule Ark.EctoCursor.OrderBy do
    @moduledoc """
    An `Ecto.Type` for the sort order of an `Ark.EctoCursor`.

    In Elixir, the sort order is a non-empty list of `{direction, field}`
    tuples such as `[asc: :inserted_at, asc: :id]`. It is stored as a list of
    string pairs such as `[["asc", "inserted_at"], ["asc", "id"]]`.

    Casting accepts both forms, along with the shorthand syntax of the
    `:order_by` option of `Ark.EctoCursor.new/1`. Loading a stored sort order
    converts field names with `String.to_existing_atom/1`.
    """
    use Ecto.Type

    @type t :: [{:asc | :desc, atom}, ...]

    defguardp is_field(field)
              when is_atom(field) and not is_nil(field) and not is_boolean(field)

    @impl true
    def type do
      {:array, {:array, :string}}
    end

    @impl true
    def embed_as(_) do
      :dump
    end

    @impl true
    def cast(order_by) do
      {:ok, cast!(order_by)}
    rescue
      ArgumentError -> load(order_by)
    end

    @doc """
    Normalizes a sort order to a list of `{direction, field}` tuples.

    Field names without a direction sort in ascending order.

        iex> Ark.EctoCursor.OrderBy.cast!([:score, desc: :id])
        [asc: :score, desc: :id]

    A single field name is a shorthand for a list of one field.

        iex> Ark.EctoCursor.OrderBy.cast!(:id)
        [asc: :id]

    Accepts a field name, or a non-empty list of field names and
    `{direction, field}` tuples where the direction is `:asc` or `:desc`. Raises
    an `ArgumentError` for any other value and for duplicate fields.
    """
    def cast!([_ | _] = order_by) do
      cast!(order_by, [])
    end

    def cast!(field) when is_field(field) do
      cast!([field])
    end

    def cast!(other) do
      raise ArgumentError,
            "expected :order_by to be a field name or a non-empty list of fields, " <>
              "got: #{inspect(other)}"
    end

    defp cast!([{dir, field} | t], acc) when dir in [:asc, :desc] and is_field(field) do
      cast!(t, add_field!(acc, dir, field))
    end

    defp cast!([field | t], acc) when is_field(field) do
      cast!(t, add_field!(acc, :asc, field))
    end

    defp cast!([], acc) do
      :lists.reverse(acc)
    end

    defp cast!([invalid | _], _) do
      invalid_element!(invalid)
    end

    defp cast!(improper_tail, _) do
      invalid_element!(improper_tail)
    end

    defp add_field!(acc, dir, field) do
      if List.keymember?(acc, field, 1) do
        raise ArgumentError, "duplicate order_by field: #{inspect(field)}"
      end

      [{dir, field} | acc]
    end

    @spec invalid_element!(term) :: no_return
    defp invalid_element!(element) do
      raise ArgumentError, "invalid order_by element: #{inspect(element)}"
    end

    @impl true
    def load([_ | _] = raw) do
      {:ok, do_load(raw, [])}
    rescue
      ArgumentError -> :error
    end

    def load(_) do
      :error
    end

    defp do_load([h | t], acc) do
      {dir, field} = load_pair(h)
      do_load(t, add_field!(acc, dir, field))
    end

    defp do_load([], acc) do
      :lists.reverse(acc)
    end

    defp load_pair(["asc", bin_field]) when is_binary(bin_field) do
      {:asc, String.to_existing_atom(bin_field)}
    end

    defp load_pair(["desc", bin_field]) when is_binary(bin_field) do
      {:desc, String.to_existing_atom(bin_field)}
    end

    defp load_pair(other) do
      raise ArgumentError, "invalid stored order_by column #{inspect(other)}"
    end

    @impl true
    def dump([_ | _] = list) do
      {:ok, do_dump(list)}
    end

    def dump(_) do
      :error
    end

    defp do_dump([{k, v} | t]) do
      [[Atom.to_string(k), Atom.to_string(v)] | do_dump(t)]
    end

    defp do_dump([]) do
      []
    end
  end
end
