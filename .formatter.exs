# Used by "mix format"
[
  inputs: ["*.exs", "{config,lib,test,dev}/**/*.{ex,exs}"],
  force_do_end_blocks: true,
  import_deps: [:ecto],
  line_length: 90
]
