# Changelog

All notable changes to this project will be documented in this file.

## [0.14.0] - 2026-10-23

This release adds `Ark.EctoCursor`, keyset pagination for Ecto queries.

A cursor holds a sort order and the position of the last row read. Pages are
fetched with a `WHERE` clause that continues right after that position, so they
stay consistent when rows are inserted or deleted between calls, and deep pages
stay fast with an index matching the sort order.

```elixir
cursor = Ark.EctoCursor.new(order_by: [desc: :inserted_at, asc: :id], page_size: 20)

%Ark.EctoCursor.Page{entries: posts, next_cursor: next} =
  Ark.EctoCursor.fetch_page(cursor, MyApp.Post, MyApp.Repo)
```

- `fetch_page/4` returns one page with the cursor for the next one, and
  `stream/4` lazily walks through every row.
- `query/3` returns the paginated `Ecto.Query` for custom execution.
- Base queries can use `where`, `join`, `select` and `distinct: true`, and the
  `:binding` option sorts on a joined source.
- Cursors are embedded schemas: store them with `embeds_one` and turn them back
  into working cursors with `resume/2` or `resume!/2`, to resume long running
  jobs or poll a table for new rows.

Ecto is an optional dependency: add `{:ecto, "~> 3.10"}` to your project to
use `Ark.EctoCursor`.


### 🚀 Features

- Add new Ark.EctoCursor tool (_lud_)

### ⚙️ Miscellaneous Tasks

- Setup library release process (_lud_)

## [0.13.2] - 2026-09-02

### 🚀 Features

- Support private and public audiences in Ark.Error formatters (_lud_)

### 📚 Documentation

- Added missing docs troughout codebase (_lud_)

## [0.13.1] - 2026-05-29

### ⚙️ Miscellaneous Tasks

- Fix compilation warnings for Elixir 1.20 (_lud_)

## [0.13.0] - 2026-05-13

### 🚀 Features

- Added Ark.Timeout utility (_lud_)
- Removed unused PubSub utility (_lud_)
- Paginator will now raise page errors as dedicated exceptions (_lud_)

## [0.12.0] - 2026-05-04

### 🚀 Features

- Added the Ark.Paginator module (_lud_)

## [0.11.0] - 2026-04-21

### 🚀 Features

- Added Ark.Retry for macro-free retry utilities (_lud_)

## [0.10.1] - 2026-03-19

### 🚀 Features

- Added Ark.Ok.flat_map_ok/2 (_lud_)

### 📚 Documentation

- Added examples for complex 'ok' functions (_lud_)

## [0.10.0] - 2026-03-19

### 🚀 Features

- [**breaking**] Removed the drip module (extracted as the kota library) (_lud_)
- [**breaking**] Removed the deprecated Ark.Ok.uok function (_lud_)
- [**breaking**] Removed the Ark.PipeIn module (_lud_)
- [**breaking**] Invalid return values in Ark.Ok.map_ok/reduce_ok now raise (_lud_)

### 📚 Documentation

- Build plugin listing in README.md with readmix (_lud_)

### ⚙️ Miscellaneous Tasks

- Introduced credo, dialyzer, etc. (_lud_)
- Formatter configuration (_lud_)
- Fix dialyzer configuration (_lud_)
- Configure versioning for mix version (_lud_)
- Fix readme generator (_lud_)

## [0.9.0] - 2023-12-06

### 🚀 Features

- New BinarySearch feature (_lud_)

## [0.5.0] - 2020-09-14

