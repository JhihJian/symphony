defmodule SymphonyElixir.Hub.RealWorkerLifecycleStore do
  @moduledoc """
  Process-local handoff between acknowledged real workers and Hub lifecycle
  reconciliation.

  Results are kept only until the matching active attempt consumes them. The
  runtime ledger remains the durable source of truth after reconciliation.
  """

  use GenServer

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, @name))
  end

  @spec record(map()) :: :ok | :unavailable | {:error, :invalid_lifecycle_result}
  def record(result) when is_map(result) do
    case Process.whereis(@name) do
      nil -> :unavailable
      _pid -> GenServer.call(@name, {:record, result})
    end
  end

  def record(_result), do: {:error, :invalid_lifecycle_result}

  @spec results([map()], keyword()) :: [map()]
  def results(requests, _opts \\ []) when is_list(requests) do
    case Process.whereis(@name) do
      nil -> []
      _pid -> GenServer.call(@name, {:take, requests})
    end
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    case Process.whereis(@name) do
      nil -> :ok
      _pid -> GenServer.call(@name, :reset)
    end
  end

  @doc false
  @spec count() :: non_neg_integer()
  def count do
    case Process.whereis(@name) do
      nil -> 0
      _pid -> GenServer.call(@name, :count)
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:record, result}, _from, state) do
    case lifecycle_key(result) do
      {:ok, key} -> {:reply, :ok, Map.put(state, key, result)}
      :error -> {:reply, {:error, :invalid_lifecycle_result}, state}
    end
  end

  def handle_call({:take, requests}, _from, state) do
    {results, state} =
      Enum.reduce(requests, {[], state}, fn request, {results, state} ->
        case lifecycle_key(request) do
          {:ok, key} ->
            case Map.pop(state, key) do
              {nil, state} -> {results, state}
              {result, state} -> {[result | results], state}
            end

          :error ->
            {results, state}
        end
      end)

    {:reply, Enum.reverse(results), state}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}
  def handle_call(:count, _from, state), do: {:reply, map_size(state), state}

  defp lifecycle_key(value) when is_map(value) do
    attempt_id = map_value(value, :attempt_id)
    start_intent_id = map_value(value, :start_intent_id)

    if is_binary(attempt_id) and attempt_id != "" and is_binary(start_intent_id) and start_intent_id != "" do
      {:ok, {attempt_id, start_intent_id}}
    else
      :error
    end
  end

  defp lifecycle_key(_value), do: :error

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
