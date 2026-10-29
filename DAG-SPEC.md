# Ark.Workflow — Resumable Computation Engine Specification

## 1. Purpose and scope

Ark.Workflow is a specification for a **resumable, demand-driven
computation engine**. It describes an algorithm and its API, not a
library: persistence, scheduling and encoding are at the edges.

Design goals, in priority order:

1. **No recomputation.** A key with a recorded value is not computed
   again, in the same run or after a resume.
2. **Resumability.** After any operation, the engine state can be
   serialized, stored, and later reloaded to continue exactly where it
   stopped.
3. **Laziness.** A dependency is computed only when something actually
   demands it. Alternatives (fallbacks) are entered only after the previous
   alternative has failed.
4. **Inspectability.** The state is the inspection surface: a frontend
   can read progress, values and failures from it.

Non-goals (for this version): intra-DAG parallelism, optional/failable
dependencies, retry policies, speculative evaluation. See §12.

### Vocabulary

- **User code**: any code that uses the engine (registers computations,
  runs the DAG).
- **Rule**: how to compute keys: an ordered list of alternatives,
  registered in the graph under `{ns, name}`.
- **Key**: the identity of one concrete computation: `{ns, name, params}`,
  computed by the rule `{ns, name}`.
- **Alternative**: one named candidate of a rule: a dependency list and a
  body.
- **Dependency function**: an entry of an alternative's dependency list
  that computes dependency keys at runtime (§5).
- **Fact**: a persisted, correctness-bearing record (a value or a failure
  marker).
- **Operation**: anything that changes the state and yields a new
  persistable state (§2).
- **State**: the recorded facts.
- **Workflow**: the value user code handles: the rules of the graph plus
  the state (§9). Only the state is dumped.
- **Graph error**: the code is wrong, whatever the data (§9). Distinct
  from a failure, which is recorded.

## 2. Computation model: an AND/OR graph

The graph is evaluated as a demand-driven AND/OR graph with short-circuit:

- **Dependencies are AND.** An alternative declares the dependencies it
  needs; all of them must be `ok` before its body runs. Dependencies are
  **hard**: if any declared dependency is failed, the alternative fails
  without its body running.
- **Dependencies are resolved left to right, with short-circuit.** A
  dependency is demanded only once every dependency to its left is `ok`.
  The first failed dependency fails the alternative; dependencies to its
  right are never demanded.
- **Alternatives are an ordered OR.** A rule is a non-empty ordered list of
  alternatives. They are tried strictly in order. Alternative N+1 is
  entered — and its dependency subtree demanded — **only after**
  alternative N has actually failed. No prefetching, no speculation.
- **Evaluation is demand-driven.** Nothing is computed unless it is a
  target of the run or a (transitively) demanded dependency of one.

### Reference scenario

Rule `A` has alternatives `A1` (depends on `B`) and `A2` (depends on `C`):

```
run([A])
  → A, alt 1, deps [B]     B missing → pause A, push B
  → B computed
  → A, alt 1               run A1 body → {:error, r}   (attempt fact recorded)
  → A, alt 2, deps [C]     C missing → pause A, push C ← C demanded ONLY here
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

The engine is a **single-threaded demand stack**. The stack holds the
chain of computations in progress: when a computation demands a
dependency that has no value and is not failed, the computation is
paused, the dependency is pushed on top and computed first. Each paused
computation waits on exactly one dependency, so every entry of the stack
is an ancestor of the entry above it.

Targets are demanded the same way, one at a time, in order, with the
same short-circuit: the next target is pushed only once the previous one
has a value, and the first failed target stops the run (§9).

The engine progresses by **operations**: an operation is anything that
changes the state and yields a new persistable state (compute one
attempt, record one failure fact, push one demanded key). The number of
operations a run takes is not part of the contract; only the
persistability of every returned state is. Parallelism at the
application level means running multiple independent DAGs, each run
by its own process; the algorithm itself stays sequential and pure.
Parallel computation within a DAG can be considered once a prototype
exists (§12).

## 3. Keys

A key is `{ns, name, params}`:

- `ns` and `name` are atoms. `{ns, name}` identifies the rule that
  computes the key.
- `params` is a map, structs included. Its keys and values are any term
  (string keys are fine, structs are fine), except pids, ports,
  references and functions, at any depth. Invalid params are rejected
  like a string identity (§3, identities): by `add_rule` for static
  dependencies, and as a graph error returned by `run` for targets and
  for keys returned by dependency functions (§5).

A key is written in one of three forms: `name`, `{name, params}` or
`{ns, name, params}`. A bare rule name is a key with empty params:
computing `:account` is exactly computing `{:account, %{}}`.

### Default namespace

A key written without a namespace is in the namespace of its context:

- inside a rule (dependencies, keys returned by dependency functions),
  the namespace of that rule (§4);
- for a rule identity given to `add_rule` without namespace, the current
  namespace of the graph: `:default`, or the namespace set by `add_ns`
  for the duration of its callback (§9);
- outside any rule and outside the graph (`run` targets, `fetch`,
  `clear_failure`), the namespace `:default`.

Messages print keys of `:default` without their namespace. Functions
that hand keys to user code, such as the `clear_failure` predicate (§9),
always give the full `{ns, name, params}` form, `:default` included.

### Runtime form

Params are used at runtime **as written** by the code that demands the
key. A body receives `%{user_id: 5, order: :asc}` and pattern-matches on
it, in a fresh run and after any number of resumes: the params handed to
a body always come from code (run targets, static dependencies, keys
returned by dependency functions), never from a dump.

Two keys are the same key when they are identical terms, compared as map
keys compare. Consequences:

- `%{user_id: 5}` and `%{"user_id" => 5}` are two different keys,
  computed separately. Code that writes params in one consistent form
  computes each key once.
- Integers and floats are distinct (`1` and `1.0` differ); floats as
  identity components are discouraged (precision), though permitted.
- Rich data does not belong in identity: put the rich value in a
  computed value and reference it by ID in params.
- A struct in params decodes with the fields it had at dump time (§10).
  Once its definition changes, keys built by code no longer match the
  recorded ones and are computed again. Changing a struct used in
  persisted params is discouraged.

### Identities and the graph

Code addresses are atoms: namespaces (`__MODULE__`), rule names
(`deps: [:account]`) and alternative names (§4). The graph maps each
`{ns, name}` to its rule. A string where code expects an address is not
an address, and is never looked up: registering a rule or an alternative
under a string, or declaring a static dependency with a string identity,
is rejected by `add_rule`; a target, or a key returned by a dependency
function, with a string identity is an invalid key (§5, §9).

`nil`, `true` and `false` are atoms but never addresses: they are almost
always a mistake. `add_rule` rejects them as a namespace, a rule name, an
alternative name, and in the identity of a static dependency. A
dependency function returning one of them returns an invalid key (§5).

Dumps store identities and alternative names by their string form (§8):
`:account` is `"account"`, `MyApp.Billing` is `"Elixir.MyApp.Billing"`.
Load matches each recorded identity and alternative name against the
rules of the workflow it is given, by string form. Identities with no
rule in that workflow are orphaned records (§7), also when a rule with
that identity is added after the load (§9). Load never creates atoms
(§10), so a hostile or stale dump cannot grow the atom table.

### Graph before state

The graph decides whether a key is valid; the state only records whether
it was computed. When a key enters the engine, its rule is looked up in
the graph before any recorded fact: a key with no rule is a graph error
(§5), even when the state holds records for it. A recorded value never
makes a key valid.

A rule removed from the code and later registered again under the same
identity finds its records again.

## 4. Rules and alternatives

### Rule

A rule registration binds an identity `{ns, name}` to a rule
implementation (§9):

```elixir
%{
  alts: [live: %{deps: [...], body: &build/3}, snapshot: %{deps: [...], body: &unwrap/3}],
  dump: &Report.to_map/1,
  load: &Report.from_map/1
}
```

- `alts`: the ordered, non-empty list of named alternatives. Mandatory.
- `dump` and `load`: how the rule's values are stored (§10). Optional.

Registering the same `{ns, name}` twice is an error.

The identity is not part of the implementation: one implementation can
be registered under several identities. Each identity is a distinct
rule, whose keys are computed and recorded separately. Dependency keys
written without namespace resolve in the namespace of the rule (§3), so
an implementation registered in two namespaces may depend on different
rules in each.

### Alternative names

`alts` is a keyword list: each alternative is bound to its name, and the
list order is the order in which alternatives are tried. Names are atoms
(§3), unique within the rule. No name has a special meaning: an
alternative named `:default` is tried in its list position like any
other.

Alternatives are identified by name, never by position. Recorded attempts
(§7) are keyed by alternative name, so they stay attached to their
alternative when a deploy reorders the list. The order of the current
graph decides which alternative is tried next: after a reorder, an
alternative may run after one that used to come later.

### Alternative

An alternative is a map `%{deps: deps, body: body}`, both mandatory:

- `deps`: the ordered dependency list of this alternative. Each entry is
  a static dependency key, an alias map of static keys, or a dependency
  function (§5), mixed freely. Dependency lists are **per alternative**, not per rule — `A1`
  may depend on `B` while `A2` depends on `C`.
- `body`: a single computation function (see the signature below).

An alternative's deps are resolved (scheduled, computed, recorded) left to
right before its body runs; by then every dep is available in `deps` (the
argument). There is no lazy in-body dependency discovery: v1's
throw-based `inject!` re-run mechanism is **removed**. By the time a body
runs, its `deps` map is fully resolved and dependency access is a pure map
lookup.

Intermediate results that must survive a pause are expressed as separate
rules: a long computation split in two is a rule depending on another
rule. The intermediate gets its own key, and is shared by every consumer
of that key. Likewise, data fetched once and used by several alternatives
is a rule they all depend on: a later alternative reuses the value
instead of fetching it again.

### Dependency keys and the `deps` map

A dependency key is written in one of three forms:

- `name`: rule `name` in the namespace of the demanding rule, with params
  `%{}`;
- `{name, params}`: rule `name` in the namespace of the demanding rule;
- `{ns, name, params}`: any rule. A rule of another namespace without
  params is written `{ns, name, %{}}`. A forgotten params in
  `{ns, name}` reads as `{name, params}` with an atom as params, and is
  rejected as invalid params (§3).

An **alias map** names dependencies: each value is a dependency key,
exposed in `deps` under its alias. In a static dependency list, it gives
readable names to keys whose params are known when the graph is built,
e.g. from a closure:

```elixir
deps: [%{account: {:account, %{user_id: user_id}}}, fn _p, deps, _ -> ... end]
```

An alias is any term; it exists only in the `deps` map and is never
persisted. The keys of one alias map are demanded in alias order, with an
ordered map iterator (`:maps.iterator(map, :ordered)`), so runs behave the
same regardless of map size. When another order matters, the map is
split: separate entries in a static list, or successive dependency
functions.

`deps` is a plain map, so bodies can pattern-match on it. A dependency
without an alias is exposed under the term written by the code that
demands it: `:account` is exposed as `:account`, `{:account, %{}}` as
`{:account, %{}}`, and `{__MODULE__, :account, %{}}` as
`{__MODULE__, :account, %{}}`. Code that builds `{name, params}` finds
the value under that same term, whether `params` is empty or not.

The same key listed more than once in one alternative, in any form or
under the same alias, is accepted and demanded once. Listed in several
forms, it is exposed under each of them: `[:a, {:a, %{}}]` exposes the
value of `:a` under `:a` and `{:a, %{}}`. Two **different** keys of one
alternative exposed under the same `deps` key are an error, including an
alias that shadows the written form of another dependency.
The reason of the graph error is `{:shadowing, exposure, exposure}`
(§9), so its message can call out the shadowing. It is rejected by `add_rule`, or is a graph error when a
dependency function returns it (§5). Each alternative has its own `deps`
map: two alternatives of one rule may use the same alias for different
keys.

### Computation function signature

Bodies and dependency functions have the same shape, so the engine calls
all user code the same way:

```elixir
fn params, deps, context -> result end
```

- `params`: the params of the computed key, as written by the code that
  demanded it (`%{}` when none were given).
- `deps`: map of resolved dependency values. For a body, every dependency
  of the alternative; for a dependency function, the dependencies to its
  left (§5).
- `context`: the map given by user code to the run (§6). Most bodies
  ignore it:
  `fn params, deps, _ -> ... end` is the expected common form.

A body or a dependency function is an anonymous function, a remote
capture (`&Module.function/3`) or a `{module, function, extra_args}`
tuple. The tuple is called with the engine's arguments prepended:
`apply(module, function, [params, deps, context | extra_args])`.

A graph whose user code is given only as tuples or remote captures holds
no anonymous function: it can be built at compile time and stored in a
module attribute. Its tuples and captures may name functions of the
module being compiled, which do not exist yet when the rule is
registered. So `add_rule` checks arities only: an anonymous function or
a capture of the wrong arity (`Function.info/1` gives the arity of a
capture even when its function does not exist) is rejected, and a tuple
has the right arity by construction. Whether the function exists is
never checked: calling one that does not exist raises
`UndefinedFunctionError`, which fails the alternative like any raise
(§7).

In a dependency list, a tuple dependency function `{atom, atom, list}`
and a key `{ns, name, params}` (`{atom, atom, map}`) are told apart by
their last element. The two look alike to a reader, so user
documentation discourages mixing them in one list.

Body return values:

- `{:ok, value}` — success; value is recorded under the computed key.
- `{:error, reason}` — controlled failure; normalized by the engine (§7).

Anything else fails the alternative with kind `:bad_return`. Raises,
throws and exits are caught and normalized (§7). What a body returns is
the outcome of its key: it is always recorded. Dependency function return
values are described in §5.

## 5. Dynamic dependencies (dependency functions)

A dependency whose key is computed at runtime cannot be declared
statically. Two cases are common:

- the key derives from the computed key's own params:
  `{:report, %{account_id: 1}}` needs `{:account, %{id: 1}}`;
- the key derives from another dependency's value: rule `:user`
  produced a user, and the computation now needs
  `{:account, %{user_id: user.id}}`.

Both are expressed with a **dependency function** placed in the
alternative's dependency list:

```elixir
deps: [:a, :b, fn params, deps, context -> ... end, :c, :d]
```

### Resolution

- The list is resolved left to right (§2). A dependency function is called
  only once every dependency to its left is `ok`; it receives the computed
  key's params, those resolved dependencies, and the context.
- The keys it returns are demanded next, before the entries to its right.

### Return values

A dependency function returns one of:

- an **alias map** (§4) `%{account: {:account, %{user_id: user.id}}}`:
  each value is exposed in `deps` under its alias;
- a **list of keys**, e.g. `[:settings, {:account, %{id: id}}]`;
- a **single key**, e.g. `:settings`. Returning an atom reads best for
  dependencies without params.

Keys returned without an alias are exposed in `deps` under the term
the function returned (§4). An empty map or empty list
demands nothing: a dependency function can make a dependency conditional.

A value is recorded under its **real identity** — never under an alias. Two
computations demanding the same real key under different aliases
(`"foo_123"`, `"foo_test"`) share one computation.

### Dependency functions are not recorded

The keys a dependency function returns are not persisted. The function is
called again whenever the engine resolves the alternative's dependencies:
several times in one run (each time the computed key resumes after a
demanded dependency is computed), and again after a resume. It is not
called at all once the key has a value. The engine may keep the returned
keys at runtime to avoid repeated calls; this is not guaranteed.

The documented contract: a dependency function **computes keys, not
values**. It is cheap, and its result depends only on its arguments,
typically turning `%{user: user}` into
`{:account, %{user_id: user.id}}`. The engine always follows the keys
returned by the latest call. A non-deterministic function costs
computation (newly returned keys are computed, values for keys no longer
returned stay unused in the state) but never correctness.

A dependency function works on correct data and has no failure return
value. When a value cannot yield a valid key (e.g. a system user without
an account), the key producing that value is the one that fails.

The failure tree does not need these records: a dependency failure
records the real key it points to (§7).

Since dependency functions see values, they can be abused to run
computations, turning `deps` into a computation list. This trade-off is
accepted for simplicity.

### Failures

What a dependency function **does** is user code; what it **returns** is
graph structure.

- A dependency function that raises, throws or exits fails the
  alternative with a `:computation_error`, and the next alternative is
  entered. Raising is the way to fail an alternative from a dependency
  function.
- A return value that is not a valid dependency is a **graph error**,
  not a failure: the code is wrong. `run` stops and returns the error
  with the workflow, holding every fact recorded so far (§9). Nothing is
  recorded for the key whose dependency function returned it: once a
  deploy fixes the code, the next run continues from there. The error
  carries what is needed to debug the code: the returned value, and the
  key and alternative whose dependency function returned it. Its reason
  is `{:bad_return, :deps, fun, retval, key_reason}` (§9), where
  `key_reason` tells what is wrong with the returned value:
  - `{:invalid_key, given}`, for a term that is not a key: `nil`, `true`
    and `false` (atoms, but reported as invalid keys rather than as keys
    with no rule), a key with a string `ns` or `name`, a string, a
    number, a function, a nested list, a list holding an alias map, or
    any other term that is not a key, a list of keys or an alias map;
  - `{:invalid_params, given}`, for a key with invalid params (§3);
  - `{:unknown_rule, key}`, for a key with no registered rule, even when
    the state holds records for it (§3);
  - `{:shadowing, exposure, exposure}`, for a key exposed under the same
    `deps` key as a different key of the alternative (§4).

  `{:ok, keys}` reads as a key of rule `:ok`: invalid params for a list
  or an atom, an unknown rule for a map. Whatever its key reason, its
  message hints that dependency functions return keys directly.
- A returned key naming an existing rule with params that match no
  data (e.g. `{:account, %{id: id}}` for a deleted account) is a
  normal dependency: the key is computed, fails, and the alternative fails
  via `dep_failed`.

Static dependencies with a string identity or invalid params are
rejected by `add_rule`. Rules may be registered in any order, so a
static dependency naming a rule that is not registered is a graph error
returned by `run` before any user code is called, with reason
`{:unknown_rule, key}`. Keys returned by
dependency functions **cannot be checked before the function runs**.

### Cycles

For the same reason, a cycle can only be detected at runtime: `:a`
demands `:b`, and a dependency function of `:b` returns `:a`. A cycle is
a demand for a key that is **in progress**, i.e. already on the demand
stack (§2), as an ancestor of the demanding computation. Like a missing
rule, a cycle means the graph is not well thought out: it is a graph
error, and `run` stops as above. Its reason is `{:cycle, key, stack}`
(§9): the demanded key, and the demand stack that leads back to it.

### Example

```elixir
add_rule(graph, :report, %{
  alts: [
    default: %{
      deps: [
        :account,
        fn _params, deps, _ctx ->
          account = deps[:account]

          %{
            invoices: {:invoices, %{account_id: account.id}},
            usage: {:usage, %{account_id: account.id}}
          }
        end
      ],
      body: fn _params, deps, _ctx ->
        {:ok, merge(deps[:invoices], deps[:usage])}
      end
    }
  ]
})
```

## 6. Context

`context` is the third argument: a map given by user code to the run,
passed as-is to every body and dependency function. Its content is up to
user code; the engine adds nothing to it. It is distinct from `deps`
(pure dependency values) and is never persisted. Logging and telemetry
are middlewares (§9), and a middleware can change the context seen by
user code (`update_args`).

An alternative does not see why previous alternatives failed. Data that
several alternatives use is a separate rule they depend on (§4).

## 7. Failure model

### Failure records

```
failure_record ::=
  | {:dep_failed, dep_key}                 # a hard dep is failed (points down the tree)
  | {:computation_error, cleaned_error}    # the body, a dependency function or a middleware failed
  | {:all_alternatives_failed, [alt_name]} # key-level: every alternative failed
```

A frontend renders a failed key and follows `dep_key` links and the
`{key, alt_name}` attempt records down to the leaf `:computation_error`
records. The persisted state graph
*is* the error tree; no aggregate error object is ever built or
propagated. Each record points one level down: a consumer of `:b`, itself
failed because of `:c`, records `{:dep_failed, :b}` only. The error that
`run` returns for a failed target is derived from the records and
describes the whole tree down to the leaves (§9).

All failure records share one shape, whatever user code produced them:
a body or a dependency function, an `{:error, _}` return, a bad return,
a raise, a throw or an exit. Only the `kind` of the cleaned error tells
them apart.

### Orphaned records

A record may reference an identity the graph no longer has: a key whose
rule was removed between deploys, or an alternative removed from its
rule. Such records stay in the state as plain data, for inspection.
They take no part in evaluation (§3, graph before state). Load never
creates atoms (§3), so after a load, an identity or alternative name with
no counterpart in the workflow stays a string, also in the names listed
by `{:all_alternatives_failed, names}`.

A key with no registered rule demanded at runtime is not a failure
record: `run` returns a graph error (§5).

### Cleaned errors

Error storage follows Oban's model (persisted errors are formatted
strings, since JSON cannot carry arbitrary terms — see Oban issue #562),
plus a structured `kind` field with a closed vocabulary, so kinds are not
scraped out of the message. At runtime, the cleaned error also holds the
original term, so user code can match on the cause of a failure.

```
cleaned_error :: %{
  at:      DateTime (ISO-8601 in serialized form),
  kind:    :error | :throw | :exit | :user_term | :bad_return,
  message: binary,      # human-readable formatted message (+ stacktrace for crashes)
  reason:  term | nil   # the original term, runtime only
}
```

`message` is computed the same way for every kind (normalization,
below). `reason` is the original term:

| `kind`        | `reason`                                                     |
|---------------|--------------------------------------------------------------|
| `:user_term`  | the `reason` of the returned `{:error, reason}`              |
| `:error`      | the exception struct, normalized with `Exception.normalize/3` as for the message; no stacktrace, the message holds it |
| `:throw`      | the thrown value                                             |
| `:exit`       | the exit reason                                              |
| `:bad_return` | the returned value                                           |

`reason` is **runtime only**: it is held for failures recorded in the
current workflow value, never encoded, and `nil` after a load. The
generic encoder (§10) never sees it, so a reason holding pids, functions
or references does not prevent a dump.

### Normalization (engine-side, mandatory)

The engine — never user code — normalizes failures at the boundary:

- `{:error, reason}` returned → `kind: :user_term`. No stacktrace (a
  controlled return is not a crash). Message: `Exception.message(reason)`
  if `reason` is an exception struct, else `inspect(reason)`. The wrap
  itself is the `:user_term` signal — it is the only case that wraps.
- any other return from a body, or from a middleware wrapping a body →
  `kind: :bad_return`. No stacktrace. The message holds the returned
  value, through `inspect`.
- raise → `kind: :error`; caught throw → `:throw`; caught exit → `:exit`.
  Message via `Exception.blame/3` then `Exception.format/3` (message +
  formatted stacktrace), as Oban does.

User code stays trivial: return `{:error, whatever}` and the engine does
the rest. Errors are for humans fixing and debugging; a user who needs
rich failure messages defines domain exceptions (optionally with a
`blame/2` callback to enrich formatting).

### Scoping and persistence of failures

- **Failure is scoped to the exact key.** `{A, %{id: 123}}` failing on
  `A1` records attempt facts for that key only; `{A, %{id: 456}}`
  starts fresh at `A1`. Nothing is remembered "for `A`" in general.
- **Every attempted alternative's outcome is persisted** as an attempt
  fact `{key, alt_name} → failure_record`. Some are technically
  re-derivable (an alternative that failed because its dep is
  recorded as failed), but body-level failures are not; blanket persistence is
  the simple, safe rule. Skipping derivable records is a later
  optimization, not a semantic requirement.
- There is no retry and no "skip forever" question: within a given state,
  either some alternative succeeded (the key has a value) or all failed
  (the key is failed). If execution stops between `A1`'s failure and
  `A2`'s attempt, resume proceeds directly to `A2`.
- **A failed key stays failed**, also when a deploy adds alternatives to
  its rule. To evaluate it again, user code clears its failure (§9)
  before running.
- **A key with a value keeps it**, also when a deploy adds, removes or
  reorders alternatives: its alternatives are never called again.
- **Attempt records of removed alternatives remain** in the state, for
  inspection. They no longer take part in evaluation.
- Attempt records double as the inspection/reporting surface ("A1 tried →
  failed with …; A2 tried → failed with …") — there is no separate
  workflow log; the persisted state carries the (cleaned) errors.
- Failure records are display data that the engine stores as JSON
  directly, without the `reason` of their cleaned errors. A rule's
  `:dump` and `:load` (§10) apply to its values only.

### Fast-fail pattern (user-side, free)

To avoid running an expensive alternative destined to fail, users make a
cheap validity check (e.g. a token check) a separate rule, and list it
before the expensive dependencies: `deps: [:token_check, :expensive]`.
Since deps resolve left to right with short-circuit (§2), a failed check
fails the alternative via `dep_failed` before `:expensive` is demanded —
evaluation moves directly to the next alternative.

## 8. State model

The shapes in this section are suggestions. The contract is the API
(§9): tests validate its inputs and outputs, and behaviours through
mocks, never the internal shape of the state.

A workflow (§9) holds the rules of the graph and the state. The state,
the only durable part, consists of **facts** only:

```
state :: %{
  results:  %{real_key => {:ok, value} | {:failed, failure_record}},
  attempts: %{{key, alt_name} => failure_record}
}
```

### Dumped form

The dump format is undefined for now: it depends on the state, which
each implementation chooses. Tests validate dumps by round trip only:
dump, load, run again, and check which user code is called and which
values come out. The format below is a suggestion.

A dump is a list of entries, one per key with recorded facts. A key is a
JSON object with `ns` and `name` as strings (§3) and params through the
generic encoder (§10); the key's attempts are nested under alternative
names, as strings, which can be JSON object keys:

```json
{
  "entries": [
    {
      "key": {"ns": "Elixir.MyApp", "name": "report",
              "params": {"json": 1, "data": {"account_id": 1}}},
      "result": {"ok": {"json": 1, "data": {"total": 120}}},
      "attempts": {"primary": {"computation_error": {
        "at": "2026-01-01T00:00:00Z", "kind": "user_term", "message": ":timeout"
      }}}
    },
    {
      "key": {"ns": "Elixir.MyApp", "name": "account",
              "params": {"json": 0, "data": "g3QAAAABdwJpZGEB"}},
      "result": {"ok": {"json": 0, "data": "..."}}
    }
  ]
}
```

(Field names are illustrative.) `result` is absent for a key with
attempts but no outcome yet. A cleaned error is dumped with its `at`,
`kind` and `message`, never its `reason` (§7). Failure records reference other keys with
the same key object. A dump holding two entries for the same key is
invalid. Load decodes the keys and rebuilds the live maps in one pass.

Storage that wants one row per key can derive a key ID by hashing the
key's encoded form, with sorted map keys for the JSON parts (e.g.
SHA-256). The engine may provide this as a helper. ETF bytes are stable
within one OTP major release (§10), so an ID derived from ETF params may
change after an OTP major upgrade. The engine itself matches keys by
term equality after decoding.

### Runtime-only data

A workflow also carries **runtime-only** data that `dump` drops: the
rules, the targets of the current run, the demand stack (§2) and the
`reason` of cleaned errors (§7). None is needed in the dump for correct
continuation: the rules come from code, after a load the stack is rebuilt
by demanding the targets again, which the recorded facts make cheap, and
a reason is never read by the engine.

Invariants:

- Everything needed for correct continuation, besides the rules, lives in
  the state. Pause / resume and frontend inspection read the same bytes.
- The dump does **not** contain the graph. Rules may be closures — code,
  not data. They are always given by user code: registered again, or
  stored in a module attribute (§4).
- An invalid graph structure is a graph error, never recorded (§5): a
  dump can be loaded into a workflow whose rules were fixed since, and
  continues from there.
- After any operation, the state is dump-safe (§10).

## 9. Engine API and lifecycle

```
new(opts)                              :: workflow                   # e.g. dump check (§10)
add_rule(workflow, identity, rule)     :: workflow                   # identity: name | {ns, name}
add_ns(workflow, ns, callback)         :: workflow
run(workflow, targets, opts)           :: {:ok, workflow} | {:error, error, workflow}
dump(workflow)                         :: {:ok, data} | {:error, codec_error}
load(workflow, data)                   :: {:ok, workflow} | {:error, codec_error}
clear_failure(workflow, key | pred)    :: {:ok, workflow} | {:error, :not_failed | graph_error}
fetch(workflow, key)                   :: {:ok, value} | {:failed, failure_record} | :error | {:error, graph_error}
attempts(workflow, key)                :: {:ok, %{alt_name => failure_record}} | {:error, graph_error}
```

These are the functions of the `Ark.Workflow` module.

A workflow is the single value user code handles: the rules of the graph
and the state. `new` and the functions below build it, possibly at
compile time (§4). `load` puts a dump into it, and returns the same kind of value as
`new`: rules can still be added, and it is given to `run` like any
other. There is no separate resume function.

```elixir
wf = Workflow.new() |> Workflow.add_rule(...)   # or @graph, built at compile time
{:ok, wf} = Workflow.run(wf, targets, context: %{}, middlewares: [])
{:ok, data} = Workflow.dump(wf)
{:ok, wf} = Workflow.load(@graph, data)
{:ok, wf} = Workflow.clear_failure(wf, &match?({_, :b, _}, &1))
{:ok, wf} = Workflow.run(wf, targets)
```

### Building the graph

`add_rule(g, identity, rule)` registers `rule` under `identity`, and
validates the whole rule at once. The identity names the rule; the rule
map holds its implementation (§4):

- `identity` is `name` or `{ns, name}`. A bare `name` is in the current
  namespace of the graph (§3). Registration takes no
  params, so `{ns, name}` here is a rule identity, whereas in a
  dependency list a two-element tuple is `{name, params}` (§4).
- `rule` is a map with the keys:
  - `alts` (mandatory): a non-empty keyword list binding each
    alternative name to a map `%{deps: deps, body: body}`, both keys
    mandatory. A rule without dependencies gives `deps: []`.
  - `dump` and `load` (optional, identity by default): §10.

Any other key, in the rule map or in an alternative map, is rejected.
These maps can be validated with `Ark.Opts`, after `Map.to_list/1`.
Adding map support to `Ark.Opts` is fine if it makes this simpler.
`Ark.Opts` has no notion of mandatory keys, so the presence of `alts`,
`deps` and `body` is checked separately.

The rule map is the single registration form: it is plain data, so tests
and helpers build it directly.

```elixir
Workflow.new()
|> add_rule(:token_check, %{alts: [default: %{deps: [], body: &check_token/3}]})
|> add_rule(:user, %{
  alts: [default: %{deps: [], body: &fetch_user/3}],
  dump: &User.to_map/1,
  load: &User.from_map/1
})
|> add_rule(:account, %{alts: [default: %{deps: [&user_of/3], body: &fetch_account/3}]})
|> add_rule(:report, %{
  alts: [
    live: %{deps: [:token_check, &account_of/3, &billing_of/3], body: &build/3},
    snapshot: %{deps: [&snapshot_of/3], body: &unwrap/3}
  ]
})
```

`add_ns(g, ns, callback)` calls `callback` with the graph whose current
namespace is `ns`, and returns the graph the callback returns, with the
current namespace restored. Calls nest: the innermost namespace applies.
A callback that does not return a graph is a graph error, raised. Inside
the callback, `add_rule(g, {:default, name}, rule)` exposes an entry
point of an otherwise black-box set of rules; its dependencies on the
rules of the set are written `{ns, name, params}`, since a key without
namespace in a rule of `:default` is in `:default`.

```elixir
Workflow.new()
|> add_ns(MyApp.Billing, fn g ->
  g
  |> add_rule(:account, %{alts: [default: %{deps: [&user_of/3], body: &fetch_account/3}]})
  |> add_rule(:report, %{alts: [default: %{deps: [:account], body: &build/3}]})
  |> add_rule({:default, :billing_report}, %{
    alts: [default: %{deps: [&billing_report_of/3], body: &unwrap/3}]
  })
end)
```

The callback runs while the graph is built: it is not stored, so a
graph built with `add_ns` can still be stored in a module attribute
(§4).

### Running

- `targets` are the keys user code wants computed, in the forms of §3,
  outside any rule. They are given to every `run` call and are not
  persisted: they may change between resumes. `run` returns
  `{:ok, workflow}` once every target has a value, or stops at the first
  failed target.
- `run` options: `context` (§6, default `%{}`) and `middlewares` (below,
  default none).
- The workflow is always returned: user code reads values with `fetch`. To compute independent targets and tolerate
  some failures, user code runs them one at a time; recorded values are
  shared between runs.
- `run` always resets the runtime-only data (§8) and rebuilds the demand
  stack from the given targets. The common use is to run fully, persist
  some data and close; resuming is the rare case, so rebuilding the stack
  from the recorded facts on resume is acceptable.
- The engine progresses by operations (§2). The API of this spec works
  at the level of runs: what an operation is may differ between
  implementations, and an implementation may expose a step function of
  its own.

### Reading

`fetch` reads the state of one key, written in the forms of §3, outside
any rule: `:foo` is `{:default, :foo, %{}}`. It returns `{:ok, value}`
for a key with a value, `{:failed, failure_record}` for a failed key,
and `:error` for a key with no result, in progress or never demanded. A
key with no registered rule returns `{:error, graph_error}`, as for
`run` targets.

`attempts` reads the attempt records of one key, in the same key forms:
`{:ok, map}` from alternative name to failure record, empty for a key
with no attempts, and `{:error, graph_error}` for a key with no
registered rule.

Together they walk the failure tree (§7) from any failed key: `fetch`
gives the key's failure, `attempts` its record per alternative, and a
`{:dep_failed, dep_key}` record names the dependency, in full form, to
read next, down to the leaf `:computation_error` records and their
cleaned errors, with their `reason`.

### Errors

Failures of user code are not errors of the API: they are failure
records (§7). The API returns errors of three families, as exception
structs, so `Exception.message/1` formats them for logs:

- **Computation error** (`Ark.Workflow.ComputationError`): a target
  could not be computed. This is the normal outcome of data that cannot
  be computed, and the cause is usually not the target itself but a key
  below it. The error holds:
  - `target`: the first target with no value;
  - `causes`: the leaves of its failure tree, in evaluation order. Each
    is the failed key, the alternative and its cleaned error (§7): a
    `:computation_error` record, never a `:dep_failed` one. A target
    whose alternatives failed on different branches has several causes.

  Its message describes the tree from the target down to the causes. The
  error is derived from the records (§7), so its message, and the `kind`,
  `at` and `message` of each cause, its keys and its tree, are the same
  whether the failures happened in this run or before a dump. The
  `reason` of a cause is the original term for a failure recorded in the
  current workflow value, and `nil` for a failure loaded from a dump.
- **Graph error** (`Ark.Workflow.GraphError`): the code is wrong,
  whatever the data. It carries what is needed to debug the code, as
  described below. Graph errors are sorted by when they can be detected:
  1. `add_rule` raises on anything it can check from the rule alone:
     identity, rule and alternative map shapes, names, arity of anonymous functions and captures,
     malformed dependency entries, static keys with a string identity or
     invalid params, two different static keys under one `deps` key. In a
     module attribute, these are compile errors.
  2. `run`, before calling any user code, checks what needs the whole
     graph: static dependencies naming a rule that is not registered, and
     targets. It returns the graph error with the workflow unchanged.
  3. During the run, an invalid dependency returned by a dependency
     function, or a cycle (§5), stops the run. `run` returns the graph
     error with the workflow, holding every fact recorded so far, and
     nothing for the key whose dependency function is at fault.

  `run` never raises.

  A graph error holds:
  - `rule`: the `{ns, name}` of the rule at fault, or `nil` when no rule
    is involved: an invalid identity, a target, a key given to `fetch`,
    `attempts` or `clear_failure`, or `add_ns`;
  - `key`: the key being computed, with its params, for an error found
    during the run (3. above), `nil` otherwise;
  - `alternative`: the name of the alternative at fault, when the error
    is inside one;
  - `reason`: what is wrong, as a tagged tuple holding the terms involved
    as the code gave them, or an `Ark.Opts.Error` for the shape of a
    rule. Its message is derived from the reason and the fields above.

  Key reasons are shared by static dependencies, keys returned by
  dependency functions, targets, and the keys given to `fetch`,
  `attempts` and `clear_failure`:

  | Reason | For |
  | --- | --- |
  | `{:invalid_key, given}` | A term that is not a key: a string, a number, a nested list, `nil`, `true`, `false`, a string `ns` or `name` |
  | `{:invalid_params, given}` | A key whose params are not a map, or hold a pid, port, reference or function. A forgotten params, `{ns, name}`, is one: its message hints `{ns, name, %{}}` |
  | `{:unknown_rule, key}` | A key whose `{ns, name}` has no rule. The full key shows how the namespace was resolved |
  | `{:shadowing, exposure, exposure}` | Two different keys of one alternative exposed under the same `deps` key (§4) |

  An exposure is `{exposed_as, key, :alias | :key}`: the `deps` key, the
  full key exposed under it, and whether `exposed_as` is an alias or the
  written form of the key. The two exposures of a shadowing are in no
  particular order.

  Building the graph, raised by `add_rule` and `add_ns`:

  | Reason | For |
  | --- | --- |
  | `{:invalid_identity, given}` | An identity that is not `name` or `{ns, name}` with addresses (§3) |
  | `{:duplicate_rule, identity}` | An identity already registered |
  | `{:invalid_rule, %Ark.Opts.Error{}}` | The shape of the rule or alternative maps: missing or unknown keys, `alts` that is not a non-empty keyword list, an invalid or duplicate alternative name, the arity of a body, a dependency function, `:dump` or `:load`. `alternative` is taken from the error path |
  | `{:invalid_namespace, given}` | `add_ns` with a namespace that is not an address |
  | `{:bad_return, :add_ns, fun, retval, :not_a_graph}` | The `add_ns` callback did not return a graph |

  `add_rule` raises the key reasons for invalid static dependencies, with
  `rule` and `alternative` set: a dependency entry that is neither a
  key, an alias map nor a dependency function is `{:invalid_key, given}`.

  Before evaluation, `run` returns `{:unknown_rule, key}` for a static
  dependency naming a rule that is not registered, with `rule` and
  `alternative` naming the dependent rule, and the key reasons of an
  invalid target, with `rule` set to `nil`. During evaluation:

  | Reason | For |
  | --- | --- |
  | `{:bad_return, :deps, fun, retval, key_reason}` | A dependency function, or a `:deps` middleware wrapping it, returned an invalid dependency (§5). `fun` is the dependency function as written in the `deps` list, `retval` the whole returned value, `key_reason` one of the key reasons |
  | `{:cycle, key, stack}` | `key` demanded while in progress (§5). `stack` lists the keys being computed, in demand order, from the target down to the demanding key, the `key` of the error |
- **Codec error** (`Ark.Workflow.CodecError`): a dump or a load failed: a
  value that cannot be encoded, a rule's `:dump` or `:load` that raises,
  a malformed dump, a value that cannot be decoded. Returned by `dump`,
  by `load`, or by the `run` that first uses a value decoded lazily.

### Dump and load

- `dump` applies each rule's `:dump` to its recorded values, encodes keys
  and values with the generic encoder (§10), drops the runtime-only data
  (§8) and produces pure JSON-compatible data (§8, dumped form). Keys and
  values still encoded since the last load are written as-is. Before
  that, `dump` decodes undecodable keys (see `load`) again: when one now
  decodes to a key that was computed in the meantime, the computed entry
  overwrites it, and `dump` emits a warning naming the key.
- `dump` does not change the workflow: it can still be run.
- `load` takes a workflow, usually holding the rules already (built from
  code or stored in a module attribute), plus the dumped data. It:
  1. validates that the dump is well-formed (§8);
  2. decodes every key with the generic decoder, and matches identities
     and alternative names against the rules of the workflow (§3);
  3. decodes the recorded values of rules in the workflow: generic
     decoder, then the rule's `:load`. Whether values are decoded at load
     or when first used is up to the implementation. Decoding at load is
     suggested: bad data fails early, and decoding is cheap since `:load`
     does not read external state (§10).

  Records of rules or alternatives not in the workflow (removed from the
  code) are kept as orphaned records (§7), and `load` emits one warning
  listing the rules they belong to. Values of such rules are never
  decoded: nothing can demand them.

  Rules are registered before the load. A rule added to the workflow
  after the load does not see the records of its identity: they stay
  orphaned, its keys are computed again, and `dump` writes the computed
  entry over the orphaned one, with a warning naming the key, as for
  undecodable keys below.

  A key whose params cannot be decoded (they reference an atom that does
  not exist) is an **undecodable key**: its entry stays encoded, is
  written back as-is by `dump`, and is never matched. `load` emits a
  warning naming its rule. When code later demands that key, it is computed
  again, and `dump` overwrites the encoded entry with the computed one.
- Storing a workflow-definition version alongside the dump is
  recommended: a rule whose meaning changed under the same identity
  keeps its recorded values (§3).
- A decode failure of a value whose rule is in the workflow (e.g. a
  rule's `:load` that does not accept data dumped by an older version of
  the rule) is a codec error, never a key failure: a value that was `ok`
  at dump must not become `failed`. Since `:load` does not read external
  state (§10), such a failure means the code is incompatible with the
  dump.

### Clearing failures

`clear_failure` makes failed keys evaluable again, e.g. after a deploy
added an alternative to their rule. Typical use is a script that loads
every failed workflow, clears the relevant keys and runs again. It takes
a key (forms of §3, outside any rule) or a predicate. The predicate
receives each failed key whose rule is in the workflow, in its full
`{ns, name, params}` form (§3), so `&match?({_, :b, _}, &1)` selects
every failed key of rule `:b` of any namespace.

For each selected key, it:

1. removes the failure of the key and all its attempt records;
2. propagates: whenever a key's failure is removed, every attempt record
   `{:dep_failed, that_key}` is removed, and the key holding it loses its
   own failure, which propagates in turn, through as many levels as
   there are.

Values are never removed. Other attempt records of the keys reached by
the propagation are kept: on the next `run`, those keys retry only the
alternatives that failed because of a cleared key. A consumer whose
attempt pointed to a cleared key loses its failure even when another of
its dependencies is failed too: that dependency was never demanded by the
attempt (short-circuit, §2), and the next run fails the consumer again
through it without calling its user code.

`clear_failure` returns `{:ok, workflow}` when it cleared at least one
key, and `{:error, :not_failed}` when there was nothing to clear: the key
has a value, has attempts but no result, has no records, or the
predicate selected nothing. A script clearing several keys can ignore
`:not_failed`, e.g. for a consumer already cleared by the propagation from
its dependency. A key with no registered rule is a graph error.

### Middlewares

A `run` option sets a list of **middlewares**. They wrap every call to
user code, bodies and dependency functions alike (§4):

```elixir
fn kind, meta, call -> result end
# kind: :computation (a body) | :deps (a dependency function)
# meta: %{key: key, alternative: alt_name}
# call: {module, function, args} | {fun, args}, invoked with apply
```

Before calling anything, the engine builds the whole chain as nested
tuples, with no closures. Each middleware layer is an MFA on an
engine-owned module, whose `args` hold the next call; the innermost call
is the user code, with the arguments of the actual call:

```elixir
{Ark.Workflow.Middleware, :call, [mw1, kind, meta,
  {Ark.Workflow.Middleware, :call, [mw2, kind, meta,
    {Mod, :fun, [params, deps, context | extra_args]}]}]}
# or, innermost, {fun, [params, deps, context]}
```

A middleware receives the `call` that follows it: invoking it runs the
next middleware, and the last middleware's `call` runs the user code.
Middlewares apply in list order, the first one outermost. A middleware
returns what the call would return, and may not invoke it at all.

The chain is plain data, readable before anything runs. The engine
exposes helpers on it, also used by its own middlewares:

- `innermost(call)` unwraps the middleware layers and returns the user
  code call, e.g. for a logger;
- `update_args(call, fun)` rewrites the arguments of the user code call
  through the chain, e.g. to change `context`.

Middlewares run inside the same boundary as user code: their raises and
invalid returns are normalized the same way (§5, §7). They are not part
of the graph and are never persisted.

The engine provides logging and telemetry middlewares. Other uses, such
as mocks in tests or caching external calls during development, are user
code: caching depends on what the user wants, and the engine shares
nothing between states.

## 10. Encoding

User code produces and consumes rich terms (atoms, structs, etc.);
encoding runs only at the dump/load boundary. Dumps are JSON. Params and
values go through one **generic encoder**, and each rule can adapt its
values with `:dump` and `:load`.

### Generic encoder

Like the dump format (§8), the generic encoder is a suggestion. A rule's
`:dump` and `:load` and their law (below) are API.

- A **JSON-native** term — a string, number, boolean, `nil`, or a list or
  string-keyed map of JSON-native terms — is stored as JSON:
  `%{"json" => 1, "data" => term}`.
- Any other term is stored as ETF:
  `%{"json" => 0, "data" => Base.encode64(:erlang.term_to_binary(term, [:deterministic]))}`.

Decoding returns JSON data as is, and decodes ETF with
`:erlang.binary_to_term(bin, [:safe])`.

Properties:

- Every term decodes to an equal term. The JSON branch takes only terms
  that JSON represents exactly; atoms, atom-keyed maps, tuples, structs
  and dates take the ETF branch. `%{user_id: 5}` and `%{"user_id" => 5}`
  never share an encoding.
- JSON-native data is readable and queryable in storage. ETF data is
  opaque.
- `:safe` decoding creates no atoms: a term referencing an atom that
  does not exist fails to decode.
- ETF bytes are deterministic within one OTP major release. The engine
  compares decoded terms, never bytes (§8).
- Pids, ports, references and functions are rejected with an error
  naming the key. A rule whose values contain them declares `:dump`.

### Rule `:dump` and `:load`

A rule may declare `:dump` and `:load` functions, both identity by
default. Like bodies, each is an anonymous function or a
`{module, function, extra_args}` tuple, called with the value (or the
data) prepended to `extra_args`:

```
dump:  fn value -> data end     stored as generic_encode(dump.(value))
load:  fn data -> value end     applied to generic_decode(stored)
```

- They belong to the rule, not to an alternative: every alternative of a
  rule produces the same kind of value.
- `:load` receives the stored data only: it restores a value, it does not
  compute one.
- **Law:** `load(dump(v))` must be semantically equivalent to `v`. A
  consumer then sees the same kind of value whether or not a pause
  happened between production and consumption.
- Typical use: turn a struct into a string-keyed map, so the stored value
  is JSON and can be queried in storage:

```elixir
add_rule(graph, :user, %{
  alts: [default: %{deps: [], body: &fetch_user/3}],
  dump: fn %User{id: id, email: email} -> %{"id" => id, "email" => email} end,
  load: fn %{"id" => id, "email" => email} -> %User{id: id, email: email} end
})
```

`:dump` and `:load` are a serialization mechanism: `:load` restores the
value from the stored data only, and does not read external state. A
value that must reflect fresh external data, e.g. a record fetched again
by ID, is computed by a separate rule.

A struct stored through ETF decodes with the fields it had at dump time.
A rule whose value struct changes shape across deploys declares `:dump`
and `:load`.

### Dump check

A workflow option of `new` (for development) makes `dump` check every value once,
collect the keys whose `:dump` output was stored as ETF, and emit a
single warning listing them. Such values are valid but cannot be queried
in storage.

## 11. Resume semantics (summary)

Resume is: build the rules (from code, or a module attribute) → `load`
the dump into that workflow (validate, decode) → `run`. Then:

- Recorded `ok` values are used as-is; their computations never re-run.
- Recorded attempt failures are honored: a key whose `A1` attempt is
  recorded failed proceeds directly to `A2`.
- Attempt records are matched by alternative name, and the current graph
  order decides the next alternative to try (§4).
- The demand stack is rebuilt by demanding the targets given to `run`;
  they need not be the targets of the run before the pause.
- Dependency functions of in-progress alternatives are called again
  with the loaded values; their results were never persisted (§5).
- Keys are decoded at load and matched by term equality (§8, §10).
  Bodies receive params as written by code, as in an uninterrupted run.

## 12. Non-goals and future work

- **Intra-DAG parallelism** — parallel computation within a DAG can be
  added after a prototype. It concerns the whole graph computation (when
  several computations have all their dependencies ready), not dependency
  resolution specifically.
- **Calling dependency functions once** — the engine may keep the
  keys returned by a dependency function at runtime to avoid repeated
  calls. Not a semantic guarantee.
- **Optional / failable dependencies** — all deps are hard in this
  version; recovery is expressed exclusively through alternatives.
- **Retry / invalidation policies** — a failed key is failed within a
  state; re-running from scratch is the only retry. Classifying transient
  vs permanent failures is future work.
- **Eager/speculative prefetch** — could become an explicit per-dep
  opt-in; never automatic.
- **Skipping derivable attempt records** — storage optimization only.
- **Rule builder helpers** — functions that build the rule map of §9,
  such as a shorthand for a single alternative. They will be specified
  later; this version has `add_rule` with the rule map only.

## 13. Differences from v1 (removal list)

- Throw-based lazy `inject!` discovery and the re-run loop: **removed**.
  Dependencies are declared (statically or via dependency functions); `deps` access is
  a pure lookup.
- Reserved `:error` inject, `NotFallbackError`, `fallback_error` plumbing:
  **removed**. Alternatives do not see prior failures; data shared
  between alternatives is a separate rule (§4).
- `DependencyError` chain building (`cause`/`from` unwrapping): **removed**;
  failure trees are re-derived from persisted records.
- Arity-based impl dispatch (`fun/1` vs `fun/2`) and the
  "does not support parameters" error: **removed**; single `(params, deps,
  context)` signature, params default `%{}`.
- Rule-level single dep list: replaced by **per-alternative** dep sets.

## 14. Test requirements

Requirements the test suite must express. Each one is observed through the
API (§9): values and errors returned, calls made to user code (mocks,
middlewares), warnings emitted. None of them inspects the internal shape
of the state or the dump format (§8).

Tests marked *(fixed dump)* need a dump built by hand. They are written
once the dump format is fixed. Tests marked *(operations)* need to stop a
run after a given operation, which the API does not expose: several
implementations may define operations differently. They are skipped until
an implementation is chosen.

A test of a graph error matches its reason (§9): at least its tag and the
term at fault, and `rule`, `key` and `alternative` when the error sets
them. A test of a message checks only what the formatter adds: hints,
and how keys are printed.

The suite may be split into files by topic, numbered in a useful reading
order (`01_graph_building_test.exs`, `02_keys_test.exs`, ...). Test
helpers in `test/support` are left to the implementor.

### Graph building (§3, §4, §5)

- Registering a rule...
  - ...twice under the same `{ns, name}` raises `{:duplicate_rule, identity}`
  - ...with an empty alternative list is an error
  - ...with two alternatives of the same name is an error
  - ...under a string `ns` or `name` raises `{:invalid_identity, given}`
  - ...with a string alternative name is rejected
  - ...with an `ns`, `name` or alternative name that is neither an atom
    nor a string (an integer, a tuple) is rejected
  - ...with `nil`, `true` or `false` as `ns`, `name` or alternative name
    is rejected
  - ...without `alts` is rejected
  - ...with an alternative without `deps` or without `body` is rejected
  - ...with an unknown key in the rule map or in an alternative map is
    rejected
  - ...that is not a map is rejected
  - ...with `alts` that is not a keyword list is rejected
  - ...with an alternative whose `deps` is not a list is rejected
  - ...registers the alternatives of `alts` in list order
  - ...applies its `dump` and `load` to the values of every alternative
  - ...without `dump` and `load` stores its values as they are
- An alternative named `:default` is tried in its list position like any
  other
- A rule identity...
  - ...`name` is in the current namespace
  - ...`{ns, name}` is in namespace `ns`
- The same rule map registered under two identities...
  - ...is two rules: a key of each is computed and recorded separately
  - ...in two namespaces resolves its dependencies written without
    namespace in the namespace of each identity
- A static dependency...
  - ...naming a rule that is not registered makes `run` return a graph
    error before calling any user code, also when no target demands the
    rule holding it, with reason `{:unknown_rule, key}`, and the rule and
    alternative holding the dependency
  - ...with a string `ns` or `name` is rejected when the rule is registered
  - ...with `nil`, `true` or `false` as `ns` or `name` is rejected when
    the rule is registered
  - ...with params containing a pid, port, reference or function, at any
    depth, is rejected when the rule is registered
  - ...written `{ns, name}` (forgotten params) is rejected as invalid
    params, with a message hinting `{ns, name, %{}}`
  - ...with params that are not a map (a list, an integer) is rejected as
    invalid params
  - ...naming a rule registered later in the graph is accepted
  - ...that is neither a key, an alias map nor a dependency function (an
    integer, a list, a four-element tuple) is rejected when the rule is
    registered
- The checks on static dependencies apply to the keys inside a static
  alias map
- A static alias map whose value is a dependency function is rejected
- Two different static keys of one alternative exposed under the same
  `deps` key are rejected when the rule is registered, with reason
  `{:shadowing, exposure, exposure}`, also when an alias shadows the
  written form of another dependency
- The same static key listed twice in one alternative is accepted and
  demanded once...
  - ...in two forms (`:a` and `{__MODULE__, :a, %{}}`, or `:a` and
    `{:default, :a, %{}}` in `:default`), and exposed under each form
  - ...under the same alias in two alias maps
- Two alternatives of one rule may use the same alias for different keys
- Two alternatives of one rule may declare different dependency lists
- Two rules with the same name in two namespaces are distinct rules
- `add_ns`...
  - ...registers the rules added by its callback in its namespace
  - ...resolves the dependencies written without namespace in those rules
    to its namespace
  - ...restores the current namespace when the callback returns
  - ...raises `{:bad_return, :add_ns, fun, retval, :not_a_graph}` when the
    callback does not return a graph
  - ...raises `{:invalid_namespace, given}` for a namespace that is not an
    address
- Nested `add_ns` calls...
  - ...register the rules of the inner callback in the inner namespace
  - ...restore the enclosing namespace, not `:default`, when the inner
    callback returns: a rule added after it, in the outer callback, is
    in the outer namespace
  - ...resolve the dependencies written without namespace to the
    namespace of each rule: inner rules to the inner namespace, outer
    rules to the outer one, also for an outer rule added after the inner
    callback returned
  - ...restore `:default` once the outermost callback returns
  - ...accept the same namespace at two levels
- `add_rule` with an identity `{ns, name}` inside an `add_ns` callback...
  - ...does not change the current namespace: a rule added after it with
    an identity `name` is in the namespace of the callback
  - ...with `:default` exposes an entry point: a rule in `:default` that a
    target written without namespace reaches, and whose dependencies on
    the rules of the callback are written `{ns, name, params}`
- A graph built with `add_ns` can be stored in a module attribute
- A graph whose user code (bodies, dependency functions, `:dump`,
  `:load`) is given as...
  - ...`{module, function, extra_args}` tuples
  - ...remote captures (`&Module.function/3`)

  ...can be built at compile time and stored in a module attribute, may
  name functions of the module being compiled, and runs like the same
  graph built at runtime
- An anonymous function or a remote capture of the wrong arity is
  rejected when the rule is registered...
  - ...as a body or a dependency function (arity 3)
  - ...as `:dump` or `:load` (arity 1)
- A body given as a tuple that is not `{module, function, list}` is
  rejected when the rule is registered
- A remote capture naming a function that does not exist yet is accepted
  when the rule is registered
- A tuple or a capture naming a function that does not exist fails the
  alternative with kind `:error` when it is called

### Keys and params (§3)

- A bare rule name and `{name, %{}}` are the same key: computed once
- `%{user_id: 5}` and `%{"user_id" => 5}` are two keys, each computed once
- `%{id: 1}` and `%{id: 1.0}` are two keys
- Params may hold structs and string keys
- A body receives params exactly as written by the code that demanded the
  key...
  - ...from a run target
  - ...from a static dependency
  - ...from a key returned by a dependency function
  - ...after a dump and a load, identical to an uninterrupted run
- A body of a key demanded without params receives `%{}`
- A rule registered without a namespace is in `:default`...
  - ...a target written `name` or `{name, params}` names a rule of
    `:default`
  - ...a target `{:default, name, params}` is the same key
  - ...a target written `name` does not name a rule of another namespace
- An error message prints keys of `:default` without their namespace
- An error message prints keys of other namespaces with their namespace
- `run` returns a graph error with `rule` set to `nil`, without calling
  user code...
  - ...for a target with no registered rule: `{:unknown_rule, key}`
  - ...for a target with a string `ns` or `name`: `{:invalid_key, given}`
  - ...for a target with params containing a pid, port, reference or
    function: `{:invalid_params, given}`
  - ...for a target with no registered rule even when the loaded state
    holds records for that key
  - ...for a malformed target: `{:invalid_key, given}` for `nil`, `true`,
    an integer or a four-element tuple, `{:invalid_params, given}` for
    params that are not a map or `{ns, name}` without params

### Dependency forms and the `deps` map (§4)

- A dependency written...
  - ...`name` is the rule `name` of the demanding namespace, params `%{}`
  - ...`{name, params}` is the rule `name` of the demanding namespace
  - ...`{ns, name, params}` is the rule of namespace `ns`
- The `deps` map given to a body...
  - ...holds every dependency of the alternative, static and dynamic
  - ...exposes an aliased dependency under its alias, whatever the term
    used as alias
  - ...exposes a dependency without alias under its written form...
    - ...`name`, `{name, %{}}` or `{ns, name, %{}}` for the same
      namespace and empty params
    - ...`{name, params}` for the same namespace
    - ...`{ns, name, params}` for another namespace
    - ...`{__MODULE__, :account, %{}}` declared in `__MODULE__`
    - ...`{:account, %{}}`
  - ...is `%{}` for an alternative without dependencies
- The same real key under two aliases of one alternative is computed once
  and exposed under both aliases
- The keys of an alias map are demanded in ordered-iterator order...
  - ...for a small map
  - ...for a map of more than 32 keys
- An empty alias map in a static dependency list demands nothing
- In a dependency list...
  - ...a `{module, function, list}` tuple is called as a dependency
    function
  - ...a remote capture is called as a dependency function
  - ...a `{ns, name, map}` tuple is demanded as a key

### Calling user code (§4)

- A body and a dependency function are called with `params`, `deps` and
  `context`...
  - ...as an anonymous function
  - ...as a `{module, function, extra_args}` tuple, with `extra_args`
    appended after the engine's arguments
  - ...as a remote capture (`&Module.function/3`)
- A rule's `:dump` and `:load` given as tuples are called with the value,
  or the data, before `extra_args`
- A body returning `{:ok, value}` records the value under the computed key
- A body returning `{:error, reason}` fails the alternative...
  - ...with kind `:user_term` and no stacktrace
  - ...with the exception message when `reason` is an exception struct
  - ...with `inspect(reason)` when `reason` is any other term
- A body returning anything else fails the alternative with kind
  `:bad_return`, no stacktrace, and a message holding the returned value
- A body that...
  - ...raises fails the alternative with kind `:error`, the message and a
    formatted stacktrace
  - ...matches on unexpected params and raises `FunctionClauseError` is
    caught like any raise
  - ...throws fails the alternative with kind `:throw`
  - ...exits fails the alternative with kind `:exit`, also with reason
    `:normal`
- An exception whose `message/1` raises, returned or raised, still yields
  a cleaned error
- A user exception's `blame/2` callback enriches its formatted message
- Every cleaned error carries the time it was recorded
- The `reason` of a cleaned error is the original term...
  - ...the `reason` of `{:error, reason}` for kind `:user_term`
  - ...the returned value for kind `:bad_return`
  - ...the normalized exception struct for kind `:error`, also for an
    Erlang error
  - ...the thrown value for kind `:throw`
  - ...the exit reason for kind `:exit`
- A dependency function that raises, throws or exits records the same
  `reason` as a body would

### Evaluation order (§2)

- Within an alternative, dependencies are resolved left to right...
  - ...a dependency is demanded only once every dependency to its left is
    `ok`
  - ...the first failed dependency fails the alternative with
    `{:dep_failed, dep_key}`...
    - ...without calling the body
    - ...without demanding the dependencies to its right
- Alternatives are tried in order...
  - ...the next alternative is entered only after the previous one failed
  - ...the dependencies of the next alternative are not demanded before
    the previous one failed (reference scenario: `C` is demanded only
    after `A1` fails)
  - ...an alternative whose dependency is already failed fails without
    calling its body, and the next alternative is entered
  - ...no alternative is entered once one succeeded
- A key whose alternatives all failed is failed with
  `{:all_alternatives_failed, alt_names}`, listing every attempted
  alternative
- After a deploy removed an alternative, a key that failed before the
  dump still lists that alternative in `{:all_alternatives_failed, _}`,
  by its name as a string
- A consumer of a failed key fails with `{:dep_failed, key}`, transitively
  up to the target
- `{:dep_failed, dep_key}` records the real key, never the alias it was
  demanded under
- A key failed earlier in a run is not computed again when another
  consumer demands it in the same run
- Nothing is computed unless it is a target or transitively demanded by
  one
- A key demanded by several consumers in one run is computed once
- The same real key demanded under different aliases is computed once and
  recorded under its real identity...
  - ...from two consumers
  - ...from two dependency functions of one alternative
  - ...from one dependency function returning both aliases
- Targets are demanded in order...
  - ...the next target is demanded only once the previous one has a value
  - ...the first failed target stops the run, later targets are never
    demanded

### Dependency functions (§5)

- A dependency function...
  - ...is called only once every dependency to its left is `ok`
  - ...receives the computed key's params, only the dependencies to its
    left, and the context
  - ...receives the dynamic dependencies to its left under their aliases
  - ...is not called when a dependency to its left is failed
  - ...is not called once the key has a value, in the same run or after a
    resume
  - ...is called again after a resume, with the loaded values
- The keys a dependency function returns...
  - ...are demanded before the entries to its right
  - ...as an alias map are exposed in `deps` under their aliases
  - ...as a list are exposed under their written forms
  - ...as a single key are exposed under its written form
  - ...as a list are demanded in list order: the first failed key fails
    the alternative, and the keys after it are not demanded
  - ...as an alias map are demanded in ordered-iterator order, with the
    same short-circuit, also for a map of more than 32 keys
  - ...written `name` or `{name, params}` resolve in the namespace of the
    demanding rule, also when a `{module, function, extra_args}`
    dependency function is defined in another module
- A dependency function returning an empty map or an empty list demands
  nothing, and the body runs
- When a dependency function returns different keys across calls, the
  engine follows the keys of the latest call; values of keys no longer
  returned stay recorded
- A dependency function that...
  - ...raises fails the alternative with a `:computation_error`, and the
    next alternative is entered
  - ...throws fails the alternative with kind `:throw`
  - ...exits fails the alternative with kind `:exit`
- A dependency function returning an invalid dependency makes `run` stop
  with a graph error...
  - ...with reason `{:bad_return, :deps, fun, retval, key_reason}`, and
    the rule, key and alternative whose dependency function returned it
  - ...returned with the workflow and every fact recorded before
  - ...recording nothing for the key whose dependency function returned
    it
  - ...after which a run with fixed code continues without calling the
    user code of recorded keys again
- Invalid dependencies, each a graph error with its key reason:
  - `nil`, `true` and `false`: `{:invalid_key, given}`, not an unknown
    rule
  - a string, a number, a function, a nested list, a list holding an alias
    map: `{:invalid_key, given}`
  - `{:ok, keys}`, with a message hinting that keys are returned directly
  - a key with no registered rule, even when the state holds records for
    that key: `{:unknown_rule, key}`
  - a key with a string `ns` or `name`: `{:invalid_key, given}`
  - a key with invalid params: `{:invalid_params, given}`
  - a key exposed under the same `deps` key as a different key of the
    alternative: `{:shadowing, exposure, exposure}`, when the other key
    is...
    - ...to the left of the dependency function
    - ...a static dependency to its right
    - ...returned by another dependency function of the alternative,
      e.g. two alias maps with a common alias
- A key returned by a dependency function...
  - ...that is also another dependency of the alternative under the same
    `deps` key is accepted and demanded once...
    - ...from a static dependency
    - ...from another dependency function, e.g. two alias maps giving the
      same alias to the same key
  - ...that is also another dependency of the alternative in another
    written form is demanded once and exposed under both forms
  - ...naming an existing rule whose computation fails fails the
    alternative with `{:dep_failed, key}`

### Cycles (§5)

- A dependency function returning a key in progress makes `run` stop
  with a graph error with reason `{:cycle, key, stack}`: the demanded key,
  and the keys being computed from the target down to the demanding key,
  which `rule`, `key` and `alternative` name. Nothing is recorded for the
  keys of the cycle
- A static dependency chain that loops back to a key in progress makes
  `run` stop the same way
- A key demanded twice from different branches (a diamond) is not a cycle:
  it is computed once
- A direct self-dependency makes `run` stop with a graph error
- A key in progress demanded under another form (`:a` and
  `{__MODULE__, :a, %{}}`) is detected as a cycle
- A cycle reachable only through a later alternative makes `run` stop
  with a graph error when that alternative is entered
- A rule demanding itself with other params (`{:fact, %{n: 5}}` demands
  `{:fact, %{n: 4}}`) is not a cycle
- A chain of 10,000 dependent keys computes, and the cycle check stays
  cheap at that depth

### Context (§6)

- User code receives the context given to the run, unchanged
- The context defaults to `%{}` when the run is given none
- A body and a dependency function receive the same context
- An alternative receives nothing about why previous alternatives failed
- Context is not persisted: after a load, user code sees only the context
  given to the run
- Changing the context between runs does not compute recorded keys again

### Failure persistence and scoping (§7)

- A failure is scoped to the exact key: `{:a, %{id: 1}}` failing on its
  first alternative does not affect `{:a, %{id: 2}}`, which starts at its
  first alternative
- A failed key stays failed...
  - ...on a later run of the same state: no user code is called for it
  - ...after a dump and a load
  - ...when a deploy adds alternatives to its rule
- A key with a value keeps it, and none of its alternatives is called
  again...
  - ...on a later run of the same state
  - ...after a dump and a load
  - ...when a deploy adds, removes or reorders alternatives
- A value produced by an alternative that a deploy then removed is given
  to consumers demanded after the deploy
- A run stopped between the failure of `A1` and the attempt of `A2`
  resumes at `A2`, without calling `A1` again
- After a deploy reorders alternatives, recorded attempts stay attached to
  their alternative name, and the current order decides which alternative
  is tried next
- After a deploy...
  - ...inserts an alternative before one that failed, the inserted one is
    tried next
  - ...removes the untried alternatives of a key, the key is failed on
    resume without calling user code
  - ...renames an alternative, the renamed one is tried again, and the
    records under the old name are orphaned
- Attempt records of a removed alternative...
  - ...take no part in evaluation
  - ...are honored again when the alternative is added back, also after a
    dump and a load: it is not tried again
- Failure records are not passed through a rule's `:dump` and `:load`

### Run API and lifecycle (§9)

- `run` returns `{:ok, workflow}` when every target has a value, and each
  target's value can be read from the workflow by its key
- `fetch` returns...
  - ...`{:ok, value}` for a key with a value
  - ...`{:failed, failure_record}` for a failed key
  - ...`:error` for a key with attempts but no result
  - ...`:error` for a key never demanded
  - ...`{:error, graph_error}` for a key with no registered rule, even
    when the state holds records for it
  - ...`{:error, graph_error}` for an invalid key: `{:invalid_key, given}`
    for a string identity, `{:invalid_params, given}` for params that are
    not a map
- `fetch` accepts the key forms of `run` targets: `:foo` reads
  `{:default, :foo, %{}}`
- `run` returns `{:error, error, workflow}` for the first failed target,
  the error being a computation error naming the target
- When `:a` needs `:b`, `:b` needs `:c` and `:c` fails...
  - ...the failure of `:a` points to `:b` only
  - ...the computation error for target `:a` has the error of `:c` as its
    single cause, and its message describes the chain down to it
- The computation error for a target whose alternatives failed on
  different branches lists every leaf as a cause, in evaluation order
- The computation error for a target that failed before a dump and a load
  is the same as the one returned by the run that failed it, apart from
  the `reason` of its causes, `nil` after the load
- The computation error is derived from the records: for a target failed
  by a key that failed in an earlier run, its causes are those of that
  earlier run
- A second `run` of a failed target returns the same computation error
- The target of a computation error is the first target with no value
- The causes of a computation error hold the cleaned error of each leaf,
  with its kind: `:user_term`, `:bad_return`, `:error`, `:throw` or `:exit`,
  and its `reason`
- From a failed key, `fetch` and `attempts` walk the `{:dep_failed, key}`
  records down to the leaf: when `:a` needs `:b`, `:b` needs `:c` and the
  body of `:c` returns `{:error, %SomeError{}}`, the walk from `:a` finds
  the struct as the `reason` of the leaf record of `:c`
- A second `run` on the returned workflow...
  - ...with the same targets calls no user code
  - ...with other targets reuses the recorded values
- `run` with an empty target list returns `{:ok, workflow}` without
  calling user code
- A target listed twice is computed once
- `run` never raises: graph errors are returned with the workflow
- Rules can be added to a workflow after a run or a load
- A `run` does not continue the targets of a previous interrupted run: it
  only demands the targets it is given
- Pausing after any operation, dumping, loading and running again yields
  the same values as an uninterrupted run, and calls each successful body
  exactly once over the whole sequence *(operations)*

### Dump and load (§8, §9, §10)

- `dump` produces data that encodes to JSON, and loading the decoded JSON
  restores the state: a run after the round trip calls no user code for
  recorded keys and returns the same values
- A loaded workflow can be run, and rules can still be added to it
- `dump` does not change the workflow: it can still be run
- An empty workflow dumps and loads into an empty workflow
- Terms survive the round trip as equal terms...
  - ...strings, numbers, booleans, `nil`, lists and string-keyed maps
  - ...atoms, atom-keyed maps, tuples, structs and dates
  - ...binaries that are not valid UTF-8, bitstrings and improper lists
  - ...in params and in values
- `%{user_id: 5}` and `%{"user_id" => 5}` are still two keys after a round
  trip
- `%{"id" => 1}` and `%{"id" => 1.0}` are still two keys after a round
  trip through JSON
- Dumping a loaded state that was not run produces the same data as the
  original dump, including orphaned records
- Dumping a loaded state that was not run produces the same data as the
  original dump, including undecodable keys *(fixed dump)*
- A failure record queried after a round trip equals the one before,
  including its time, kind and message, apart from the `reason` of its
  cleaned error, `nil` after the load
- A cleaned error whose `reason` holds a pid or a function does not make
  `dump` fail
- A `{:dep_failed, key}` record pointing to an orphaned key survives a
  load and a dump
- A `{:dep_failed, key}` record pointing to an undecodable key survives a
  load and a dump *(fixed dump)*
- A value containing a pid, port, reference or function...
  - ...makes `dump` return a codec error naming the key
  - ...dumps fine when the rule's `:dump` turns it into data
- A rule's `:dump` that raises, or returns a pid, makes `dump` return a
  codec error naming the key
- A rule's `:dump` and `:load`...
  - ...are identity when not declared
  - ...are applied to the rule's values: a consumer after a resume receives
    `load(dump(value))`
  - ...apply to every alternative of the rule
- `load` returns a codec error for... *(fixed dump)*
  - ...a malformed dump
  - ...a dump holding two entries for the same key, compared as decoded
    terms: also when one entry is stored as JSON and the other as ETF
- A value whose rule's `:load` fails makes `load`, or the `run` that first
  uses the value, return a codec error, never turning the key into a
  failure
- A value of a rule in the workflow whose ETF references an atom that
  does not exist makes `load`, or the `run` that first uses the value,
  return a codec error *(fixed dump)*
- Records of a rule removed from the code...
  - ...are loaded and kept as orphaned records
  - ...make `load` emit one warning listing the rules they belong to
  - ...are written back by `dump`
  - ...are never decoded: the removed rule's code is not involved
    *(fixed dump)*
  - ...take no part in evaluation: demanding that key is a graph error
  - ...are found again when the rule is registered again under the same
    identity, before the load
  - ...stay orphaned when the rule is added to the workflow after the
    load: its keys are computed again, and `dump` writes the computed
    entries over the orphaned ones, with a warning naming the keys
- `load` emits no warning when every record has a rule
- Load never creates atoms... *(fixed dump)*
  - ...for an `ns`, `name` or alternative name with no registered rule
  - ...for params referencing an atom that does not exist
- A key whose params reference an atom that does not exist...
  *(fixed dump)*
  - ...makes `load` emit a warning naming its rule
  - ...is written back as-is by `dump`
  - ...is never matched by a demanded key
  - ...once code demands the same key, it is computed again, and `dump`
    overwrites the encoded entry with the computed one and emits a warning
    naming the key

### Dump check (§10)

- With the dump check enabled, `dump` emits a single warning listing every
  key whose `:dump` output is stored as ETF
- With the dump check enabled and only JSON-native values, `dump` emits no
  warning
- With the dump check disabled, `dump` emits no warning

### Clearing failures (§9)

- `clear_failure` on a failed key...
  - ...returns `{:ok, workflow}`
  - ...makes the next run try its alternatives again from the first one
  - ...lets a deploy-added alternative run
  - ...removes the failure of every key holding `{:dep_failed, key}`,
    transitively
  - ...keeps the other attempt records of the keys reached by the
    propagation: the next run retries only the alternatives that failed
    because of a cleared key
  - ...keeps every recorded value
  - ...propagates through orphaned records
  - ...accepts the key forms that `run` accepts for targets
- When `:a` needs `:b`, `:b` needs `:c` and `:c` failed, clearing `:c`
  clears `:b` and `:a`
- When `:a` needs `:b` then `:d`, `:b` needs `:c`, `:d` failed in a first
  run and `:c` in a second, clearing `:c` clears `:b` and `:a`; the next
  run of `:a` computes `:c` and `:b`, then fails `:a` with
  `{:dep_failed, :d}` without calling the user code of `:d`
- `clear_failure` with a predicate...
  - ...clears every failed key it selects, with the same propagation
  - ...receives keys in the full `{ns, name, params}` form, `:default`
    included
  - ...is not given orphaned keys
- `clear_failure` returns `{:error, :not_failed}`...
  - ...for a key with a value
  - ...for a key with attempts but no result
  - ...for a key with no records
  - ...for a predicate that selects no key
  - ...for a consumer already cleared by the propagation from its
    dependency
- `clear_failure` for a key with no registered rule returns a graph error
- `clear_failure` result survives a dump and a load

### Middlewares (§9)

- A middleware wraps...
  - ...every body call, with kind `:computation`
  - ...every dependency function call, with kind `:deps`
- A middleware receives meta with the computed key and the alternative
  name
- Middlewares apply in list order, the first one outermost
- The call a middleware receives...
  - ...is plain data: `{module, function, args}` or `{fun, args}`
  - ...runs the next middleware when invoked, and the user code for the
    last middleware
- `innermost(call)` returns the user code call with its actual arguments
- `update_args(call, fun)` rewrites the user code arguments through the
  chain, e.g. to change the context seen by the body
- A middleware that does not invoke the call...
  - ...replaces the body result with its own return value
  - ...prevents the user code from running
- A middleware that raises fails the alternative the same way user code
  does
- A middleware wrapping a body and returning an invalid value fails the
  alternative with kind `:bad_return`
- A middleware wrapping a dependency function and returning an invalid
  dependency makes `run` stop with a graph error, with the reason the
  dependency function would have
- A middleware that rescues a raise from user code and returns
  `{:ok, value}` records the value
- A `:deps` middleware that does not invoke the call supplies the keys
  to demand
- Middlewares are not persisted: a run after a load uses only the
  middlewares given to that run
- The provided logging middleware logs each call to user code
- The provided telemetry middleware emits events for each call to user
  code
