# Changelog

All notable changes to this project will be documented in this file.

## [0.15.0] - 2026-11-10

This release adds `Ark.Workflow`, which computes values from rules with
ordered fallback alternatives and a state that persists across runs.

A rule provides a value under a name and lists alternatives to compute it. Each
alternative declares its dependencies on other rules and a body function, and
when an alternative fails the next one is tried. Values and failures are
recorded, so a key is computed once and the whole state can be dumped to
JSON-compatible data and loaded back to resume after a restart or a deploy.

```elixir
import Ark.Workflow, only: [rule: 1, rule: 2, alt: 2]

wf =
  Ark.Workflow.new()
  |> Ark.Workflow.add_rule(:transcript, rule(&MyApp.Audio.transcribe/3))
  |> Ark.Workflow.add_rule(:summary,
    rule(
      cloud: alt([:transcript], &MyApp.AI.summarize_with_cloud_model/3),
      local: alt([:transcript], &MyApp.AI.summarize_with_local_model/3)
    )
  )

key = {:summary, %{meeting_id: 42}}
{:ok, wf} = Ark.Workflow.run(wf, [key])
{:ok, summary} = Ark.Workflow.fetch(wf, key)
```

When the cloud API call fails, the local model takes over without
transcribing the meeting again, and the recorded state can be stored and
resumed later with the transcript already in hand.

- Keys carry params, so one rule provides many values, and bodies receive the
  params of the key they compute.
- Dependencies are written as keys, alias maps, or dependency functions that
  pick the keys to demand at run time from the params and the values computed
  so far, which also expresses conditional dependencies.
- Namespaces let packages of rules join a workflow with private rules and an
  entry point registered in the application's namespace.
- `attempts/2` and `blame/2` read the failure records down to the root cause,
  and `clear_failure/2` makes the next run try a failed key again.
- `dump/1` and `load/2` persist the state, with optional `:dump` and `:load`
  callbacks on rules whose values hold terms that cannot be serialized as they
  are.
- A call wrapper given to `new/1` or `run/3` wraps every call to user code, for
  logging, telemetry or timeouts.

This release also adds `Ark.Opts`, a small validator for the options of a
function. `validate!/4` calls a callback for each given option and merges the
valid values over a map of defaults, so a function reads its options with a
single pattern match. The module ships validators for the common types, along
with `any_of/2`, `all_of/2`, `list_of/2`, `member_of/2` and `nullable/2` to
combine them. `validate/4` returns an `Ark.Opts.Error` instead of raising it,
with the path to the option, the given value and a reason that reads in the
error message.

```elixir
%{timeout: timeout, retries: retries} =
  Ark.Opts.validate!(opts, %{timeout: 5000, retries: 3}, fn
    :timeout, value -> Ark.Opts.pos_integer(value)
    :retries, value -> Ark.Opts.non_neg_integer(value)
    _, _ -> :unknown
  end)
```

`Ark.EctoCursor` and `Ark.Workflow` validate their options with it, and now
raise an `Ark.Opts.Error` for an invalid option.


### 🚀 Features

- Add Ark.Opts, an ad-hoc options validator
- Accept maps as options in Ark.Opts.validate
- Add Ark.Opts.all_of validator
- Return Ark.Opts.Error with paths, reasons and required options
- [**breaking**] Raise Ark.Opts.Error for invalid Ark.EctoCursor options
- Add Ark.Workflow, rule-based computation with fallback alternatives

### 🐛 Bug Fixes

- Ark.Error now always renders exceptions with format_banner for private audience
- Added missing typespecs to Ark.Workflow

### 🚜 Refactor

- Validate Ark.EctoCursor options with Ark.Opts

### ⚙️ Miscellaneous Tasks

- Sobelow skip on workflow codec with :safe option

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

- Add new Ark.EctoCursor tool

### ⚙️ Miscellaneous Tasks

- Setup library release process

## [0.13.2] - 2026-09-02

### 🚀 Features

- Support private and public audiences in Ark.Error formatters

### 📚 Documentation

- Added missing docs troughout codebase

## [0.13.1] - 2026-05-29

### ⚙️ Miscellaneous Tasks

- Fix compilation warnings for Elixir 1.20

## [0.13.0] - 2026-05-13

### 🚀 Features

- Added Ark.Timeout utility
- Removed unused PubSub utility
- Paginator will now raise page errors as dedicated exceptions

## [0.12.0] - 2026-05-04

### 🚀 Features

- Added the Ark.Paginator module

## [0.11.0] - 2026-04-21

### 🚀 Features

- Added Ark.Retry for macro-free retry utilities

## [0.10.1] - 2026-03-19

### 🚀 Features

- Added Ark.Ok.flat_map_ok/2

### 📚 Documentation

- Added examples for complex 'ok' functions

## [0.10.0] - 2026-03-19

### 🚀 Features

- [**breaking**] Removed the drip module (extracted as the kota library)
- [**breaking**] Removed the deprecated Ark.Ok.uok function
- [**breaking**] Removed the Ark.PipeIn module
- [**breaking**] Invalid return values in Ark.Ok.map_ok/reduce_ok now raise

### 📚 Documentation

- Build plugin listing in README.md with readmix

### ⚙️ Miscellaneous Tasks

- Introduced credo, dialyzer, etc.
- Formatter configuration
- Fix dialyzer configuration
- Configure versioning for mix version
- Fix readme generator

## [0.9.0] - 2023-12-06

### 🚀 Features

- New BinarySearch feature

## [0.5.0] - 2020-09-14

