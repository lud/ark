{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
{:ok, _} = Ark.TestRepo.start_link()

Ark.TestRepo.query!("""
CREATE TABLE items (
  id INTEGER PRIMARY KEY,
  uuid TEXT NOT NULL,
  name TEXT NOT NULL,
  score INTEGER NOT NULL,
  created_at TEXT NOT NULL
)
""")

Ark.TestRepo.query!("""
CREATE TABLE cursor_holders (
  id INTEGER PRIMARY KEY,
  cursor TEXT
)
""")

Ark.TestRepo.query!("""
CREATE TABLE bench_items (
  id INTEGER PRIMARY KEY,
  uuid TEXT NOT NULL,
  name TEXT NOT NULL,
  score INTEGER NOT NULL,
  created_at TEXT NOT NULL
)
""")

Ark.TestRepo.query!("CREATE INDEX bench_items_score_id ON bench_items (score, id)")

Ark.TestRepo.query!(
  "CREATE INDEX bench_items_score_id_desc ON bench_items (score, id DESC)"
)

Ark.TestRepo.query!(
  "CREATE INDEX bench_items_created_at_uuid ON bench_items (created_at, uuid)"
)

Ark.TestRepo.query!(
  "CREATE INDEX bench_items_score_created_at_desc_id ON bench_items (score, created_at DESC, id)"
)

Ark.TestRepo.query!("""
WITH RECURSIVE g(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM g WHERE n < 200000)
INSERT INTO bench_items (id, uuid, name, score, created_at)
SELECT
  n,
  printf('%08x-0000-4000-8000-%012x', (n * 2654435761) % 4294967296, n),
  'item-' || n,
  (n * 7919) % 1000,
  strftime('%Y-%m-%dT%H:%M:%S', '2024-01-01', '+' || ((n * 104729) % 31536000) || ' seconds')
FROM g
""")

Ark.TestRepo.query!("ANALYZE")

if Ark.PgRepo in Ark.TestRepos.enabled() do
  {:ok, _} = Application.ensure_all_started(:postgrex)
  _ = Ecto.Adapters.Postgres.storage_up(Ark.PgRepo.config())
  {:ok, _} = Ark.PgRepo.start_link()

  Ark.PgRepo.query!("DROP TABLE IF EXISTS items")
  Ark.PgRepo.query!("DROP TABLE IF EXISTS cursor_holders")

  Ark.PgRepo.query!("""
  CREATE TABLE items (
    id bigserial PRIMARY KEY,
    uuid uuid NOT NULL,
    name text NOT NULL,
    score integer NOT NULL,
    created_at timestamp(0) NOT NULL
  )
  """)

  Ark.PgRepo.query!("""
  CREATE TABLE cursor_holders (
    id bigserial PRIMARY KEY,
    cursor jsonb
  )
  """)

  Ark.PgRepo.query!("""
  CREATE TABLE IF NOT EXISTS bench_items (
    id bigint PRIMARY KEY,
    uuid uuid NOT NULL,
    name text NOT NULL,
    score integer NOT NULL,
    created_at timestamp(0) NOT NULL
  )
  """)

  Ark.PgRepo.query!(
    "CREATE INDEX IF NOT EXISTS bench_items_score_id ON bench_items (score, id)"
  )

  Ark.PgRepo.query!(
    "CREATE INDEX IF NOT EXISTS bench_items_score_id_desc ON bench_items (score, id DESC)"
  )

  Ark.PgRepo.query!(
    "CREATE INDEX IF NOT EXISTS bench_items_created_at_uuid ON bench_items (created_at, uuid)"
  )

  Ark.PgRepo.query!(
    "CREATE INDEX IF NOT EXISTS bench_items_score_created_at_desc_id " <>
      "ON bench_items (score, created_at DESC, id)"
  )

  if Ark.PgRepo.query!("SELECT count(*) FROM bench_items").rows == [[0]] do
    Ark.PgRepo.query!("""
    INSERT INTO bench_items (id, uuid, name, score, created_at)
    SELECT
      g,
      md5(g::text)::uuid,
      'item-' || g,
      (g * 7919) % 1000,
      timestamp '2024-01-01' + ((g::bigint * 104729) % 31536000) * interval '1 second'
    FROM generate_series(1, 200000) g
    """)

    Ark.PgRepo.query!("ANALYZE bench_items")
  end
end

ExUnit.start(exclude: [:explain_output])
