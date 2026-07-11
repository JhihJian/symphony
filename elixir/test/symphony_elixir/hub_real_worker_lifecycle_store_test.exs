defmodule SymphonyElixir.HubRealWorkerLifecycleStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.RealWorkerLifecycleStore

  test "starts with its default registered name" do
    assert {:ok, pid} = RealWorkerLifecycleStore.start_link()
    assert Process.whereis(RealWorkerLifecycleStore) == pid
    assert :ok = GenServer.stop(pid)
  end

  test "returns safe defaults while the store is unavailable" do
    refute Process.whereis(RealWorkerLifecycleStore)

    assert RealWorkerLifecycleStore.record(%{attempt_id: "attempt", start_intent_id: "intent"}) == :unavailable
    assert RealWorkerLifecycleStore.record(:invalid) == {:error, :invalid_lifecycle_result}
    assert RealWorkerLifecycleStore.results([]) == []
    assert RealWorkerLifecycleStore.reset() == :ok
    assert RealWorkerLifecycleStore.count() == 0
  end

  test "records, matches, consumes and resets lifecycle results" do
    start_supervised!(RealWorkerLifecycleStore)

    assert RealWorkerLifecycleStore.record(%{attempt_id: nil, start_intent_id: "intent"}) ==
             {:error, :invalid_lifecycle_result}

    first = %{
      attempt_id: "attempt-1",
      start_intent_id: "intent-1",
      status: "succeeded"
    }

    second = %{
      "attempt_id" => "attempt-2",
      "start_intent_id" => "intent-2",
      "status" => "failed"
    }

    assert RealWorkerLifecycleStore.record(first) == :ok
    assert RealWorkerLifecycleStore.record(second) == :ok
    assert RealWorkerLifecycleStore.count() == 2

    assert RealWorkerLifecycleStore.results([
             %{attempt_id: "missing", start_intent_id: "missing"},
             :invalid_request,
             %{"attempt_id" => "attempt-2", "start_intent_id" => "intent-2"}
           ]) == [second]

    assert RealWorkerLifecycleStore.count() == 1
    assert RealWorkerLifecycleStore.results([%{attempt_id: "attempt-1", start_intent_id: "intent-1"}]) == [first]
    assert RealWorkerLifecycleStore.results([%{attempt_id: "attempt-1", start_intent_id: "intent-1"}]) == []

    assert RealWorkerLifecycleStore.record(first) == :ok
    assert RealWorkerLifecycleStore.reset() == :ok
    assert RealWorkerLifecycleStore.count() == 0
  end
end
