defmodule SymphonyElixir.HubWritebackProcessorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.ProviderToolRouting
  alias SymphonyElixir.Hub.RuntimeLedger
  alias SymphonyElixir.Hub.WritebackProcessor

  test "normalizes provider routing summary into a safe runtime ledger writeback fact" do
    assert {:ok, routed} =
             ProviderToolRouting.build_request(
               "github_issue",
               "upsert_workpad_comment",
               %{
                 issue_id: "97",
                 header: "## Codex Workpad",
                 body: "full workpad body should not leak"
               },
               routing_opts()
             )

    summary = %{
      request: routed.request_summary,
      result: %{},
      tool_call: routed.tool_call,
      writeback_intent: routed.writeback_intent
    }

    assert {:ok, fact} = WritebackProcessor.normalize(summary)

    assert fact.project_id == "alpha"
    assert fact.issue_key == "alpha:github:jhihjian/symphony:97"
    assert fact.issue_ref.provider_scope_key == "github:jhihjian/symphony"
    assert fact.writeback.intent_key =~ "alpha:github:jhihjian/symphony:97:writeback:workpad_upsert:"
    assert fact.writeback.logical_action == "workpad_upsert"
    assert fact.writeback.operation_type == "comment_upsert"
    assert fact.writeback.replay_policy == :idempotent
    assert fact.writeback.result_status == :pending
    assert fact.writeback.attempt_id == "attempt-1"
    assert fact.writeback.target["header"] == "## Codex Workpad"
    assert is_binary(fact.writeback.target["body_sha256"])
    assert fact.writeback.target["body_bytes"] == 33

    safe_text = inspect(fact)
    refute safe_text =~ "full workpad body"
    refute safe_text =~ "prompt must not leak"
    refute safe_text =~ "github_pat_secret"
  end

  test "recovers string-key providerGovernance payload and unknown PR create requires lookup before replay" do
    assert {:ok, routed} =
             ProviderToolRouting.execute(
               "github_pr",
               "create_pr",
               %{
                 head_ref_name: "issue-97-writeback-processing",
                 base_ref_name: "main",
                 title: "Add writeback processing",
                 body: "Issue: Closes #97\n\nbody should be summarized",
                 draft: true
               },
               fn ->
                 {:provider_result, :unknown_result,
                  result_summary: %{
                    message: "timeout after provider accepted request",
                    body: "provider response body should not leak"
                  }}
               end,
               routing_opts()
             )

    payload = routed.payload["providerGovernance"]

    assert {:ok, fact} = WritebackProcessor.normalize(payload)
    assert fact.writeback.logical_action == "pr_create"
    assert fact.writeback.result_status == :unknown
    assert fact.writeback.replay_policy == :non_idempotent
    assert fact.writeback.manual_attention == true
    assert fact.writeback.manual_attention_reason == "unknown_pr_create_requires_provider_lookup"

    assert {:ok, decision} = WritebackProcessor.decide(RuntimeLedger.new(), payload)

    assert decision.decision == :manual_attention
    assert decision.action == :manual_attention
    assert decision.replayable == false
    assert decision.manual_attention == true
    assert decision.reason == :unknown_pr_create_requires_provider_lookup
    assert decision.provider_lookup.operation == "pr_lookup_by_head"
    assert decision.provider_lookup.target == %{"base_ref_name" => "main", "head_ref_name" => "issue-97-writeback-processing"}

    {:ok, ledger} = WritebackProcessor.apply_fact(RuntimeLedger.new(), payload)
    [project] = RuntimeLedger.replay(ledger).projects

    assert project.writebacks.counts.unknown == 1
    assert project.writebacks.counts.manual_attention == 1
    assert [%{reason: "unknown_pr_create_requires_provider_lookup", target: target}] = project.manual_attention
    assert target["head_ref_name"] == "issue-97-writeback-processing"

    safe_text = inspect(project)
    refute safe_text =~ "Issue: Closes #97"
    refute safe_text =~ "provider response body"
  end

  test "successful idempotent status writeback reuses completed result instead of replaying" do
    success_summary =
      routed_summary(
        "github_issue",
        "set_status",
        %{issue_id: "97", state: "Human Review"},
        {:ok, %{"issueId" => "97", "state" => "Human Review", "updated" => true}}
      )

    assert {:ok, ledger} = WritebackProcessor.apply_fact(RuntimeLedger.new(), success_summary)
    retry_summary = routed_summary("github_issue", "set_status", %{issue_id: "97", state: "Human Review"}, :timed_out)

    assert {:ok, decision} = WritebackProcessor.decide(ledger, retry_summary)

    assert decision.decision == :completed
    assert decision.action == :reuse_completed_result
    assert decision.replayable == false
    assert decision.manual_attention == false
    assert decision.reason == :already_succeeded
  end

  test "pending and retryable failures follow replay policy" do
    pending_summary =
      ProviderToolRouting.build_request(
        "github_issue",
        "set_status",
        %{issue_id: "97", state: "Human Review"},
        routing_opts()
      )
      |> elem(1)
      |> then(fn routed ->
        %{request: routed.request_summary, tool_call: routed.tool_call, writeback_intent: routed.writeback_intent}
      end)

    assert {:ok, pending_decision} = WritebackProcessor.decide(RuntimeLedger.new(), pending_summary)
    assert pending_decision.decision == :pending
    assert pending_decision.action == :execute_once
    assert pending_decision.replayable == true

    retryable_summary =
      routed_summary(
        "github_issue",
        "set_status",
        %{issue_id: "97", state: "Human Review"},
        {:provider_result, :retryable_failure, error_class: :network_timeout}
      )

    assert {:ok, retryable_decision} = WritebackProcessor.decide(RuntimeLedger.new(), retryable_summary)
    assert retryable_decision.decision == :retry
    assert retryable_decision.action == :retry_writeback
    assert retryable_decision.replayable == true
    assert retryable_decision.manual_attention == false
  end

  test "unknown append comment requires manual attention and redacts body" do
    summary =
      routed_summary(
        "tracker_issue",
        "create_comment",
        %{issue_id: "97", body: "append comment body should not leak"},
        {:provider_result, :unknown_result, result_summary: %{message: "lost acknowledgement"}}
      )

    assert {:ok, decision} = WritebackProcessor.decide(RuntimeLedger.new(), summary)

    assert decision.decision == :manual_attention
    assert decision.replayable == false
    assert decision.manual_attention == true
    assert decision.reason == :unknown_append_comment_requires_manual_attention

    {:ok, ledger} = WritebackProcessor.apply_fact(RuntimeLedger.new(), summary)
    [project] = RuntimeLedger.observability_snapshot(ledger).projects

    assert project.writebacks.counts.unknown == 1
    assert project.writebacks.counts.manual_attention == 1
    assert [%{manual_attention_reason: "unknown_append_comment_requires_manual_attention"}] = project.writebacks.manual_attention
    assert [%{code: :writeback_unknown_manual_attention}] = project.manual_attention

    safe_text = inspect(project)
    refute safe_text =~ "append comment body"
  end

  test "detects unstable intent keys and same intent key with different targets" do
    first = routed_summary("github_issue", "set_status", %{issue_id: "97", state: "Human Review"}, :timed_out)
    second = routed_summary("github_issue", "set_status", %{issue_id: "97", state: "Done"}, :timed_out)

    assert {:ok, ledger} = WritebackProcessor.apply_fact(RuntimeLedger.new(), first)
    assert {:ok, conflict} = WritebackProcessor.decide(ledger, second)

    assert conflict.decision == :conflict
    assert conflict.manual_attention == true
    assert Enum.any?(conflict.diagnostics, &(&1.code == :writeback_intent_key_unstable))

    assert {:ok, first_fact} = WritebackProcessor.normalize(first)
    assert {:ok, second_fact} = WritebackProcessor.normalize(second)

    same_key_different_target =
      put_in(second_fact.writeback.intent_key, first_fact.writeback.intent_key)

    assert {:ok, ledger_with_first} = WritebackProcessor.apply_fact(RuntimeLedger.new(), first_fact)
    assert {:ok, same_key_conflict} = WritebackProcessor.decide(ledger_with_first, same_key_different_target)

    assert same_key_conflict.decision == :conflict
    assert Enum.any?(same_key_conflict.diagnostics, &(&1.code == :writeback_intent_conflict))
  end

  test "sanitizes secret-bearing target and correlation fields" do
    summary =
      routed_summary(
        "github_issue",
        "set_status",
        %{issue_id: "97", state: "Human Review"},
        {:ok, %{"issueId" => "97", "state" => "Human Review", "updated" => true}}
      )
      |> put_in([:writeback_intent, :target, :body], "body containing ghp_secret should become digest only")
      |> put_in([:writeback_intent, :target, :authorization], "Bearer github_pat_secret")
      |> put_in([:request, :correlation, :raw_config], %{"token" => "$GITHUB_TOKEN"})
      |> put_in([:request, :correlation, :prompt], "full prompt must not leak")

    assert {:ok, fact} = WritebackProcessor.normalize(summary)

    assert is_binary(fact.writeback.target["body_sha256"])
    assert fact.writeback.target["body_bytes"] == 52
    refute Map.has_key?(fact.writeback.target, "body")
    refute Map.has_key?(fact.writeback.target, "authorization")

    {:ok, ledger} = WritebackProcessor.apply_fact(RuntimeLedger.new(), fact)
    [project] = RuntimeLedger.observability_snapshot(ledger).projects

    safe_text = inspect(project)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "$GITHUB_TOKEN"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "authorization"
    refute safe_text =~ "raw_config"
  end

  defp routed_summary(tool, operation, target, execution) do
    assert {:ok, routed} =
             ProviderToolRouting.execute(
               tool,
               operation,
               target,
               fn -> execution end,
               routing_opts()
             )

    routed.summary
  end

  defp routing_opts(extra \\ []) do
    routing_keys = [:correlation, :run_context, :provider_scope, :project_id, :config_fingerprint, :snapshot_version]
    routing_extra = extra |> Keyword.take(routing_keys) |> Map.new()
    tool_extra = Keyword.drop(extra, routing_keys)

    context =
      Map.merge(
        %{
          project_id: "alpha",
          provider_scope: %{
            kind: "github",
            key: "github:jhihjian/symphony",
            scope: %{owner: "JhihJian", repo: "symphony", project_number: 1}
          },
          issue_ref: %{
            project_id: "alpha",
            tracker_kind: "github",
            provider_scope: %{owner: "JhihJian", repo: "symphony", project_number: 1},
            provider_scope_key: "github:jhihjian/symphony",
            provider_issue_id: "97",
            provider_local_id: "97",
            identifier: "JhihJian/symphony#97",
            url: "https://github.com/JhihJian/symphony/issues/97"
          },
          run_context: %{
            attempt_id: "attempt-1",
            attempt_number: 2,
            correlation_id: "corr-1",
            current_stage: "in_progress",
            session_id: "session-1",
            workspace_lease_id: "lease-1",
            prompt: "prompt must not leak",
            token: "github_pat_secret"
          },
          config_fingerprint: "fingerprint-alpha",
          snapshot_version: "hub-registry:alpha:1"
        },
        routing_extra
      )

    Keyword.merge([hub_provider_routing: context], tool_extra)
  end
end
