import Config
config :logger, level: :debug

config :ark, Ark.TestRepo,
  database: ":memory:",
  pool_size: 1,
  log: false

config :ark, Ark.PgRepo,
  database: "ark_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432,
  pool_size: 10,
  log: false
