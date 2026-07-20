# VarDAG v2 — Resumable Computation DAG Specification

Status: draft
Supersedes: `Aitx.Utils.VarDAG` (v1) evaluation semantics

## 1. Purpose and scope

VarDAG v2 is a specification for a **pure, resumable, demand-driven
computation engine**. It describes an algorithm and a state model, not a
library: persistence, scheduling and encoding are pluggable at the edges,
and the core is a deterministic state machine.

Design goals, in priority order:

1. **No wasted computation.** Expensive user code runs at most once per
   computed key, in-run and across pause/resume.
2. **Resumability.** After any single step, the engine state can be
   serialized, stored, and later reloaded to continue exactly where it
   stopped.
3. **Laziness.** A dependency is computed only when something actually
   demands it. Alternatives (fallbacks) are entered only after the previous
   alternative has failed.
4. **Inspectability.** The persisted state is the inspection surface: a
   frontend can read progress, values and failures directly from it.

Non-goals (for this version): intra-DAG parallelism, optional/failable
dependencies, retry policies, speculative evaluation. See §12.

### Vocabulary

- **User code**: any code that uses the engine (registers computations,
  runs the DAG).
- **Node** (or *service*): a named computation registered in the graph.
- **Key**: the identity of one concrete computation: `{ns, service, params}`.
- **Alternative**: one of the ordered candidate implementations of a node.
- **Step**: one named stage inside an alternative.
- **Fact**: a persisted, correctness-bearing record (a value, a binding, or
  a failure marker).

## 2. Computation model: an AND/OR graph

The graph is evaluated as a demand-driven AND/OR graph with short-circuit:

- **Dependencies are AND.** An alternative declares the dependencies it
  needs; all of them must be `ok` before its body runs. Dependencies are
  **hard**: if any declared dependency is failed, the alternative fails
  without its body running.
- **Alternatives are an ordered OR.** A node is a non-empty ordered list of
  alternatives. They are tried strictly in order. Alternative N+1 is
  entered — and its dependency subtree demanded — **only after**
  alternative N has actually failed. No prefetching, no speculation.
- **Evaluation is demand-driven.** Nothing is computed unless it is a
  target of the run or a (transitively) demanded dependency of one.

### Reference scenario

Node `A` has alternatives `A1` (depends on `B`) and `A2` (depends on `C`):

```
run([A])
  → A, alt 1, deps [B]     B missing → schedule B, requeue A
  → B computed
  → A, alt 1               run A1 body → {:error, r}   (attempt fact recorded)
  → A, alt 2, deps [C]     C missing → schedule C      ← C demanded ONLY here
  → C computed
  → A, alt 2               run A2 body → {:ok, v}      (value fact recorded)
```

If `B` is already failed when `A` is evaluated, `A1` fails immediately
(kind `dep_failed`, body never runs) and evaluation advances to `A2`.

If every alternative of a key fails, the key's value is **failed**. There
is no error propagation machinery: a consumer of a failed dependency is
itself failed by the same hard-dependency rule, recursively. The full
failure tree is *re-derived* by walking persisted failure records (§7),
never carried in error objects.

### Scheduling

The engine is a **single-threaded work queue**. One `step` call performs
one unit of progress (compute one attempt, record one binding, record one
failure fact, resolve one dependency scheduling decision). Parallelism at
the application level means running multiple independent DAGs, each
stepped by its own process; the algorithm itself stays sequential and pure.

Invariant reserved for the future: if intra-DAG parallelism is ever added,
**AND dependencies within one alternative may be parallelized; the OR
sequence across alternatives must remain strictly sequential.**

## 3. Keys

A key is `{ns, service, params}`:

- `ns` and `service` are atoms.
- `params` is any **JSON-compatible value**: string, number, boolean,
  `nil`, list of JSON-compatible values, or map from string to
  JSON-compatible value.

`Computing A` is exactly computing `{A, %{}}`: when no params are given,
params default to the empty map. An *explicit* `nil` is a valid params
value and yields a distinct key: `{A, nil} ≠ {A, %{}}`.

### Canonicalization (eager, at key entry)

Params are canonicalized **when a key enters the engine** (declared
dependency, dynamic binding, run target) — in live runs too, not only at
dump time:

- Atom map keys and atom values are converted to strings, recursively.
  `true`, `false` and `nil` are preserved as-is.
- Tuples, structs, pids, refs, functions are **rejected** at key-creation
  time with a clear error.

Consequences:

- Dump/load is **identity** for params: what is stored is exactly what the
  engine uses. Fully frontend-readable and queryable.
- No live/serialized divergence by construction: an implementation
  receives `%{"user_id" => 5, "order" => "asc"}` identically in a fresh
  run and after any number of resumes.
- Free dedup: `%{user_id: 5}` and `%{"user_id" => 5}` canonicalize to the
  same key.

Users may *write* atoms as sugar; implementations only ever *see* the
canonical string form.

Notes:

- Integers and floats are distinct under term equality (`1 ≠ 1.0`); floats
  as identity components are discouraged (precision), though permitted.
- Rich data does not belong in identity. The documented pattern is
  *reduce to reference*: put the rich value in a computed value or a
  binding and reference it by ID in params.

### Serialized form

On dump, `ns` and `service` are serialized as strings. On load they are
revived with `String.to_existing_atom/1` — never `String.to_atom/1` — so a
hostile or stale dump cannot grow the atom table. This is safe because the
graph is rebuilt from code before `load` runs (§9), so every legitimate
atom already exists; a string that fails to convert is precisely a
"key not present in the supplied graph" load error.

## 4. Nodes, alternatives, steps

### Node

A node registration binds `{ns, service}` to an ordered, non-empty list of
alternatives. Registering the same `{ns, service}` twice is an error.

### Alternative

An alternative is `{deps, body}`:

- `deps`: the statically declared dependency keys for this alternative.
  Dependency sets are **per alternative**, not per node — `A1` may depend
  on `B` while `A2` depends on `C`.
- `body`: either a single computation function, or an ordered list of
  **named steps** (see below).

An alternative's declared deps are resolved (scheduled, computed, cached)
before its body runs; by then every declared dep is available in `deps`
(the argument). There is no lazy in-body dependency discovery: v1's
throw-based `inject!` re-run mechanism is **removed**. By the time a body
runs, its `deps` map is fully resolved and dependency access is a pure map
lookup.

### Steps (the AND / let-binding axis)

A multi-step alternative exists for two reasons: to persist intermediate
results at durable boundaries, and to support **dynamic dependencies**
(§5). Rules:

- Steps are **named** with stable keys. Resume addresses "which step is
  next" by name, never by list position.
- Each step's output is written to the value cache under the step's own
  key, so intermediates survive a pause and never recompute.
- Steps communicate **only** through the cache and the bindings map —
  never through closure scope. Local variables are not saved; anything a
  later step needs must be emitted as a fact.
- A single step does **one** of: declare dynamic dependencies (cheap,
  returns bindings) or compute-and-emit a value. Expensive work must live
  in a step that runs *after* its dependencies resolve.

### Computation function signature

Every computation function has the same shape:

```elixir
fn params, deps, context -> result end
```

- `params`: the canonical params of the computed key (a canonical JSON
  value; `%{}` when none were given).
- `deps`: map of resolved dependency values — declared deps plus
  dynamically bound aliases (§5), aliases shadowing on merge.
- `context`: growable ambient map (§6). Most implementations ignore it:
  `fn params, deps, _ -> ... end` is the expected common form.

Return values:

- `{:ok, value}` — success; value is recorded under the computed key.
- `{:error, reason}` — controlled failure; normalized by the engine (§7).
- `{:bind, %{alias => real_key}}` — dynamic dependency declaration, only
  meaningful from a binding step (§5).

Anything else is an error. Raises, throws and exits are caught and
normalized (§7).

## 5. Dynamic dependencies (bindings)

A dependency whose key is computed at runtime (`{:foo, foo_id}` where
`foo_id` comes from earlier work) cannot be declared statically. The
mechanism is a **let-binding of a runtime-computed key to a local alias**:

1. A cheap binding step computes the dynamic key(s) and returns
   `{:bind, %{"invoices" => {:invoices, %{"account_id" => id}}}}`.
2. The engine persists the binding map (a fact), schedules the real keys,
   and once resolved, merges the values into the next step's `deps` under
   the alias names, **shadowing** any same-named entries.
3. The real key's value is cached under its **real identity** — never
   under the alias. Two computations binding the same real key under
   different aliases (`"foo_123"`, `"foo_test"`) share one computation.

State shapes:

```
cache    :: %{real_key => {:ok, value} | :failed}
bindings :: %{step_key => %{alias => real_key}}
```

The cache is canonical and identity-keyed; bindings are a per-node
projection over it. On resume, bindings are **replayed from storage, never
recomputed** — a binding step is therefore allowed to be non-deterministic
without breaking resume.

Illustrative sketch (API shape non-normative):

```elixir
add_node(graph, :report, [
  alternative(deps: [:account], steps: [
    step(:select, fn _params, deps, _ctx ->
      account = deps[:account]
      {:bind, %{
        "invoices" => {:invoices, %{"account_id" => account.id}},
        "usage"    => {:usage,    %{"account_id" => account.id}}
      }}
    end),
    step(:compute, fn _params, deps, _ctx ->
      {:ok, merge(deps["invoices"], deps["usage"])}   # runs exactly once
    end)
  ])
])
```

## 6. Context

`context` is the ambient, growable third argument. It is distinct from
`deps` (pure dependency values) and carries:

- **User globals** supplied at run construction.
- **Engine services**: logger, telemetry hooks, `workflow_info` (run
  metadata), and future helpers — new services attach without a signature
  change.
- **`alternatives`**: injected by the engine before each computation, the
  ordered list of failure records already recorded *for this exact key* —
  empty on a first attempt. This is how alternative N can observe why
  alternatives 1..N-1 failed. Because it is rebuilt from persisted attempt
  records, it is **resume-safe**: a fallback running after a pause sees the
  same history as one running in the same process.

Failure records exposed here contain `kind` and a formatted string (§7),
**not** structured reason terms. Errors exist primarily for humans fixing
and debugging; alternatives should not branch on structured prior-failure
data. A user who needs rich failure semantics defines domain exceptions
with informative messages (optionally an `Exception.blame/2` callback to
enrich formatting).

This mechanism replaces v1's reserved `:error` inject (and its
`NotFallbackError` / `fallback_error` machinery), which is removed.

## 7. Failure model

### Failure records

```
failure_record ::=
  | {:dep_failed, dep_key}                 # a hard dep is failed (points down the tree)
  | {:computation_error, cleaned_error}    # the body itself returned/raised an error
  | {:all_alternatives_failed, [alt_key]}  # node-level: every alternative failed
```

A frontend renders a failed node and follows `dep_key` / `alt_key` links
down to the leaf `:computation_error` records. The persisted state graph
*is* the error tree; no aggregate error object is ever built or
propagated.

### Cleaned errors

Error storage follows Oban's proven model (persisted errors are formatted
strings, since JSON cannot carry arbitrary terms — see Oban issue #562),
with one deliberate improvement: a structured `kind` field with a closed
vocabulary, which is JSON-safe and avoids Oban's need to text-scrape kinds
out of the message.

```
cleaned_error :: %{
  at:    DateTime (ISO-8601 in serialized form),
  kind:  :error | :throw | :exit | :user_term,
  error: binary   # human-readable formatted message (+ stacktrace for crashes)
}
```

### Normalization (engine-side, mandatory)

The engine — never user code — normalizes failures at the boundary:

- `{:error, reason}` returned → `kind: :user_term`. No stacktrace (a
  controlled return is not a crash). Message: `Exception.message(reason)`
  if `reason` is an exception struct, else `inspect(reason)`. The wrap
  itself is the `:user_term` signal — it is the only case that wraps.
- raise → `kind: :error`; caught throw → `:throw`; caught exit → `:exit`.
  Message via `Exception.blame/3` then `Exception.format/3` (message +
  formatted stacktrace), as Oban does.

User code stays trivial: return `{:error, whatever}` and the engine does
the rest.

### Scoping and persistence of failures

- **Failure is scoped to the exact key.** `{A, %{"id" => 123}}` failing on
  `A1` records attempt facts for that key only; `{A, %{"id" => 456}}`
  starts fresh at `A1`. Nothing is remembered "for `A`" in general.
- **Every attempted alternative's outcome is persisted** as an attempt
  fact `{node_key, alt_index} → failure_record`. Some are technically
  re-derivable (an alternative that failed because its dep is
  cached-failed), but body-level failures are not; blanket persistence is
  the simple, safe rule. Skipping derivable records is a later
  optimization, not a semantic requirement.
- There is no retry and no "skip forever" question: within a given state,
  either some alternative succeeded (the key has a value) or all failed
  (the key is failed). If execution stops between `A1`'s failure and
  `A2`'s attempt, resume proceeds directly to `A2`.
- Attempt records double as the inspection/reporting surface ("A1 tried →
  failed with …; A2 tried → failed with …") — there is no separate
  workflow log; the persisted state carries the (cleaned) errors.
- Errors are **not** passed through the value codec (§10); they are
  already-serializable display data.

### Fast-fail pattern (user-side, free)

To avoid running an expensive alternative destined to fail, users split a
dependency into steps whose first step is a cheap validity check (e.g. a
token check). If the check fails, the dependency is failed, and every
alternative that declares it fails via `dep_failed` without running —
evaluation moves directly to the next alternative.

## 8. State model

Durable state consists of **facts** only:

```
state :: %{
  status:   :live | :serialized,       # see §9
  cache:    %{real_key => {:ok, value} | {:failed, failure_record}},
  attempts: %{{node_key, alt_index} => failure_record},
  bindings: %{step_key => %{alias => real_key}},
  queue:    [work_item]                # pending demand, resumable
}
```

Invariants:

- Everything needed for correct continuation lives in this state. Pause /
  resume and frontend inspection read the same bytes.
- The state does **not** contain the graph. Implementations are closures —
  code, not data. The graph is always reconstructed from user code (§9).
- After any single `step/1`, the state is dump-safe (given codec
  discipline, §10).

## 9. Engine API and lifecycle

```
new(graph_definition)                  :: live_state
step(live_state)                       :: {:continue, live_state} | {:done, live_state}
run(live_state)                        :: {:done, live_state}         # loops step/1
dump(live_state)                       :: serializable_data           # → :serialized
load(graph_definition, dumped_data)    :: live_state
```

(Names and exact shapes are non-normative; semantics are.)

- A state has a serialization status: `:live` or `:serialized`.
  `run`/`step` **raise** on a serialized state: the user must `load`
  first.
- `dump` encodes every cached value through the codec (§10) and produces
  pure JSON-compatible data.
- `load` takes the **graph** (rebuilt from code, same registration calls)
  plus the dumped data. It:
  1. validates that every key in the dump exists in the supplied graph,
     failing with a precise diff otherwise (this is where step-key
     stability across deploys becomes a load-time check; storing a
     workflow-definition version alongside the dump is recommended);
  2. revives `ns`/`service` atoms via `String.to_existing_atom/1`;
  3. **eagerly** decodes every cached value through the codec.
- `load` fails **as a whole, loudly** on any decode failure (e.g. a
  referenced record was deleted since dump). It never silently marks
  individual nodes failed — a value that was `ok` at dump must not become
  `failed` at load. Users who want "missing record ⇒ workflow failure"
  make `decode` return a sentinel and check it in a downstream step.

## 10. Value codec

Values computed by user code may be arbitrary terms (Ecto structs, etc.).
Persistence is pluggable; JSON is the baseline target. The bridge is an
optional, user-provided **codec**: a module or an `{encode, decode}` pair
of functions.

- **Live form is canonical.** Steps always produce and consume rich
  terms. The codec runs only at the dump/load boundary: `dump` encodes
  every cached value; `load` decodes every one.
- **Codec law:** `decode(encode(v))` must be semantically equivalent to
  `v`. This is what preserves *representation consistency*: a consumer
  sees the same kind of value whether or not a pause happened between
  production and consumption.
- `encode` output must itself be JSON-round-trip-stable (string-keyed
  maps, JSON scalars). A dev/test mode check should round-trip every
  encoded value through the persistence format and raise on mismatch;
  production skips the check.
- **No codec configured ⇒ identity codec.** Arbitrary terms flow freely
  and fully in-memory runs need no ceremony — the user merely loses the
  right to `dump`; the engine raises a clear error if asked.
- `:erlang.term_to_binary` is rejected as a baseline: opaque to frontends,
  unsafe to decode from untrusted storage, and brittle across struct
  upgrades.

Documented codec pattern — *reduce to reference*:

```elixir
encode: %Cart{id: id}                  -> %{"type" => "cart", "cart_id" => id}
decode: %{"type" => "cart", ...} = m  -> CartStore.fetch!(m["cart_id"])
```

The refetch happens **once at load**, not in every downstream step.
Freshness caveat (state explicitly in user docs): a decoded value reflects
the *current* external state, not a dumped-time snapshot; resume is not
bit-for-bit replay. Users needing snapshot semantics encode the full data
instead of a reference.

## 11. Resume semantics (summary)

Resume is: rebuild graph from code → `load` (validate, revive, decode) →
`run`. Then:

- Cached `ok` values are used as-is; their computations never re-run.
- Recorded attempt failures are honored: a key whose `A1` attempt is
  recorded failed proceeds directly to `A2`.
- Persisted bindings are replayed, not recomputed.
- `context.alternatives` is rebuilt from attempt records, so fallbacks see
  the same failure history as in an uninterrupted run.
- Params, being canonical on both sides of the boundary, are byte-stable.

## 12. Non-goals and future work

- **Intra-DAG parallelism** — permitted later for AND deps within one
  alternative only; OR order is inviolable (§2).
- **Optional / failable dependencies** — all deps are hard in this
  version; recovery is expressed exclusively through alternatives.
- **Retry / invalidation policies** — a failed key is failed within a
  state; re-running from scratch is the only retry. Classifying transient
  vs permanent failures is future work.
- **Lazy decode at load** — eager decode is the baseline; per-access
  decode is a possible optimization if load cost becomes significant.
- **Eager/speculative prefetch** — could become an explicit per-dep
  opt-in; never automatic.
- **Skipping derivable attempt records** — storage optimization only.

## 13. Differences from v1 (removal list)

- Throw-based lazy `inject!` discovery and the re-run loop: **removed**.
  Dependencies are declared (statically or via bindings); `deps` access is
  a pure lookup.
- Reserved `:error` inject, `NotFallbackError`, `fallback_error` plumbing:
  **removed**, replaced by `context.alternatives`.
- `DependencyError` chain building (`cause`/`from` unwrapping): **removed**;
  failure trees are re-derived from persisted records.
- Arity-based impl dispatch (`fun/1` vs `fun/2`) and the
  "does not support parameters" error: **removed**; single `(params, deps,
  context)` signature, params default `%{}`.
- Node-level single dep list: replaced by **per-alternative** dep sets.
