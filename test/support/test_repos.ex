defmodule Ark.TestRepos do
  def enabled do
    if :postgres in Keyword.get(ExUnit.configuration(), :exclude, []) do
      [Ark.TestRepo]
    else
      [Ark.TestRepo, Ark.PgRepo]
    end
  end

  def parameters do
    Enum.map(enabled(), &%{repo: &1})
  end
end
