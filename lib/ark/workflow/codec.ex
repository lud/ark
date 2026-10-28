defmodule Ark.Workflow.Codec do
  @moduledoc false

  def encode(term) do
    if json_native?(term) do
      %{"json" => 1, "data" => term}
    else
      %{
        "json" => 0,
        "data" => Base.encode64(:erlang.term_to_binary(term, [:deterministic]))
      }
    end
  end

  def etf?(%{"json" => 0}) do
    true
  end

  def etf?(_) do
    false
  end

  def decode(%{"json" => 1, "data" => data}) do
    data
  end

  def decode(%{"json" => 0, "data" => data}) when is_binary(data) do
    data |> Base.decode64!() |> :erlang.binary_to_term([:safe])
  end

  def decode(other) do
    raise ArgumentError, "invalid encoded term: #{inspect(other)}"
  end

  defp json_native?(term) when is_binary(term) do
    String.valid?(term)
  end

  defp json_native?(term) when is_number(term) or is_boolean(term) or is_nil(term) do
    true
  end

  defp json_native?(term) when is_list(term) do
    native_list?(term)
  end

  defp json_native?(term) when is_map(term) and not is_struct(term) do
    Enum.all?(term, fn {k, v} -> is_binary(k) and String.valid?(k) and json_native?(v) end)
  end

  defp json_native?(_) do
    false
  end

  defp native_list?([]) do
    true
  end

  defp native_list?([h | t]) do
    json_native?(h) and native_list?(t)
  end

  defp native_list?(_) do
    false
  end
end
