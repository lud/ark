defmodule Ark.Workflow.Middleware do
  require Logger

  @doc false
  def chain(middlewares, kind, meta, innermost) do
    middlewares
    |> Enum.reverse()
    |> Enum.reduce(innermost, fn mw, next ->
      {__MODULE__, :call, [mw, kind, meta, next]}
    end)
  end

  @doc false
  def call(mw, kind, meta, next) when is_function(mw, 3) do
    mw.(kind, meta, next)
  end

  def call({m, f, extra}, kind, meta, next) do
    apply(m, f, [kind, meta, next | extra])
  end

  def innermost({__MODULE__, :call, [_mw, _kind, _meta, next]}) do
    innermost(next)
  end

  def innermost(call) do
    call
  end

  def update_args({__MODULE__, :call, [mw, kind, meta, next]}, fun) do
    {__MODULE__, :call, [mw, kind, meta, update_args(next, fun)]}
  end

  def update_args({user_fun, args}, fun) when is_function(user_fun) do
    {user_fun, fun.(args)}
  end

  def update_args({m, f, args}, fun) do
    {head, extra} = Enum.split(args, 3)
    {m, f, fun.(head) ++ extra}
  end

  def log(kind, %{key: key, alternative: alternative}, call) do
    label = Ark.Workflow.format_key(key)
    Logger.info("workflow #{kind} call of #{label} (alternative #{inspect(alternative)})")
    invoke(call)
  end

  def telemetry(kind, %{key: key, alternative: alternative}, call) do
    metadata = %{kind: kind, key: key, alternative: alternative}

    :telemetry.span([:ark, :workflow, :call], metadata, fn ->
      {invoke(call), metadata}
    end)
  end

  defp invoke({fun, args}) when is_function(fun) do
    apply(fun, args)
  end

  defp invoke({m, f, args}) do
    apply(m, f, args)
  end
end
