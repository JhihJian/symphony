defmodule SymphonyElixir.HubProviderToolRoutingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Hub.ProviderToolRouting

  test "builds safe governance request for workpad upsert with stable intent key" do
    assert {:ok, routed} =
             ProviderToolRouting.build_request(
               "github_issue",
               "upsert_workpad_comment",
               %{
                 issue_id: "94",
                 body: "## Codex Workpad\n\nsecret-bearing body should be hashed, not copied",
                 header: "## Codex Workpad"
               },
               routing_opts(
                 correlation: %{
                   trace_id: "trace-1",
                   token: "github_pat_secret",
                   prompt: "full prompt should not be retained",
                   nested: %{cookie: "session=secret"}
                 }
               )
             )

    request = routed.request
    snapshot = routed.request_summary

    assert request.project_id == "alpha"
    assert request.provider_scope_key == "github:jhihjian/symphony"
    assert request.issue_key == "alpha:github:jhihjian/symphony:94"
    assert request.operation_kind == :comment_workpad_upsert
    assert request.priority == 25
    assert request.replay_policy == :marker_upsert
    assert request.logical_key =~ "alpha:github:jhihjian/symphony:94:writeback:workpad_upsert:"

    assert snapshot.provider_scope_key == "github:jhihjian/symphony"
    assert snapshot.issue_ref.provider_scope_key == "github:jhihjian/symphony"
    assert snapshot.issue_ref.provider_local_id == "94"
    assert snapshot.correlation.trace_id == "trace-1"
    assert snapshot.correlation.tool_name == "github_issue"
    assert snapshot.correlation.tool_operation == "upsert_workpad_comment"
    assert snapshot.correlation.target.body_bytes > 0
    assert is_binary(snapshot.correlation.target.body_sha256)

    assert routed.writeback_intent.logical_action == "workpad_upsert"
    assert routed.writeback_intent.operation_type == "comment_upsert"
    assert routed.writeback_intent.provider_marker == "## Codex Workpad"
    assert routed.writeback_intent.replay_policy == :idempotent

    safe_text = inspect(routed)
    refute safe_text =~ "github_pat_secret"
    refute safe_text =~ "secret-bearing body"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "session=secret"
    refute safe_text =~ "cookie"
  end

  test "maps provider tool operations to operation kind, priority, and replay policy" do
    cases = [
      {"github_issue", "get_issue", %{issue_id: "94"}, :dynamic_tool_provider_call, 50, :idempotent, nil},
      {"github_issue", "list_comments", %{issue_id: "94"}, :dynamic_tool_provider_call, 50, :idempotent, nil},
      {"github_issue", "set_status", %{issue_id: "94", state: "Human Review"}, :stage_writeback, 20, :idempotent, "status_set"},
      {"github_issue", "add_labels", %{issue_id: "94", labels: ["enhancement"]}, :stage_writeback, 20, :idempotent, "label_add"},
      {"github_pr", "list_for_head", %{head_ref_name: "issue-94-provider-tool-routing"}, :pr_lookup, 30, :idempotent, nil},
      {"github_pr", "get_pr", %{pr_number: "12"}, :pr_lookup, 30, :idempotent, nil},
      {"github_pr", "create_pr",
       %{
         head_ref_name: "issue-94-provider-tool-routing",
         base_ref_name: "main",
         title: "Add routing",
         body: "Issue: Closes #94",
         draft: true
       }, :pr_create, 30, :unknown_requires_manual_attention, nil},
      {"tracker_issue", "set_status", %{issue_id: "94", state: "Done"}, :stage_writeback, 20, :idempotent, "status_set"},
      {"tracker_issue", "create_comment", %{issue_id: "94", body: "plain comment"}, :stage_writeback, 20, :unknown_requires_manual_attention, "comment_append"}
    ]

    for {tool, operation, target, operation_kind, priority, replay_policy, intent_action} <- cases do
      assert {:ok, routed} = ProviderToolRouting.build_request(tool, operation, target, routing_opts())

      assert routed.request.operation_kind == operation_kind
      assert routed.request.priority == priority
      assert routed.request.replay_policy == replay_policy

      if intent_action do
        assert routed.writeback_intent.logical_action == intent_action
      else
        assert is_nil(routed.writeback_intent)
      end
    end
  end

  test "classifies routed execution results into compatible safe dynamic tool payloads" do
    assert {:ok, success} =
             ProviderToolRouting.execute(
               "github_issue",
               "set_status",
               %{issue_id: "94", state: "Human Review"},
               fn -> {:ok, %{"issueId" => "94", "state" => "Human Review", "updated" => true}} end,
               routing_opts()
             )

    assert success.success == true
    assert success.result.status == :success
    assert success.payload["providerGovernance"]["result"]["status"] == "success"
    assert success.payload["providerGovernance"]["result"]["ledger"]["writeback_intent_key"] =~ ":writeback:status_set:"

    assert {:ok, retryable} =
             ProviderToolRouting.execute(
               "github_pr",
               "get_pr",
               %{pr_number: "12"},
               fn -> {:error, {:github_api_status, 503}} end,
               routing_opts()
             )

    assert retryable.success == false
    assert retryable.result.status == :retryable_failure
    assert retryable.result.replayable == true
    assert retryable.payload["error"]["providerStatus"] == "retryable_failure"
    assert retryable.payload["error"]["retryable"] == true

    assert {:ok, permanent} =
             ProviderToolRouting.execute(
               "github_issue",
               "get_issue",
               %{issue_id: "404"},
               fn -> {:error, :issue_not_found} end,
               routing_opts()
             )

    assert permanent.result.status == :permanent_failure
    assert permanent.result.error_class == :not_found
    assert permanent.result.replayable == false

    assert {:ok, rate_limited} =
             ProviderToolRouting.execute(
               "github_issue",
               "list_comments",
               %{issue_id: "94"},
               fn -> {:provider_result, :rate_limited, error_class: :rate_limited, retry_after_ms: 60_000} end,
               routing_opts()
             )

    assert rate_limited.result.status == :rate_limited
    assert rate_limited.result.retry_after_ms == 60_000
    assert rate_limited.payload["providerGovernance"]["result"]["retry_after_ms"] == 60_000

    assert {:ok, unknown_pr_create} =
             ProviderToolRouting.execute(
               "github_pr",
               "create_pr",
               %{
                 head_ref_name: "issue-94-provider-tool-routing",
                 base_ref_name: "main",
                 title: "Add routing",
                 body: "Issue: Closes #94",
                 draft: true
               },
               fn -> {:provider_result, :unknown_result, result_summary: %{message: "timeout after provider accepted request"}} end,
               routing_opts()
             )

    assert unknown_pr_create.result.status == :unknown_result
    assert unknown_pr_create.result.replayable == false
    assert unknown_pr_create.result.manual_attention == true
    assert unknown_pr_create.payload["error"]["manualAttention"] == true
    assert unknown_pr_create.payload["error"]["retryable"] == false
  end

  test "dynamic tool uses hub provider routing only when explicitly enabled" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_issue",
        %{"operation" => "set_status", "issueId" => "94", "state" => "Human Review"},
        routing_opts(
          tracker_kind: "github",
          github_update_issue_state: fn issue_id, state ->
            send(test_pid, {:direct_provider_called, issue_id, state})
            :ok
          end
        )
      )

    assert_received {:direct_provider_called, "94", "Human Review"}

    assert %{
             "issueId" => "94",
             "providerGovernance" => %{
               "request" => %{
                 "operation_kind" => "stage_writeback",
                 "provider_scope_key" => "github:jhihjian/symphony",
                 "replay_policy" => "idempotent"
               },
               "result" => %{
                 "status" => "success",
                 "ledger" => %{"manual_attention" => false, "writeback_intent_key" => intent_key}
               }
             },
             "state" => "Human Review",
             "updated" => true
           } = Jason.decode!(response["output"])

    assert intent_key =~ "alpha:github:jhihjian/symphony:94:writeback:status_set:"
    assert response["success"] == true

    legacy =
      DynamicTool.execute(
        "github_issue",
        %{"operation" => "set_status", "issueId" => "94", "state" => "Done"},
        tracker_kind: "github",
        github_update_issue_state: fn issue_id, state ->
          send(test_pid, {:legacy_provider_called, issue_id, state})
          :ok
        end
      )

    assert_received {:legacy_provider_called, "94", "Done"}
    refute Map.has_key?(Jason.decode!(legacy["output"]), "providerGovernance")
  end

  test "dynamic tool routed unknown append comment requires manual attention and redacts body" do
    response =
      DynamicTool.execute(
        "tracker_issue",
        %{"operation" => "create_comment", "issueId" => "94", "body" => "comment body with secret should not leak"},
        routing_opts(
          tracker_create_comment: fn _issue_id, _body ->
            {:error, :comment_create_failed}
          end
        )
      )

    assert response["success"] == false
    decoded = Jason.decode!(response["output"])

    assert decoded["error"]["providerStatus"] == "unknown_result"
    assert decoded["error"]["manualAttention"] == true
    assert decoded["error"]["retryable"] == false
    assert decoded["providerGovernance"]["result"]["manual_attention"] == true
    assert decoded["providerGovernance"]["result"]["replayable"] == false

    safe_text = inspect(decoded)
    refute safe_text =~ "comment body with secret"
    refute safe_text =~ "secret should not leak"
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
          run_context: %{
            attempt_id: "attempt-1",
            attempt_number: 2,
            correlation_id: "corr-1",
            current_stage: "in_progress",
            session_id: "session-1",
            workspace_lease_id: "lease-1",
            prompt: "do not copy prompt"
          },
          config_fingerprint: "fingerprint-alpha",
          snapshot_version: "hub-registry:alpha:1"
        },
        routing_extra
      )

    Keyword.merge([hub_provider_routing: context], tool_extra)
  end
end
