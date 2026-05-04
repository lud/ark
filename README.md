# Ark

<!-- rdmx :badges
    hexpm         : "ark?color=4e2a8e"
    github_action : "lud/ark/elixir.yaml?label=CI&branch=main"
    license       : ark
    -->
[![hex.pm Version](https://img.shields.io/hexpm/v/ark?color=4e2a8e)](https://hex.pm/packages/ark)
[![Build Status](https://img.shields.io/github/actions/workflow/status/lud/ark/elixir.yaml?label=CI&branch=main)](https://github.com/lud/ark/actions/workflows/elixir.yaml?query=branch%3Amain)
[![License](https://img.shields.io/hexpm/l/ark.svg)](https://hex.pm/packages/ark)
<!-- rdmx /:badges -->


Ark is a collection of small utilities useful for prototyping,
testing, and working with Elixir common patterns.

## Installation

<!-- rdmx :app_dep vsn:$app_vsn -->
```elixir
def deps do
  [
    {:ark, "~> 0.11"},
  ]
end
```
<!-- rdmx /:app_dep -->


## Plugins

<!-- rdmx ark:plugins -->
### `Ark.Error`

This module provides function to work errors as data.

### `Ark.Ok`

This module provides base functions to work with ok/error tuples.

### `Ark.Paginator`

This module provides a helper to build streams from paginated sources.

A user-supplied callback is called with an initial state and is expected to
return the items for the current page along with the next state, until it
signals that pagination is over.

```elixir
pages = %{1 => [1, 2, 3], 2 => [4, 5, 6]}

{:ok, stream} =
  Ark.Paginator.stream(1, fn page ->
    case Map.get(pages, page, []) do
      [] -> {:halt, []}
      items -> {:cont, items, page + 1}
    end
  end)

Enum.to_list(stream)
# => [1, 2, 3, 4, 5, 6]
```

### `Ark.PubSub`

This module provides a simple pub-sub mechanism.

### `Ark.Retry`

This module provides base functions to retry operations.

### `Ark.StructAccess`

This module provides a simple way to implement the Access behaviour for any struct.

#### Example

```elixir
defmodule MyStruct do
  defstruct [:k]
  use Ark.StructAccess
end

s = %MyStruct{k: 1}
put_in(s.k, 2)

# => %MyStruct{k: 2}
```

<!-- rdmx /ark:plugins -->


## Documentation

The docs can be found at [hexdocs](https://hexdocs.pm/ark).
