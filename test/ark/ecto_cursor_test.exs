defmodule Ark.EctoCursorTest do
  use ExUnit.Case,
    async: false,
    parameterize: Ark.TestRepos.parameters()

  import Ecto.Query

  doctest Ark.EctoCursor
  doctest Ark.EctoCursor.OrderBy

  alias Ark.EctoCursor
  alias Ark.EctoCursor.MismatchError
  alias Ark.EctoCursor.Page
  alias Ark.TestCursorHolder
  alias Ark.TestItem
  alias Ecto.Adapters.SQL

  @t1 ~N[2024-01-01 00:00:00]
  @t2 ~N[2024-01-02 00:00:00]
  @t3 ~N[2024-01-03 00:00:00]

  setup %{repo: repo} do
    repo.delete_all(TestItem)
    repo.delete_all(TestCursorHolder)
    :ok
  end

  defp repo(%{repo: repo}) do
    repo
  end

  defp insert_table(repo, columns, rows) do
    Enum.map(rows, fn values ->
      fields = Enum.zip(columns, values)
      repo.insert!(struct!(TestItem, Keyword.merge(item_defaults(), fields)))
    end)
  end

  defp item_defaults do
    [
      uuid: Ecto.UUID.generate(),
      name: "item-#{System.unique_integer([:positive])}",
      score: 0,
      created_at: @t1
    ]
  end

  defp sorted_uuids(n) do
    Enum.sort(
      for _ <- 1..n do
        Ecto.UUID.generate()
      end
    )
  end

  defp ids(rows) do
    Enum.map(rows, fn
      %{id: id} -> id
      %{"id" => id} -> id
    end)
  end

  defp collect_pages(cursor, query, opts, executor) do
    page = EctoCursor.fetch_page(cursor, query, executor, opts)

    case page.has_next_page do
      false -> [ids(page.entries)]
      _ -> [ids(page.entries) | collect_pages(page.next_cursor, query, opts, executor)]
    end
  end

  defp collect_persisted_pages(repo, opts) do
    opts
    |> EctoCursor.new()
    |> Stream.unfold(fn
      nil ->
        nil

      cursor ->
        page = EctoCursor.fetch_page(cursor, TestItem, repo)

        next =
          if page.has_next_page do
            EctoCursor.resume!(json_roundtrip(page.next_cursor), opts)
          end

        {ids(page.entries), next}
    end)
    |> Enum.to_list()
  end

  defp json_roundtrip(cursor) do
    data =
      cursor
      |> Ecto.embedded_dump(:json)
      |> JSON.encode!()
      |> JSON.decode!()

    Ecto.embedded_load(EctoCursor, data, :json)
  end

  describe "new/1" do
    test "normalizes order_by" do
      assert [asc: :id] = EctoCursor.new(order_by: :id).order_by
      assert [asc: :a, asc: :b] = EctoCursor.new(order_by: [:a, :b]).order_by
      assert [desc: :a, asc: :b] = EctoCursor.new(order_by: [desc: :a, asc: :b]).order_by
      assert [asc: :a, desc: :b] = EctoCursor.new(order_by: [:a, desc: :b]).order_by
    end

    test "rejects invalid options" do
      assert_raise ArgumentError, ~r/missing required option :order_by/, fn ->
        EctoCursor.new([])
      end

      assert_raise ArgumentError, ~r/expected :order_by/, fn ->
        EctoCursor.new(order_by: [])
      end

      assert_raise ArgumentError, ~r/expected :order_by/, fn ->
        EctoCursor.new(order_by: "a")
      end

      assert_raise ArgumentError, ~r/invalid order_by element/, fn ->
        EctoCursor.new(order_by: ["a"])
      end

      assert_raise ArgumentError, ~r/invalid order_by element/, fn ->
        EctoCursor.new(order_by: [asc_nulls_first: :a])
      end

      assert_raise ArgumentError, ~r/invalid order_by element/, fn ->
        EctoCursor.new(order_by: [:a | :b])
      end

      assert_raise ArgumentError, ~r/positive integer/, fn ->
        EctoCursor.new(order_by: :id, page_size: 0)
      end
    end

    test "rejects duplicate order_by fields" do
      for order_by <- [[:id, :id], [:id, desc: :id], [{:asc, :id}, :score, {:desc, :id}]] do
        assert_raise ArgumentError, ~r/duplicate order_by field: :id$/, fn ->
          EctoCursor.new(order_by: order_by)
        end
      end
    end

    test "names the invalid order_by element" do
      assert_raise ArgumentError, ~r/invalid order_by element: "b"$/, fn ->
        EctoCursor.new(order_by: [:a, "b", :c])
      end
    end

    test "rejects nil and booleans as fields" do
      for invalid <- [nil, true, false] do
        assert_raise ArgumentError, ~r/expected :order_by/, fn ->
          EctoCursor.new(order_by: invalid)
        end

        assert_raise ArgumentError, ~r/invalid order_by element/, fn ->
          EctoCursor.new(order_by: [:id, invalid])
        end

        assert_raise ArgumentError, ~r/invalid order_by element/, fn ->
          EctoCursor.new(order_by: [asc: :id, desc: invalid])
        end
      end
    end
  end

  describe "optional options" do
    test "accept nil" do
      assert %EctoCursor{page_size: nil, binding: nil} =
               EctoCursor.new(order_by: :id, page_size: nil, binding: nil)

      stored = EctoCursor.new(order_by: :id, page_size: 2, binding: :target)

      assert %EctoCursor{page_size: nil, binding: nil} =
               EctoCursor.resume!(stored, order_by: :id, page_size: nil, binding: nil)
    end
  end

  describe "query/3" do
    test "rejects base queries with limit, offset or order_by" do
      cursor = EctoCursor.new(order_by: :id, page_size: 10)

      assert_raise ArgumentError, ~r/limit/, fn ->
        EctoCursor.query(cursor, limit(TestItem, 5))
      end

      assert_raise ArgumentError, ~r/offset/, fn ->
        EctoCursor.query(cursor, offset(TestItem, 5))
      end

      assert_raise ArgumentError, ~r/order_by/, fn ->
        EctoCursor.query(cursor, order_by(TestItem, :name))
      end
    end

    test "rejects base queries with combinations" do
      cursor = EctoCursor.new(order_by: :id, page_size: 10)
      low = where(TestItem, [i], i.id <= 2)
      high = where(TestItem, [i], i.id >= 4)

      for combined <- [
            union(low, ^high),
            union_all(low, ^high),
            except(low, ^high),
            except_all(low, ^high),
            intersect(low, ^high),
            intersect_all(low, ^high)
          ] do
        assert_raise ArgumentError, ~r/combination/, fn ->
          EctoCursor.query(cursor, combined)
        end

        assert_raise ArgumentError, ~r/combination/, fn ->
          EctoCursor.fetch_page(cursor, combined, &never_called/1)
        end
      end
    end

    test "rejects base queries with a distinct on expressions" do
      cursor = EctoCursor.new(order_by: :id, page_size: 10)

      for distinct_on <- [
            distinct(TestItem, [i], i.score),
            distinct(TestItem, [i], [:score])
          ] do
        assert_raise ArgumentError, ~r/distinct on expressions/, fn ->
          EctoCursor.query(cursor, distinct_on)
        end

        assert_raise ArgumentError, ~r/distinct on expressions/, fn ->
          EctoCursor.fetch_page(cursor, distinct_on, &never_called/1)
        end
      end
    end

    test "paginates over a distinct query", ctx do
      insert_table(repo(ctx), [:score], [[1], [3], [1], [2], [3]])
      query = from(i in TestItem, distinct: true, select: %{score: i.score})
      cursor = EctoCursor.new(order_by: :score, page_size: 2)

      assert [%{score: 1}, %{score: 2}, %{score: 3}] =
               Enum.to_list(EctoCursor.stream(cursor, query, repo(ctx)))
    end

    test "paginates over combinations wrapped in a subquery", ctx do
      insert_table(
        repo(ctx),
        [:id],
        for id <- 1..6 do
          [id]
        end
      )

      combined =
        union_all(where(TestItem, [i], i.id <= 2), ^where(TestItem, [i], i.id >= 4))

      cursor = EctoCursor.new(order_by: :id, page_size: 1)

      assert [[1], [2], [4], [5], [6]] =
               collect_pages(cursor, from(s in subquery(combined)), [], repo(ctx))
    end

    test "raises when no page size is given" do
      cursor = EctoCursor.new(order_by: :id)

      assert_raise ArgumentError, ~r/page_size is not defined/, fn ->
        EctoCursor.query(cursor, TestItem)
      end

      assert %Ecto.Query{} = EctoCursor.query(cursor, TestItem, page_size: 10)
    end

    test "rejects an invalid page_size option", ctx do
      cursor = EctoCursor.new(order_by: :id, page_size: 10)

      for invalid <- [false, 0, -1] do
        assert_raise ArgumentError, ~r/positive integer/, fn ->
          EctoCursor.query(cursor, TestItem, page_size: invalid)
        end

        assert_raise ArgumentError, ~r/positive integer/, fn ->
          EctoCursor.fetch_page(cursor, TestItem, repo(ctx), page_size: invalid)
        end
      end
    end

    test "limits to the page size", ctx do
      insert_table(
        repo(ctx),
        [:id],
        for id <- 1..5 do
          [id]
        end
      )

      cursor = EctoCursor.new(order_by: :id, page_size: 2)

      assert [%{id: 1}, %{id: 2}] = repo(ctx).all(EctoCursor.query(cursor, TestItem))
    end

    test "accepts any Ecto queryable", ctx do
      insert_table(
        repo(ctx),
        [:id, :score],
        [
          [1, 20],
          [2, 10],
          [3, 10]
        ]
      )

      cursor = EctoCursor.new(order_by: [:score, :id], page_size: 2)

      assert [%{id: 2}, %{id: 3}] =
               cursor
               |> EctoCursor.query("items")
               |> select([i], %{id: i.id})
               |> repo(ctx).all()

      assert [[2, 3], [1]] = collect_pages(cursor, {"items", TestItem}, [], repo(ctx))
    end
  end

  describe "fetch_page/4" do
    test "paginates on a single unique field", ctx do
      insert_table(
        repo(ctx),
        [:id],
        for id <- 1..7 do
          [id]
        end
      )

      cursor = EctoCursor.new(order_by: :id, page_size: 3)

      assert [[1, 2, 3], [4, 5, 6], [7]] = collect_pages(cursor, TestItem, [], repo(ctx))
    end

    test "uses the last field as a tie-breaker", ctx do
      insert_table(
        repo(ctx),
        [:id, :score],
        [
          [1, 20],
          [2, 10],
          [3, 10],
          [4, 30],
          [5, 10],
          [6, 20]
        ]
      )

      cursor = EctoCursor.new(order_by: [:score, :id], page_size: 2)

      assert [[2, 3], [5, 1], [6, 4]] = collect_pages(cursor, TestItem, [], repo(ctx))
    end

    test "supports mixed directions", ctx do
      insert_table(
        repo(ctx),
        [:id, :score],
        [
          [1, 20],
          [2, 10],
          [3, 10],
          [4, 30],
          [5, 10],
          [6, 20]
        ]
      )

      cursor = EctoCursor.new(order_by: [desc: :score, asc: :id], page_size: 4)

      assert [[4, 1, 6, 2], [3, 5]] = collect_pages(cursor, TestItem, [], repo(ctx))
    end

    test "has_next_page is exact when the last page is full", ctx do
      insert_table(
        repo(ctx),
        [:id],
        for id <- 1..4 do
          [id]
        end
      )

      cursor = EctoCursor.new(order_by: :id, page_size: 2)

      assert %Page{entries: [_, _], has_next_page: true, next_cursor: next} =
               EctoCursor.fetch_page(cursor, TestItem, repo(ctx))

      assert %Page{entries: [_, _], has_next_page: false, next_cursor: last} =
               EctoCursor.fetch_page(next, TestItem, repo(ctx))

      assert [4] = last.position
    end

    test "returns the same cursor on an empty page", ctx do
      cursor = EctoCursor.new(order_by: :id, page_size: 2)

      assert %Page{entries: [], has_next_page: false, next_cursor: ^cursor} =
               EctoCursor.fetch_page(cursor, TestItem, repo(ctx))
    end

    test "resumes after new rows are inserted", ctx do
      insert_table(repo(ctx), [:id], [[1], [2]])

      cursor = EctoCursor.new(order_by: :id, page_size: 5)

      assert %Page{entries: [_, _], has_next_page: false, next_cursor: next} =
               EctoCursor.fetch_page(cursor, TestItem, repo(ctx))

      assert %Page{entries: [], has_next_page: false, next_cursor: ^next} =
               EctoCursor.fetch_page(next, TestItem, repo(ctx))

      insert_table(repo(ctx), [:id], [[3]])

      assert %Page{entries: [%{id: 3}]} = EctoCursor.fetch_page(next, TestItem, repo(ctx))
    end

    test "page_size option overrides the cursor page size for one call", ctx do
      insert_table(
        repo(ctx),
        [:id],
        for id <- 1..5 do
          [id]
        end
      )

      cursor = EctoCursor.new(order_by: :id, page_size: 2)

      assert %Page{entries: [_, _, _, _], next_cursor: next} =
               EctoCursor.fetch_page(cursor, TestItem, repo(ctx), page_size: 4)

      assert 2 = next.page_size
    end

    test "supports named bindings", ctx do
      insert_table(
        repo(ctx),
        [:id, :score],
        [
          [1, 20],
          [2, 10],
          [3, 10],
          [4, 0]
        ]
      )

      query = from(i in TestItem, as: :item, where: i.score > 0)

      cursor =
        EctoCursor.new(order_by: [desc: :score, asc: :id], page_size: 2, binding: :item)

      assert [[1, 2], [3]] = collect_pages(cursor, query, [], repo(ctx))
    end

    test "orders and filters on a joined named binding", ctx do
      insert_table(
        repo(ctx),
        [:id, :score],
        [
          [1, 4],
          [2, 3],
          [3, 2],
          [4, 1]
        ]
      )

      query =
        from(i in TestItem,
          join: target in TestItem,
          as: :target,
          on: target.id == i.score,
          select: %{id: target.id, source_id: i.id}
        )

      cursor = EctoCursor.new(order_by: :id, page_size: 2, binding: :target)

      assert [[1, 2], [3, 4]] = collect_pages(cursor, query, [], repo(ctx))
    end

    test "compares ties on a joined named binding", ctx do
      insert_table(
        repo(ctx),
        [:id, :score, :created_at],
        [
          [1, 4, @t1],
          [2, 3, @t1],
          [3, 2, @t2],
          [4, 1, @t2]
        ]
      )

      query =
        from(i in TestItem,
          join: target in TestItem,
          as: :target,
          on: target.id == i.score,
          select: %{id: target.id, created_at: target.created_at}
        )

      cursor =
        EctoCursor.new(order_by: [:created_at, :id], page_size: 3, binding: :target)

      assert [[1, 2, 3], [4]] = collect_pages(cursor, query, [], repo(ctx))
    end

    test "supports rows selected as maps with string keys", ctx do
      insert_table(
        repo(ctx),
        [:id, :score],
        [
          [1, 20],
          [2, 10],
          [3, 10]
        ]
      )

      query = from(i in TestItem, select: %{"id" => i.id, "score" => i.score})
      cursor = EctoCursor.new(order_by: [:score, :id], page_size: 2)

      page = EctoCursor.fetch_page(cursor, query, repo(ctx))
      assert [%{"id" => 2}, %{"id" => 3}] = page.entries
      assert [10, 3] = page.next_cursor.position
    end
  end

  describe "fetch_page/4 with an executor function" do
    test "runs the paginated query through the function", ctx do
      insert_table(
        repo(ctx),
        [:id, :score],
        [
          [1, 20],
          [2, 10],
          [3, 10],
          [4, 30],
          [5, 10]
        ]
      )

      cursor = EctoCursor.new(order_by: [:score, :id], page_size: 2)

      as_raw_rows = fn query ->
        query
        |> repo(ctx).all()
        |> Enum.map(&%{"id" => &1.id, "score" => &1.score})
      end

      assert [[2, 3], [5, 1], [4]] = collect_pages(cursor, TestItem, [], as_raw_rows)
    end

    test "raises when a row does not have a cursor field" do
      cursor = EctoCursor.new(order_by: [:score, :id], page_size: 2)

      assert_raise ArgumentError, ~r/could not fetch cursor field :score/, fn ->
        EctoCursor.fetch_page(cursor, TestItem, fn _ -> [%{id: 1}] end)
      end
    end

    test "raises when rows are not maps" do
      cursor = EctoCursor.new(order_by: :id, page_size: 2)

      assert_raise ArgumentError, ~r/expected rows to be maps or structs/, fn ->
        EctoCursor.fetch_page(cursor, TestItem, fn _ -> [{1, "item"}] end)
      end
    end

    test "raises when the row holding the position is not a map" do
      cursor = EctoCursor.new(order_by: :id, page_size: 2)

      assert_raise ArgumentError, ~r/expected rows to be maps or structs/, fn ->
        EctoCursor.fetch_page(cursor, TestItem, fn _ -> [%{id: 1}, nil] end)
      end
    end

    test "raises when the executor does not return a list", ctx do
      cursor = EctoCursor.new(order_by: :id, page_size: 2)

      assert_raise ArgumentError, ~r/expected the executor to return a list/, fn ->
        EctoCursor.fetch_page(cursor, TestItem, fn query ->
          {:ok, repo(ctx).all(query)}
        end)
      end
    end
  end

  describe "persistence" do
    test "page_size is not persisted" do
      cursor = EctoCursor.new(order_by: :id, page_size: 2)

      assert %EctoCursor{order_by: [asc: :id], position: nil, page_size: nil} =
               json_roundtrip(cursor)
    end

    test "binding is not persisted" do
      cursor = EctoCursor.new(order_by: :id, binding: :target)

      assert %{binding: nil} = json_roundtrip(cursor)
    end

    test "a reloaded cursor continues on a date field", ctx do
      insert_table(
        repo(ctx),
        [:id, :created_at],
        [
          [1, @t2],
          [2, @t1],
          [3, @t1],
          [4, @t3],
          [5, @t1],
          [6, @t2]
        ]
      )

      cursor = EctoCursor.new(order_by: [desc: :created_at, asc: :id], page_size: 3)

      %Page{entries: first, next_cursor: next} =
        EctoCursor.fetch_page(cursor, TestItem, repo(ctx))

      assert [4, 1, 6] = ids(first)

      reloaded = json_roundtrip(next)
      assert [<<_::binary>>, 6] = reloaded.position

      assert %Page{entries: second, has_next_page: false} =
               EctoCursor.fetch_page(reloaded, TestItem, repo(ctx), page_size: 3)

      assert [2, 3, 5] = ids(second)
    end

    test "a reloaded cursor on a date field needs a schema source on Postgres", ctx do
      insert_table(repo(ctx), [:id, :created_at], [[1, @t2], [2, @t1], [3, @t3]])
      query = from(i in "items", select: map(i, [:id, :created_at]))
      cursor = EctoCursor.new(order_by: [desc: :created_at, asc: :id], page_size: 1)

      %Page{next_cursor: next} = EctoCursor.fetch_page(cursor, query, repo(ctx))
      reloaded = json_roundtrip(next)

      case repo(ctx) do
        Ark.PgRepo ->
          # The message is written by Postgrex, it may change across versions
          assert_raise DBConnection.EncodeError, ~r/got "2024-01-03T00:00:00"/, fn ->
            EctoCursor.fetch_page(reloaded, query, repo(ctx), page_size: 2)
          end

        Ark.TestRepo ->
          assert %Page{entries: [%{id: 1}, %{id: 2}]} =
                   EctoCursor.fetch_page(reloaded, query, repo(ctx), page_size: 2)
      end
    end
  end

  describe "loading from storage" do
    test "fails when the stored order_by has an unknown direction" do
      assert_raise ArgumentError, fn ->
        Ecto.embedded_load(
          EctoCursor,
          %{"order_by" => [["sideways", "id"]], "position" => nil},
          :json
        )
      end
    end

    test "fails when a stored order_by field does not exist" do
      assert_raise ArgumentError, fn ->
        Ecto.embedded_load(
          EctoCursor,
          %{
            "order_by" => [["asc", "no_atom_exists_with_this_name_8f3a2c"]],
            "position" => nil
          },
          :json
        )
      end
    end

    test "fails when the stored order_by has duplicate fields" do
      assert_raise ArgumentError, fn ->
        Ecto.embedded_load(
          EctoCursor,
          %{"order_by" => [["asc", "id"], ["desc", "id"]], "position" => nil},
          :json
        )
      end
    end
  end

  describe "embedding in a schema" do
    test "a cursor is stored in a column and continues from it", ctx do
      insert_table(
        repo(ctx),
        [:id],
        for id <- 1..5 do
          [id]
        end
      )

      opts = [order_by: [desc: :id], page_size: 2]
      page = EctoCursor.fetch_page(EctoCursor.new(opts), TestItem, repo(ctx))
      holder = repo(ctx).insert!(%TestCursorHolder{cursor: page.next_cursor})

      stored = repo(ctx).get!(TestCursorHolder, holder.id).cursor
      assert %EctoCursor{order_by: [desc: :id], position: [4]} = stored

      page = EctoCursor.fetch_page(EctoCursor.resume!(stored, opts), TestItem, repo(ctx))
      assert [3, 2] = ids(page.entries)
    end

    test "a stored cursor is replaced by the next cursor", ctx do
      insert_table(
        repo(ctx),
        [:id],
        for id <- 1..5 do
          [id]
        end
      )

      opts = [order_by: :id, page_size: 2]
      holder = repo(ctx).insert!(%TestCursorHolder{cursor: EctoCursor.new(opts)})

      page =
        EctoCursor.fetch_page(
          EctoCursor.resume!(holder.cursor, opts),
          TestItem,
          repo(ctx)
        )

      holder
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_embed(:cursor, page.next_cursor)
      |> repo(ctx).update!()

      assert %EctoCursor{position: [2]} =
               repo(ctx).get!(TestCursorHolder, holder.id).cursor
    end
  end

  describe "casting in a changeset" do
    defp cast_cursor(params) do
      Ecto.Changeset.cast(%EctoCursor{}, params, [:order_by, :position])
    end

    test "casts order_by from the Ecto syntax" do
      changeset = cast_cursor(%{order_by: [:score, desc: :id], position: [10, 3]})

      assert {:ok, %EctoCursor{order_by: [asc: :score, desc: :id], position: [10, 3]}} =
               Ecto.Changeset.apply_action(changeset, :cast)

      assert {:ok, %EctoCursor{order_by: [asc: :id]}} =
               Ecto.Changeset.apply_action(cast_cursor(%{order_by: :id}), :cast)
    end

    test "casts order_by from the stored format" do
      changeset =
        cast_cursor(%{
          "order_by" => [["asc", "score"], ["desc", "id"]],
          "position" => [10, 3]
        })

      assert {:ok, %EctoCursor{order_by: [asc: :score, desc: :id], position: [10, 3]}} =
               Ecto.Changeset.apply_action(changeset, :cast)
    end

    test "invalid order_by is a changeset error" do
      for invalid <- [
            [],
            "id",
            [nil],
            [["sideways", "id"]],
            [["asc", :id]],
            [:id | :name]
          ] do
        changeset = cast_cursor(%{order_by: invalid})

        assert {:error, %{errors: [order_by: {"is invalid", _}]}} =
                 Ecto.Changeset.apply_action(changeset, :cast)
      end
    end
  end

  describe "timestamp ordering with a UUID tie-breaker" do
    test "paginates in order across persisted cursors", ctx do
      [u1, u2, u3, u4, u5, u6, u7] = sorted_uuids(7)

      insert_table(
        repo(ctx),
        [:id, :created_at, :uuid],
        [
          [1, @t2, u3],
          [2, @t1, u6],
          [3, @t3, u1],
          [4, @t1, u2],
          [5, @t2, u7],
          [6, @t1, u4],
          [7, @t2, u5]
        ]
      )

      assert [[4, 6], [2, 1], [7, 5], [3]] =
               collect_persisted_pages(repo(ctx),
                 order_by: [:created_at, :uuid],
                 page_size: 2
               )
    end

    test "paginates through rows sharing a timestamp across page boundaries", ctx do
      [u1, u2, u3, u4, u5, u6] = sorted_uuids(6)

      insert_table(
        repo(ctx),
        [:id, :created_at, :uuid],
        [
          [1, @t1, u3],
          [2, @t2, u5],
          [3, @t1, u1],
          [4, @t2, u4],
          [5, @t1, u2],
          [6, @t2, u6]
        ]
      )

      assert [[3, 5], [1, 4], [2, 6]] =
               collect_persisted_pages(repo(ctx),
                 order_by: [:created_at, :uuid],
                 page_size: 2
               )
    end

    test "picks up rows inserted after reaching the end", ctx do
      [u1, u2, u3, u4] = sorted_uuids(4)

      insert_table(
        repo(ctx),
        [:id, :created_at, :uuid],
        [
          [1, @t1, u4],
          [2, @t1, u3]
        ]
      )

      opts = [order_by: [:created_at, :uuid], page_size: 10]

      assert %Page{entries: [%{id: 2}, %{id: 1}], has_next_page: false, next_cursor: next} =
               EctoCursor.fetch_page(EctoCursor.new(opts), TestItem, repo(ctx))

      stored = json_roundtrip(next)

      insert_table(
        repo(ctx),
        [:id, :created_at, :uuid],
        [
          [3, @t2, u2],
          [4, @t2, u1]
        ]
      )

      assert %Page{entries: [%{id: 4}, %{id: 3}], has_next_page: false} =
               EctoCursor.fetch_page(
                 EctoCursor.resume!(stored, opts),
                 TestItem,
                 repo(ctx)
               )
    end
  end

  describe "ordering on three fields" do
    test "continues after the position compared on every field", ctx do
      insert_table(
        repo(ctx),
        [:id, :score, :created_at],
        [
          [9, 1, @t3],
          [8, 1, @t2],
          [7, 2, @t1],
          [4, 2, @t2],
          [5, 2, @t2],
          [6, 2, @t2],
          [3, 2, @t3],
          [2, 3, @t2],
          [1, 3, @t1]
        ]
      )

      cursor = EctoCursor.new(order_by: [:score, :created_at, :id], page_size: 5)

      assert [[8, 9, 7, 4, 5], [6, 3, 1, 2]] =
               collect_pages(cursor, TestItem, [], repo(ctx))
    end

    test "continues after the position with asc, desc, asc directions", ctx do
      insert_table(
        repo(ctx),
        [:id, :score, :created_at],
        [
          [9, 1, @t1],
          [8, 1, @t2],
          [7, 2, @t3],
          [4, 2, @t2],
          [5, 2, @t2],
          [6, 2, @t2],
          [3, 2, @t1],
          [2, 3, @t2],
          [1, 3, @t3]
        ]
      )

      cursor =
        EctoCursor.new(order_by: [asc: :score, desc: :created_at, asc: :id], page_size: 5)

      assert [[8, 9, 7, 4, 5], [6, 3, 1, 2]] =
               collect_pages(cursor, TestItem, [], repo(ctx))
    end

    test "continues after the position with desc, asc, desc directions", ctx do
      insert_table(
        repo(ctx),
        [:id, :score, :created_at],
        [
          [1, 3, @t3],
          [2, 3, @t2],
          [3, 2, @t1],
          [6, 2, @t2],
          [5, 2, @t2],
          [4, 2, @t2],
          [7, 2, @t3],
          [8, 1, @t2],
          [9, 1, @t1]
        ]
      )

      cursor =
        EctoCursor.new(
          order_by: [desc: :score, asc: :created_at, desc: :id],
          page_size: 5
        )

      assert [[2, 1, 3, 6, 5], [4, 7, 9, 8]] =
               collect_pages(cursor, TestItem, [], repo(ctx))
    end
  end

  describe "resume/2" do
    test "creates a new cursor from nil" do
      assert {:ok, %EctoCursor{order_by: [asc: :id], position: nil, page_size: 2}} =
               EctoCursor.resume(nil, order_by: :id, page_size: 2)
    end

    test "keeps the position and sets the page size" do
      stored =
        json_roundtrip(%{EctoCursor.new(order_by: [:score, :id]) | position: [10, 3]})

      assert {:ok, %EctoCursor{position: [10, 3], page_size: 5}} =
               EctoCursor.resume(stored, order_by: [asc: :score, asc: :id], page_size: 5)
    end

    test "returns an error when order_by differs" do
      stored = EctoCursor.new(order_by: [:score, :id])

      assert {:error, %MismatchError{stored: [asc: :score, asc: :id]}} =
               EctoCursor.resume(stored, order_by: [desc: :score, asc: :id])

      assert_raise MismatchError, fn ->
        EctoCursor.resume!(stored, order_by: :id)
      end
    end

    test "takes the page size from the options" do
      stored = EctoCursor.new(order_by: :id, page_size: 5)

      assert %{page_size: 10} = EctoCursor.resume!(stored, order_by: :id, page_size: 10)
      assert %{page_size: nil} = EctoCursor.resume!(stored, order_by: :id)
    end

    test "takes the binding from the options" do
      stored = EctoCursor.new(order_by: :id, binding: :target)

      assert %{binding: :other} =
               EctoCursor.resume!(stored, order_by: :id, binding: :other)

      assert %{binding: nil} = EctoCursor.resume!(stored, order_by: :id)
    end

    test "raises on invalid options even with a stored cursor" do
      stored = EctoCursor.new(order_by: :id)

      assert_raise ArgumentError, fn ->
        EctoCursor.resume(stored, order_by: :id, page_size: -1)
      end
    end
  end

  describe "invalid bindings" do
    defp joined_query do
      from(i in TestItem,
        join: target in TestItem,
        as: :target,
        on: target.id == i.score,
        select: %{id: target.id}
      )
    end

    defp never_called(_query) do
      flunk("the query should not be executed")
    end

    test "rejects a binding that is not an atom or is a boolean" do
      for invalid <- ["target", true, false, 1] do
        assert_raise ArgumentError, ~r/expected :binding/, fn ->
          EctoCursor.new(order_by: :id, binding: invalid)
        end
      end
    end

    test "raises when the binding is not defined in the query" do
      cursor = EctoCursor.new(order_by: :id, page_size: 2, binding: :renamed)

      assert_raise ArgumentError, ~r/binding :renamed .*\[:target\]/, fn ->
        EctoCursor.query(cursor, joined_query())
      end
    end

    test "raises when a binding is given with a bare schema" do
      cursor = EctoCursor.new(order_by: :id, page_size: 2, binding: :target)

      assert_raise ArgumentError, ~r/binding :target/, fn ->
        EctoCursor.query(cursor, TestItem)
      end
    end

    test "raises before executing the query" do
      cursor = EctoCursor.new(order_by: :id, page_size: 2, binding: :renamed)

      assert_raise ArgumentError, ~r/binding :renamed/, fn ->
        EctoCursor.fetch_page(cursor, joined_query(), &never_called/1)
      end
    end

    test "rejects a joined binding when the query has no select" do
      cursor = EctoCursor.new(order_by: :id, page_size: 2, binding: :target)

      unselected =
        from(i in TestItem,
          join: target in TestItem,
          as: :target,
          on: target.id == i.score
        )

      assert_raise ArgumentError, ~r/select/, fn ->
        EctoCursor.query(cursor, unselected)
      end

      assert_raise ArgumentError, ~r/select/, fn ->
        EctoCursor.fetch_page(cursor, unselected, &never_called/1)
      end
    end

    test "accepts the root binding without a select on a joined query", ctx do
      insert_table(
        repo(ctx),
        [:id, :score],
        [
          [1, 2],
          [2, 1],
          [3, 1]
        ]
      )

      query =
        from(i in TestItem,
          as: :item,
          join: target in TestItem,
          as: :target,
          on: target.id == i.score
        )

      for binding <- [:item, nil] do
        cursor = EctoCursor.new(order_by: [desc: :id], page_size: 2, binding: binding)

        assert [[3, 2], [1]] = collect_pages(cursor, query, [], repo(ctx))
      end
    end
  end

  describe "nil cursor values" do
    test "raises when the row holding the position has a nil cursor value" do
      cursor = EctoCursor.new(order_by: [:score, :id], page_size: 1)

      for {row, field} <- [
            {%{id: 1, score: nil}, ":score"},
            {%{"id" => 1, "score" => nil}, ":score"},
            {%TestItem{id: 1, score: nil}, ":score"},
            {%{id: nil, score: 1}, ":id"}
          ] do
        error =
          assert_raise ArgumentError, ~r/nil/, fn ->
            EctoCursor.fetch_page(cursor, TestItem, fn _ -> [row, %{id: 2, score: 5}] end)
          end

        assert Exception.message(error) =~ field
        refute Exception.message(error) =~ "could not fetch"
      end
    end

    test "raises when a left join yields a NULL sort value", ctx do
      insert_table(repo(ctx), [:id, :score], [[1, 99]])

      query =
        from(i in TestItem,
          left_join: target in TestItem,
          as: :target,
          on: target.id == i.score,
          select: %{id: target.id, source_id: i.id}
        )

      cursor = EctoCursor.new(order_by: :id, page_size: 1, binding: :target)

      assert_raise ArgumentError, ~r/nil/, fn ->
        EctoCursor.fetch_page(cursor, query, repo(ctx))
      end
    end
  end

  describe "unknown options" do
    test "are rejected by new/1" do
      assert_raise ArgumentError, ~r/pagesize/, fn ->
        EctoCursor.new(order_by: :id, pagesize: 3)
      end
    end

    test "are rejected by resume/2 and resume!/2" do
      stored = EctoCursor.new(order_by: :id)

      for cursor <- [nil, stored] do
        assert_raise ArgumentError, ~r/pagesize/, fn ->
          EctoCursor.resume(cursor, order_by: :id, pagesize: 3)
        end

        assert_raise ArgumentError, ~r/pagesize/, fn ->
          EctoCursor.resume!(cursor, order_by: :id, pagesize: 3)
        end
      end
    end

    test "are rejected by query/3, fetch_page/4 and stream/4" do
      cursor = EctoCursor.new(order_by: :id, page_size: 2)

      for {key, _} = opt <- [pagesize: 3, binding: :target, order_by: :name] do
        pattern = ~r/#{key}/

        assert_raise ArgumentError, pattern, fn ->
          EctoCursor.query(cursor, joined_query(), [opt])
        end

        assert_raise ArgumentError, pattern, fn ->
          EctoCursor.fetch_page(cursor, joined_query(), &never_called/1, [opt])
        end

        assert_raise ArgumentError, pattern, fn ->
          EctoCursor.stream(cursor, joined_query(), &never_called/1, [opt])
        end
      end
    end
  end

  describe "use_index" do
    defp positioned_sql(repo, order_by, opts) do
      cursor = %{EctoCursor.new(order_by: order_by, page_size: 10) | position: [5, 3]}

      {sql, _params} =
        SQL.to_sql(:all, repo, EctoCursor.query(cursor, TestItem, opts))

      sql
    end

    test "bounds the leading sort field by default", ctx do
      assert positioned_sql(repo(ctx), [:score, :id], []) =~ ~r/"score" >= /
      assert positioned_sql(repo(ctx), [desc: :score, asc: :id], []) =~ ~r/"score" <= /
      assert positioned_sql(repo(ctx), [:score, :id], use_index: true) =~ ~r/"score" >= /
      assert positioned_sql(repo(ctx), [:score, :id], use_index: nil) =~ ~r/"score" >= /
    end

    test "can be disabled", ctx do
      sql = positioned_sql(repo(ctx), [:score, :id], use_index: false)

      refute sql =~ ~r/>=|<=/
      assert sql =~ ~r/"score" > /
    end

    test "adds no bound with a single sort field", ctx do
      cursor = %{EctoCursor.new(order_by: :id, page_size: 10) | position: [5]}

      {sql, _} =
        SQL.to_sql(:all, repo(ctx), EctoCursor.query(cursor, TestItem))

      refute sql =~ ~r/>=/
    end

    test "rejects a non-boolean value" do
      cursor = EctoCursor.new(order_by: [:score, :id], page_size: 10)

      for invalid <- [1, "true"] do
        assert_raise ArgumentError, ~r/expected :use_index to be a boolean/, fn ->
          EctoCursor.query(cursor, TestItem, use_index: invalid)
        end

        assert_raise ArgumentError, ~r/expected :use_index to be a boolean/, fn ->
          EctoCursor.fetch_page(cursor, TestItem, &never_called/1, use_index: invalid)
        end
      end
    end
  end

  describe "stream/4" do
    test "streams all rows in order", ctx do
      insert_table(
        repo(ctx),
        [:id, :score],
        for id <- 1..10 do
          [id, rem(id, 3)]
        end
      )

      cursor = EctoCursor.new(order_by: [:score, :id], page_size: 3)

      assert [3, 6, 9, 1, 4, 7, 10, 2, 5, 8] =
               cursor |> EctoCursor.stream(TestItem, repo(ctx)) |> Enum.map(& &1.id)
    end

    test "is lazy", ctx do
      insert_table(
        repo(ctx),
        [:id],
        for id <- 1..10 do
          [id]
        end
      )

      cursor = EctoCursor.new(order_by: :id, page_size: 2)
      stream = EctoCursor.stream(cursor, TestItem, repo(ctx))

      repo(ctx).delete_all(TestItem)

      assert [] = Enum.to_list(stream)
    end

    test "validates options and the query when called" do
      cursor = EctoCursor.new(order_by: :id, page_size: 2)

      assert_raise ArgumentError, ~r/page_size is not defined/, fn ->
        EctoCursor.stream(EctoCursor.new(order_by: :id), TestItem, &never_called/1)
      end

      assert_raise ArgumentError, ~r/:page_size/, fn ->
        EctoCursor.stream(cursor, TestItem, &never_called/1, page_size: 0)
      end

      assert_raise ArgumentError, ~r/:use_index/, fn ->
        EctoCursor.stream(cursor, TestItem, &never_called/1, use_index: 1)
      end

      assert_raise ArgumentError, ~r/limit/, fn ->
        EctoCursor.stream(cursor, limit(TestItem, 1), &never_called/1)
      end
    end

    test "can be halted before the last page", ctx do
      insert_table(
        repo(ctx),
        [:id],
        for id <- 1..10 do
          [id]
        end
      )

      cursor = EctoCursor.new(order_by: :id, page_size: 2)

      assert [1, 2, 3] =
               cursor
               |> EctoCursor.stream(TestItem, repo(ctx))
               |> Enum.take(3)
               |> Enum.map(& &1.id)
    end

    test "streams through an executor function", ctx do
      insert_table(
        repo(ctx),
        [:id],
        for id <- 1..5 do
          [id]
        end
      )

      cursor = EctoCursor.new(order_by: :id, page_size: 2)

      assert [1, 2, 3, 4, 5] =
               cursor
               |> EctoCursor.stream(TestItem, fn q -> repo(ctx).all(q) end)
               |> Enum.map(& &1.id)
    end
  end
end
