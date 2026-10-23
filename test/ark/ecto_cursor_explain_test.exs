defmodule Ark.EctoCursorExplainTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ark.EctoCursor
  alias Ark.TestItem
  alias Ecto.Adapters.SQL

  @source {"bench_items", TestItem}
  @order_by [asc: :score, asc: :id]

  defp deep_cursor(repo) do
    row = repo.one(from(i in @source, order_by: ^@order_by, offset: 180_000, limit: 1))
    cursor = EctoCursor.new(order_by: @order_by, page_size: 50)
    %{cursor | position: [row.score, row.id]}
  end

  test "lets SQLite search the index from the position" do
    repo = Ark.TestRepo
    query = EctoCursor.query(deep_cursor(repo), @source)

    assert SQL.explain(repo, :all, query, type: :query_plan) =~
             ~r/SEARCH .* USING INDEX bench_items_score_id \(score>\?\)/
  end

  @tag :postgres
  test "lets Postgres seek the index from the position" do
    repo = Ark.PgRepo
    query = EctoCursor.query(deep_cursor(repo), @source)

    assert SQL.explain(repo, :all, query) =~ ~r/Index Cond: \(score >= /
  end
end

defmodule Ark.EctoCursorExplainOutputTest do
  use ExUnit.Case,
    async: false,
    parameterize: Ark.TestRepos.parameters()

  import Ecto.Query

  alias Ark.EctoCursor
  alias Ark.TestItem
  alias Ecto.Adapters.SQL

  @moduletag :explain_output

  @skipped_rows 100_000

  defp explain(Ark.PgRepo, query) do
    SQL.explain(Ark.PgRepo, :all, query, analyze: true, buffers: true)
  end

  defp explain(repo, query) do
    SQL.explain(repo, :all, query, type: :query_plan)
  end

  test "prints the SQL and plan with and without use_index", %{repo: repo} do
    base = from(i in {"bench_items", TestItem}, where: i.name != "")

    cursor =
      EctoCursor.new(order_by: [asc: :score, desc: :created_at, asc: :id], page_size: 10)

    for use_index <- [true, false] do
      %{next_cursor: next} =
        EctoCursor.fetch_page(cursor, base, repo,
          page_size: @skipped_rows,
          use_index: use_index
        )

      query = EctoCursor.query(next, base, use_index: use_index)
      {sql, params} = SQL.to_sql(:all, repo, query)

      IO.puts("""

      ==== #{inspect(repo)} | use_index: #{use_index} | position after #{@skipped_rows} rows: #{inspect(next.position)}

      #{sql}

      params: #{inspect(params)}

      #{explain(repo, query)}
      """)
    end
  end
end
