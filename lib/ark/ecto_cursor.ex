if Code.ensure_loaded?(Ecto.Query) do
  defmodule Ark.EctoCursor do
    @moduledoc """
    Keyset pagination for Ecto queries.

    A cursor holds a sort order and the position of the last row read. Each page
    is fetched with a `WHERE` clause that continues right after that position,
    so pages stay consistent when rows are inserted or deleted between calls.
    With an index matching the sort order, the database seeks to the position in
    the index, so deep pages stay fast.

    Create a cursor with a sort order and a page size, then fetch pages with a
    base query and a repo. Each page carries the cursor for the next one.

        cursor = Ark.EctoCursor.new(order_by: [desc: :inserted_at, asc: :id], page_size: 20)

        %Ark.EctoCursor.Page{entries: posts, next_cursor: next} =
          Ark.EctoCursor.fetch_page(cursor, MyApp.Post, MyApp.Repo)

        %Ark.EctoCursor.Page{entries: more_posts} =
          Ark.EctoCursor.fetch_page(next, MyApp.Post, MyApp.Repo)

    The `:has_next_page` field of `Ark.EctoCursor.Page` tells whether more rows
    follow the page.

    To go through every row, `stream/4` fetches the pages lazily as the stream
    is consumed.

        Ark.EctoCursor.new(order_by: :id, page_size: 500)
        |> Ark.EctoCursor.stream(MyApp.Post, MyApp.Repo)
        |> Enum.each(&MyApp.Search.index_post/1)

    ### Sort order

    The `:order_by` option lists the fields that define the order of the rows. A
    plain field name sorts in ascending order, and `{:asc, field}` or `{:desc,
    field}` give an explicit direction, as in `Ecto.Query.order_by/3`.

    Choose the sort fields with these rules in mind:

    * Together, the fields must identify a single row. End the list with a
      unique field, usually the primary key, to break ties between rows that
      share the other values. For instance `[desc: :inserted_at, asc: :id]`.
    * The fields must be non-nullable columns. Rows with a `NULL` sort value can
      be skipped from the pages, and a row with a `nil` sort value raises an
      `ArgumentError` when it becomes the position of the next cursor.
    * An index on the same fields, in the same order and directions (or with all
      directions reversed), lets the database read each page directly from the
      index. For the example above, that is `create index(:posts, ["inserted_at
      DESC", :id])` in a migration.

    With several sort fields, the query also bounds the first field with a
    redundant `>=` (or `<=`) condition, which lets query planners seek the index
    from the position. The `:use_index` option of `fetch_page/4`, `stream/4` and
    `query/3` controls this behaviour.

    ### Base queries

    The base query can be any `Ecto.Queryable`: a schema, a `{source, schema}`
    tuple, or a query with `where`, `join`, `select` and `distinct: true`
    clauses. The cursor adds the `order_by`, the `limit`, and the conditions on
    the position, which shapes the base query:

    * The base query leaves out `limit`, `offset` and `order_by`. The limit
      comes from the `:page_size` option, and the order from the cursor.
    * Combinations such as `Ecto.Query.union/2` go inside a subquery: `from(s in
      subquery(union_all(q1, ^q2)))`.
    * `distinct` uses `true` rather than a list of expressions.

    Each row returned by the query must be a map or a struct that holds every
    sort field, under an atom or string key. Rows selected as schema structs or
    with `Ecto.Query.API.map/2` meet this naturally. With a custom `select`,
    include the sort fields in the selected map.

    By default, sort fields are read from the root source of the query. To sort
    on a joined source, give the cursor a `:binding` naming a binding of the
    query, defined with the `:as` option. A joined binding needs an explicit
    `select` that returns the sort fields of that binding, under their field
    names. This example lists the members of a group, sorted by user name.

        query =
          from m in MyApp.Membership,
            where: m.group_id == ^group_id,
            join: u in assoc(m, :user),
            as: :user,
            select: %{id: u.id, name: u.name, role: m.role}

        cursor = Ark.EctoCursor.new(order_by: [:name, :id], page_size: 20, binding: :user)

    ### Persisting cursors

    A cursor is an embedded schema, so it can be stored in a column of a parent
    schema with `Ecto.Schema.embeds_one/3`. This is useful to resume a long
    running job, or to keep polling a table for new rows. The cursor of the last
    page still points after the last row, so with a sort order that follows
    insertion, such as `:id` or `:inserted_at`, later calls return the rows
    inserted since then. Concurrent transactions can commit rows out of that
    order though, and a row committed after a later row was read is skipped.

        defmodule MyApp.Export do
          use Ecto.Schema

          schema "exports" do
            embeds_one :cursor, Ark.EctoCursor, on_replace: :delete
          end
        end

    The database column holds a map, declared with `add :cursor, :map` in the
    migration that creates the parent table.

    Only the sort order and the position are stored, so `resume!/2` turns a
    stored cursor back into a working one, with the page size and binding given
    again. It also accepts `nil`, which starts a new cursor for a parent that
    has none yet.

        @cursor_opts [order_by: [asc: :inserted_at, asc: :id], page_size: 500]

        def export_next_batch(%MyApp.Export{cursor: stored} = export) do
          cursor = Ark.EctoCursor.resume!(stored, @cursor_opts)

          %Ark.EctoCursor.Page{entries: posts, next_cursor: next} =
            Ark.EctoCursor.fetch_page(cursor, MyApp.Post, MyApp.Repo)

          :ok = MyApp.Storage.write_posts(posts)

          export
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.put_embed(:cursor, next)
          |> MyApp.Repo.update!()
        end

    Stored as JSON, position values take their JSON form, a datetime becomes a
    string for instance. Ecto casts them back to the type of the sort fields
    when building the query, using the schema of the queried source. Use a base
    query with a schema, such as `MyApp.Post` or `{"posts", MyApp.Post}`, with
    cursors loaded from storage.

    `Ecto.embedded_dump/2` and `Ecto.embedded_load/3` convert a cursor to and
    from JSON data for storage outside of a schema.
    """

    use Ecto.Schema
    import Ecto.Query

    @doc false
    def __ark__(:doc) do
      """
      This module provides keyset pagination for Ecto queries, with cursors that
      can be stored in an embedded schema.

      ```elixir
      cursor = Ark.EctoCursor.new(order_by: [desc: :inserted_at, asc: :id], page_size: 20)

      %Ark.EctoCursor.Page{entries: posts, next_cursor: next} =
        Ark.EctoCursor.fetch_page(cursor, MyApp.Post, MyApp.Repo)
      ```
      """
    end

    @primary_key false
    embedded_schema do
      field :order_by, Ark.EctoCursor.OrderBy
      field :position, {:array, :any}
      field :page_size, :integer, virtual: true
      field :binding, :any, virtual: true
    end

    @type t :: %__MODULE__{
            order_by: Ark.EctoCursor.OrderBy.t(),
            position: [term] | nil,
            page_size: pos_integer | nil,
            binding: atom | nil
          }

    @new_opts_keys [:order_by, :page_size, :binding]
    @type new_opts :: [
            order_by: atom | [atom | {:asc | :desc, atom}],
            page_size: pos_integer | nil,
            binding: atom | nil
          ]

    @query_opts_keys [:page_size, :use_index]
    @type query_opts :: [page_size: pos_integer, use_index: boolean]

    @type executor :: module | (Ecto.Query.t() -> [map])

    @doc """
    Returns a new cursor positioned before the first row.

    The sort order is normalized to a list of `{direction, field}` tuples.

        iex> Ark.EctoCursor.new(order_by: [:score, desc: :id], page_size: 10)
        %Ark.EctoCursor{order_by: [asc: :score, desc: :id], position: nil, page_size: 10, binding: nil}

    See the "Sort order" section of the module documentation to choose the sort
    fields.

    ### Options

    * `:order_by` - Required. A field name, or a list of field names and
      `{direction, field}` tuples where the direction is `:asc` or `:desc`.
      Field names without a direction sort in ascending order.
    * `:page_size` - A positive integer, the number of rows per page. This
      option can also be given to `query/3`, `fetch_page/4` and `stream/4`.
    * `:binding` - The named binding of the query that holds the sort fields.
      Defaults to the root source of the query.

    Raises an `ArgumentError` for invalid or unknown options.
    """
    @spec new(new_opts) :: t
    def new(opts) do
      opts = Keyword.validate!(opts, @new_opts_keys)

      %__MODULE__{
        order_by: order_by_opt!(opts),
        page_size: page_size_opt!(opts),
        binding: binding_opt!(opts)
      }
    end

    @doc """
    Prepares a stored cursor for a new page, or creates a new cursor from `nil`.

        {:ok, cursor} = Ark.EctoCursor.resume(stored_cursor, order_by: :id, page_size: 100)

    The options are the same as for `new/1`. The `:order_by` option must match
    the sort order of the stored cursor, and the returned cursor keeps the
    stored position. The `:page_size` and `:binding` of the returned cursor come
    from the options, and default to `nil` when they are not given.

    Returns `{:error, %Ark.EctoCursor.MismatchError{}}` when the sort orders
    differ, for instance after a change of the sort fields in the code that
    stored the cursor. Raises an `ArgumentError` for invalid or unknown options.
    """
    @spec resume(t | nil, new_opts) ::
            {:ok, t} | {:error, Ark.EctoCursor.MismatchError.t()}
    def resume(cursor_or_nil, opts) do
      opts = Keyword.validate!(opts, @new_opts_keys)
      {:ok, resume!(cursor_or_nil, opts)}
    rescue
      e in Ark.EctoCursor.MismatchError -> {:error, e}
    end

    @doc """
    Same as `resume/2`, but returns the cursor directly and raises an
    `Ark.EctoCursor.MismatchError` when the sort orders differ.

        cursor = Ark.EctoCursor.resume!(stored_cursor, order_by: :id, page_size: 100)
    """
    @spec resume!(t | nil, new_opts) :: t
    def resume!(nil, opts) do
      new(opts)
    end

    def resume!(%__MODULE__{} = cursor, opts) do
      %{order_by: expected_order_by, page_size: new_page_size, binding: new_binding} =
        new(opts)

      %{order_by: order_by} = cursor

      if order_by != expected_order_by do
        raise Ark.EctoCursor.MismatchError, stored: order_by, expected: expected_order_by
      end

      %{cursor | page_size: new_page_size, binding: new_binding}
    end

    @doc """
    Returns the query for the page that follows the cursor position, without
    running it.

    The returned query adds the sort order, a limit of one page, and the
    conditions on the cursor position to the base query. It is useful to inspect
    the generated SQL or the query plan.

        query = Ark.EctoCursor.query(cursor, MyApp.Post)
        Ecto.Adapters.SQL.explain(MyApp.Repo, :all, query)

    To read pages, use `fetch_page/4`, which also computes the next cursor.

    ### Options

    * `:page_size` - A positive integer that overrides the page size of the
      cursor. Required when the cursor has no page size.
    * `:use_index` - A boolean. When `true`, and the cursor has a position and
      several sort fields, the query bounds the first sort field with a
      redundant `>=` or `<=` condition so the database can seek an index on the
      sort fields. Defaults to `true`.

    Raises an `ArgumentError` for invalid options or when the base query does
    not fit the cursor, see the "Base queries" section of the module
    documentation.
    """
    @spec query(t, Ecto.Queryable.t(), query_opts) :: Ecto.Query.t()
    def query(%__MODULE__{} = cursor, q, opts \\ []) do
      opts = Keyword.validate!(opts, @query_opts_keys)
      page_size = page_size!(cursor, opts[:page_size])
      use_index? = use_index_opt!(opts)
      q = validate_queryable!(q, cursor)
      build_query(cursor, q, page_size, use_index?)
    end

    @doc """
    Runs the query for the page that follows the cursor position and returns an
    `Ark.EctoCursor.Page`.

        %Ark.EctoCursor.Page{entries: posts, has_next_page: more?, next_cursor: next} =
          Ark.EctoCursor.fetch_page(cursor, MyApp.Post, MyApp.Repo)

    The page entries are the rows returned by the query, in the cursor order.
    The next cursor points after the last entry, and keeps the page size and
    binding of the given cursor. When the page is empty, the next cursor is the
    given cursor.

    The query selects one row more than the page size to tell whether another
    page follows, so `:has_next_page` is exact even when the last page is full.

    The third argument runs the query. It is either an `Ecto.Repo` module, on
    which `c:Ecto.Repo.all/2` is called, or a function that receives the query
    and returns a list of rows. A function gives control over the repo options
    or the shape of the rows.

        Ark.EctoCursor.fetch_page(cursor, MyApp.Post, fn query ->
          MyApp.Repo.all(query, prefix: "tenant_42")
        end)

    Each row must be a map or a struct holding the sort fields, under atom or
    string keys.

    The options are the same as for `query/3`. Raises an `ArgumentError` for
    invalid options, a base query that does not fit the cursor, or when the last
    row of the page does not hold the sort fields or holds a `nil` sort value.
    """
    @spec fetch_page(t, Ecto.Queryable.t(), executor, query_opts) ::
            Ark.EctoCursor.Page.t()
    def fetch_page(%__MODULE__{} = cursor, q, repo, opts \\ []) do
      opts = Keyword.validate!(opts, @query_opts_keys)
      page_size = page_size!(cursor, opts[:page_size])
      use_index? = use_index_opt!(opts)
      q = validate_queryable!(q, cursor)
      fetch_valid_page(cursor, q, repo, page_size, use_index?)
    end

    @doc """
    Returns a lazy stream of all the rows that follow the cursor position.

        Ark.EctoCursor.new(order_by: :id, page_size: 500)
        |> Ark.EctoCursor.stream(MyApp.Post, MyApp.Repo)
        |> Stream.map(&MyApp.Search.to_document/1)
        |> Enum.each(&MyApp.Search.index/1)

    The stream fetches one page at a time with `fetch_page/4` as it is consumed,
    and ends after the last page. Each page runs as its own query, so rows
    inserted while the stream runs are included when they sort after the current
    position.

    The arguments and options are the same as for `fetch_page/4`. They are
    validated when `stream/4` is called, before any query runs.
    """
    @spec stream(t, Ecto.Queryable.t(), executor, query_opts) :: Enumerable.t(map)
    def stream(%__MODULE__{} = cursor, q, repo, opts \\ []) do
      opts = Keyword.validate!(opts, @query_opts_keys)
      page_size = page_size!(cursor, opts[:page_size])
      use_index? = use_index_opt!(opts)
      q = validate_queryable!(q, cursor)

      pages =
        Stream.unfold(cursor, fn
          %__MODULE__{} = c ->
            case fetch_valid_page(c, q, repo, page_size, use_index?) do
              %{entries: entries, has_next_page: true, next_cursor: next} ->
                {entries, next}

              %{entries: entries, has_next_page: false} ->
                {entries, :finish}
            end

          :finish ->
            nil
        end)

      Stream.flat_map(pages, & &1)
    end

    defp fetch_valid_page(cursor, q, repo, page_size, use_index?) do
      recordset =
        case run_query(repo, build_query(cursor, q, page_size + 1, use_index?)) do
          rows when is_list(rows) ->
            rows

          other ->
            raise ArgumentError,
                  "expected the executor to return a list of rows, got: #{inspect(other)}"
        end

      build_page(recordset, cursor, page_size)
    end

    defp run_query(repo, query) when is_atom(repo) do
      repo.all(query)
    end

    defp run_query(querier, query) when is_function(querier, 1) do
      querier.(query)
    end

    defp build_query(cursor, q, limit, use_index?) do
      %{binding: binding} = cursor
      q = inject_order_by(q, cursor, binding)

      q =
        if use_index? do
          inject_leading_bound(q, cursor, binding)
        else
          q
        end

      q
      |> inject_where(cursor, binding)
      |> limit([], ^limit)
    end

    defp order_by_opt!(opts) do
      case Keyword.fetch(opts, :order_by) do
        {:ok, v} -> Ark.EctoCursor.OrderBy.cast!(v)
        :error -> raise ArgumentError, "missing required option :order_by"
      end
    end

    defp page_size_opt!(opts) do
      case Keyword.fetch(opts, :page_size) do
        {:ok, nil} -> nil
        {:ok, v} -> validate_page_size!(v)
        :error -> nil
      end
    end

    defp binding_opt!(opts) do
      case Keyword.fetch(opts, :binding) do
        {:ok, v} when not is_atom(v) or is_boolean(v) ->
          raise ArgumentError,
                "expected :binding to be an atom (except booleans), got: #{inspect(v)}"

        {:ok, v} ->
          v

        :error ->
          nil
      end
    end

    defp page_size!(%{page_size: nil}, nil) do
      raise ArgumentError, """
      page_size is not defined

      The page size must be given to #{inspect(__MODULE__)}.new/1, \
      #{inspect(__MODULE__)}.resume/2, or as the :page_size option of \
      query/3, fetch_page/4 and stream/4.

      Cursors loaded from storage do not hold a page size, use \
      #{inspect(__MODULE__)}.resume/2 to set it.
      """
    end

    defp page_size!(%{page_size: n}, nil) do
      n
    end

    defp page_size!(_cursor, n) do
      validate_page_size!(n)
    end

    defp use_index_opt!(opts) do
      case Keyword.get(opts, :use_index) do
        nil ->
          true

        v when is_boolean(v) ->
          v

        v ->
          raise ArgumentError, "expected :use_index to be a boolean, got: #{inspect(v)}"
      end
    end

    defp validate_page_size!(n) when is_integer(n) and n > 0 do
      n
    end

    defp validate_page_size!(n) do
      raise ArgumentError,
            "expected :page_size to be a positive integer, got: #{inspect(n)}"
    end

    # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
    defp validate_queryable!(queryable, cursor) do
      q = Ecto.Queryable.to_query(queryable)
      binding = cursor.binding

      %Ecto.Query{
        limit: limit,
        offset: offset,
        order_bys: order_bys,
        combinations: combinations,
        distinct: distinct,
        select: select,
        aliases: aliases
      } = q

      cond do
        limit != nil ->
          raise ArgumentError,
                "base query must not have a limit, use the :page_size option instead"

        offset != nil ->
          raise ArgumentError, "base query must not have an offset"

        order_bys != [] ->
          raise ArgumentError,
                "base query must not have an order_by, the order is defined by the cursor"

        combinations != [] ->
          raise ArgumentError,
                "base query must not have combinations"

        match?(%{expr: [_ | _]}, distinct) ->
          raise ArgumentError,
                "base query must not have a distinct on expressions, " <>
                  "they would take precedence over the cursor order"

        binding != nil and not has_named_binding?(q, binding) ->
          raise ArgumentError,
                "binding #{inspect(binding)} is not defined in the query, " <>
                  "got bindings: #{inspect(Map.keys(aliases))}"

        binding != nil and select == nil and aliases[binding] != 0 ->
          raise ArgumentError,
                "query must have a select when the cursor binding #{inspect(binding)} " <>
                  "is a joined binding, otherwise rows are read from the root source"

        true ->
          q
      end
    end

    defp inject_order_by(query, cursor, binding) do
      %{order_by: order_by} = cursor
      bound = Enum.map(order_by, fn {dir, field} -> {dir, field_ref(binding, field)} end)

      order_by(query, ^bound)
    end

    defp field_ref(nil, field) do
      dynamic([o], field(o, ^field))
    end

    defp field_ref(binding, field) do
      dynamic([{^binding, o}], field(o, ^field))
    end

    defp inject_where(query, %{position: nil}, _) do
      query
    end

    defp inject_where(query, cursor, binding) do
      %{order_by: order_by, position: position} = cursor
      where(query, ^build_where_clause(order_by, position, binding))
    end

    defp inject_leading_bound(query, %{position: nil}, _) do
      query
    end

    defp inject_leading_bound(query, %{order_by: [_]}, _) do
      query
    end

    defp inject_leading_bound(query, cursor, binding) do
      %{order_by: [{direction, field} | _], position: [val | _]} = cursor
      where(query, ^where_at_or_after(direction, binding, field, val))
    end

    defp build_where_clause([{direction, field} = _last], [val], binding) do
      where_after(direction, binding, field, val)
    end

    defp build_where_clause([{direction, field} | order_by], [val | values], binding) do
      inequality = where_after(direction, binding, field, val)
      equality = where_equal(binding, field, val)
      sub = build_where_clause(order_by, values, binding)

      dynamic(^inequality or (^equality and ^sub))
    end

    defp where_after(:asc, binding, field, val) do
      where_greater(binding, field, val)
    end

    defp where_after(:desc, binding, field, val) do
      where_less(binding, field, val)
    end

    defp where_at_or_after(:asc, binding, field, val) do
      where_greater_or_equal(binding, field, val)
    end

    defp where_at_or_after(:desc, binding, field, val) do
      where_less_or_equal(binding, field, val)
    end

    defp where_greater_or_equal(nil, field, val) do
      dynamic([o], field(o, ^field) >= ^val)
    end

    defp where_greater_or_equal(binding, field, val) do
      dynamic([{^binding, o}], field(o, ^field) >= ^val)
    end

    defp where_less_or_equal(nil, field, val) do
      dynamic([o], field(o, ^field) <= ^val)
    end

    defp where_less_or_equal(binding, field, val) do
      dynamic([{^binding, o}], field(o, ^field) <= ^val)
    end

    defp where_greater(nil, field, val) do
      dynamic([o], field(o, ^field) > ^val)
    end

    defp where_greater(binding, field, val) do
      dynamic([{^binding, o}], field(o, ^field) > ^val)
    end

    defp where_less(nil, field, val) do
      dynamic([o], field(o, ^field) < ^val)
    end

    defp where_less(binding, field, val) do
      dynamic([{^binding, o}], field(o, ^field) < ^val)
    end

    defp where_equal(nil, field, val) do
      dynamic([o], field(o, ^field) == ^val)
    end

    defp where_equal(binding, field, val) do
      dynamic([{^binding, o}], field(o, ^field) == ^val)
    end

    defp build_page(recordset, cursor, page_size) do
      %{order_by: order_by, position: current_position} = cursor

      {entries, rest} = Enum.split(recordset, page_size)
      has_next_page? = rest != []

      next_position =
        case entries do
          [] -> current_position
          _ -> build_position(order_by, :lists.last(entries))
        end

      %Ark.EctoCursor.Page{
        entries: entries,
        has_next_page: has_next_page?,
        next_cursor: %{cursor | position: next_position}
      }
    end

    defp build_position(order_by, entry) when is_map(entry) do
      Enum.map(order_by, fn {_, field} ->
        case fetch_cursor_field!(entry, field) do
          nil ->
            raise ArgumentError,
                  "cursor :order_by option uses nullable field #{inspect(field)}, got: #{field}: nil"

          v ->
            v
        end
      end)
    end

    defp build_position(_order_by, entry) do
      raise ArgumentError, "expected rows to be maps or structs, got: #{inspect(entry)}"
    end

    defp fetch_cursor_field!(entry, field) when is_map_key(entry, field) do
      Map.fetch!(entry, field)
    end

    defp fetch_cursor_field!(entry, field) do
      case Map.fetch(entry, Atom.to_string(field)) do
        {:ok, value} ->
          value

        :error ->
          raise ArgumentError,
                "could not fetch cursor field #{inspect(field)} from row: #{inspect(entry)}"
      end
    end
  end
end
