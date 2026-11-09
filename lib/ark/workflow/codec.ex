defmodule Ark.Workflow.Codec do
  @moduledoc false

  defguardp is_unpersistable(term)
            when is_pid(term) or is_port(term) or is_reference(term) or is_function(term)

  defguardp is_atomic(term) when is_number(term) or is_atom(term) or is_bitstring(term)

  defguardp is_json_scalar(term) when is_number(term) or is_boolean(term) or is_nil(term)

  def encode(term) do
    case scan_json([term]) do
      :json ->
        {:ok, %{"json" => 1, "data" => term}}

      :etf ->
        {:ok,
         %{
           "json" => 0,
           "data" => Base.encode64(:erlang.term_to_binary(term, [:deterministic]))
         }}

      {:error, bad} ->
        {:error, {:bad_dump_term, bad}}
    end
  end

  def decode(%{"json" => 1, "data" => data}) do
    {:ok, data}
  end

  def decode(%{"json" => 0, "data" => data}) when is_binary(data) do
    with {:ok, bin} <- Base.decode64(data) do
      binary_to_term(bin)
    end
  end

  def decode(_) do
    :error
  end

  defp binary_to_term(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp scan_json([term | _]) when is_unpersistable(term) do
    {:error, term}
  end

  defp scan_json([[head | tail] | stack]) when is_json_scalar(head) and is_list(tail) do
    scan_json([tail | stack])
  end

  defp scan_json([[head | tail] | stack]) when is_binary(head) and is_list(tail) do
    if String.valid?(head) do
      scan_json([tail | stack])
    else
      find_unpersistable([tail | stack])
    end
  end

  defp scan_json([[head | tail] | stack]) when is_list(tail) do
    scan_json([head, tail | stack])
  end

  defp scan_json([term | stack]) when is_json_scalar(term) or term == [] do
    scan_json(stack)
  end

  defp scan_json([binary | stack]) when is_binary(binary) do
    if String.valid?(binary) do
      scan_json(stack)
    else
      find_unpersistable(stack)
    end
  end

  defp scan_json([map | stack]) when is_map(map) and not is_struct(map) do
    if json_keys?(map) do
      scan_json([:maps.values(map) | stack])
    else
      find_unpersistable([map | stack])
    end
  end

  defp scan_json([]) do
    :json
  end

  defp scan_json(stack) do
    find_unpersistable(stack)
  end

  defp json_keys?(map) do
    :maps.fold(
      fn key, _, acc -> acc and is_binary(key) and String.valid?(key) end,
      true,
      map
    )
  end

  defp find_unpersistable([term | _]) when is_unpersistable(term) do
    {:error, term}
  end

  defp find_unpersistable([[head | tail] | stack]) when is_atomic(head) do
    find_unpersistable([tail | stack])
  end

  defp find_unpersistable([[head | tail] | stack]) do
    find_unpersistable([head, tail | stack])
  end

  defp find_unpersistable([map | stack]) when is_map(map) do
    find_unpersistable([:maps.keys(map), :maps.values(map) | stack])
  end

  defp find_unpersistable([{a, b} | stack]) do
    find_unpersistable([a, b | stack])
  end

  defp find_unpersistable([{a, b, c} | stack]) do
    find_unpersistable([a, b, c | stack])
  end

  defp find_unpersistable([tuple | stack]) when is_tuple(tuple) do
    find_unpersistable([Tuple.to_list(tuple) | stack])
  end

  defp find_unpersistable([_ | stack]) do
    find_unpersistable(stack)
  end

  defp find_unpersistable([]) do
    :etf
  end
end
