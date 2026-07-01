defmodule SymphonyElixir.HubRealWritebackExecutorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{
    ActivationPreflight,
    CutoverExecutionOutcomeLedger,
    ProviderToolRouting,
    RealWritebackExecutor,
    RuntimeLedger,
    WritebackProcessor
  }

  test "executes idempotent stage writeback through project-local tracker settings" do
    root = tmp_root("hub-real-writeback-stage")
    legacy_issue = %Issue{id: "shared-1", identifier: "LEGACY-1", title: "Legacy", state: "Todo"}
    alpha_issue = %Issue{id: "shared-1", identifier: "ALPHA-1", title: "Alpha", state: "Todo"}
    beta_issue = %Issue{id: "shared-1", identifier: "BETA-1", title: "Beta", state: "Todo"}

    try do
      alpha = write_memory_project!(root, "alpha")
      beta = write_memory_project!(root, "beta")

      Workflow.set_workflow_file_path(Path.join(root, "legacy/WORKFLOW.md"))
      File.mkdir_p!(Path.join(root, "legacy"))
      write_workflow_file!(Path.join(root, "legacy/WORKFLOW.md"), tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "legacy"]))

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [legacy_issue])

      Application.put_env(:symphony_elixir, :memory_tracker_issues_by_project, %{
        "alpha" => [alpha_issue],
        "beta" => [beta_issue]
      })

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      assert {:ok, routed} =
               ProviderToolRouting.build_request(
                 "tracker_issue",
                 "set_status",
                 %{issue_id: "shared-1", state: "in_progress"},
                 routing_opts("alpha", "memory")
               )

      result =
        RealWritebackExecutor.execute(routed.request,
          writeback_intent: routed.writeback_intent,
          registry: registry([alpha, beta])
        )

      assert result.status == :success
      assert result.result_summary.executor == "real_writeback"
      assert result.result_summary.provider_io == true
      assert result.result_summary.provider_scope_key == "memory:alpha"
      assert result.result_summary.logical_action == "status_set"
      assert result.result_summary.target.state == "in_progress"
      assert result.result_summary.execution_outcome.status == "succeeded"
      assert result.result_summary.execution_outcome.side_effect_entered == true

      assert_receive {:memory_tracker_state_update, "shared-1", "in_progress"}, 1_000
      refute_receive {:memory_tracker_state_update, "legacy", _state}, 50

      issues = Application.fetch_env!(:symphony_elixir, :memory_tracker_issues)
      assert [%Issue{id: "shared-1", state: "Todo"}] = issues
    after
      File.rm_rf(root)
    end
  end

  test "executes GitHub workpad upsert and label add through routed executor without leaking body" do
    root = tmp_root("hub-real-writeback-github")
    test_pid = self()

    try do
      project = write_github_project!(root, "alpha")

      workpad_body = "## Codex Workpad\n\nfull workpad body with secret should not leak"

      assert {:ok, routed_workpad} =
               ProviderToolRouting.build_request(
                 "github_issue",
                 "upsert_workpad_comment",
                 %{issue_id: "129", header: "## Codex Workpad", body: workpad_body},
                 routing_opts("alpha", "github")
               )

      assert {:provider_result, :success, workpad_result} =
               RealWritebackExecutor.execute_routed(
                 Map.merge(routed_workpad, %{raw_target: %{issue_id: "129", header: "## Codex Workpad", body: workpad_body}}),
                 registry: registry([project]),
                 github_upsert_workpad_comment: fn issue_id, body, header ->
                   send(test_pid, {:github_workpad_upsert, issue_id, body, header})
                   {:ok, %{"comment" => %{"id" => "comment-1", "url" => "https://example.test/comment-1"}, "body" => body}}
                 end
               )

      assert_received {:github_workpad_upsert, "129", ^workpad_body, "## Codex Workpad"}
      assert workpad_result[:external_ref] == "https://example.test/comment-1"
      assert workpad_result[:result_summary].comment.id == "comment-1"

      safe_text = inspect(workpad_result)
      refute safe_text =~ "full workpad body"
      refute safe_text =~ "secret should not leak"

      assert {:ok, routed_labels} =
               ProviderToolRouting.build_request(
                 "github_issue",
                 "add_labels",
                 %{issue_id: "129", labels: ["enhancement", "symphony"]},
                 routing_opts("alpha", "github")
               )

      result =
        RealWritebackExecutor.execute(routed_labels.request,
          writeback_intent: routed_labels.writeback_intent,
          registry: registry([project]),
          github_add_labels: fn issue_id, labels ->
            send(test_pid, {:github_add_labels, issue_id, labels})
            {:ok, labels}
          end
        )

      assert result.status == :success
      assert result.result_summary.logical_action == "label_add"
      assert result.result_summary.label_count == 2
      assert_received {:github_add_labels, "129", ["enhancement", "symphony"]}
    after
      File.rm_rf(root)
    end
  end

  test "ledger decision blocks already succeeded and conflicting intents before provider I/O" do
    root = tmp_root("hub-real-writeback-ledger")
    test_pid = self()

    try do
      project = write_memory_project!(root, "alpha")

      succeeded_summary =
        routed_summary(
          "tracker_issue",
          "set_status",
          %{issue_id: "129", state: "in_progress"},
          {:ok, %{"issueId" => "129", "state" => "in_progress", "updated" => true}},
          "alpha",
          "memory"
        )

      assert {:ok, ledger} = WritebackProcessor.apply_fact(RuntimeLedger.new(), succeeded_summary)

      assert {:ok, routed_retry} =
               ProviderToolRouting.build_request(
                 "tracker_issue",
                 "set_status",
                 %{issue_id: "129", state: "in_progress"},
                 routing_opts("alpha", "memory")
               )

      completed =
        RealWritebackExecutor.execute(routed_retry.request,
          writeback_intent: routed_retry.writeback_intent,
          runtime_ledger: ledger,
          registry: registry([project]),
          tracker_update_issue_state: fn issue_id, state ->
            send(test_pid, {:unexpected_provider_call, issue_id, state})
            :ok
          end
        )

      assert completed.status == :success
      assert completed.result_summary.provider_io == false
      assert completed.result_summary.decision == "completed"
      refute_received {:unexpected_provider_call, _issue_id, _state}

      first = routed_summary("tracker_issue", "set_status", %{issue_id: "129", state: "in_progress"}, :timed_out, "alpha", "memory")
      assert {:ok, conflict_ledger} = WritebackProcessor.apply_fact(RuntimeLedger.new(), first)

      assert {:ok, routed_conflict} =
               ProviderToolRouting.build_request(
                 "tracker_issue",
                 "set_status",
                 %{issue_id: "129", state: "done"},
                 routing_opts("alpha", "memory")
               )

      conflict =
        RealWritebackExecutor.execute(routed_conflict.request,
          writeback_intent: routed_conflict.writeback_intent,
          runtime_ledger: conflict_ledger,
          registry: registry([project])
        )

      assert conflict.status == :permanent_failure
      assert conflict.error_class == :conflict
      assert conflict.result_summary.provider_io == false
      assert conflict.result_summary.decision == "conflict"
    after
      File.rm_rf(root)
    end
  end

  test "activation preflight blocks real writeback before provider I/O" do
    root = tmp_root("hub-real-writeback-activation-preflight")
    test_pid = self()

    try do
      project = write_memory_project!(root, "alpha") |> Map.put(:migration_state, "hub_managed")
      routed = routed_call!("tracker_issue", "set_status", %{issue_id: "129", state: "in_progress"}, "alpha", "memory")

      preflight =
        ActivationPreflight.build(registry([project]),
          probe: %{
            projects: %{
              "alpha" => %{
                legacy_service: %{service: "symphony@alpha.service", active: true},
                provider_scope_owners: [%{provider_scope_key: "memory:alpha", owner: "legacy-poll"}]
              }
            }
          }
        )

      result =
        RealWritebackExecutor.execute(routed.request,
          writeback_intent: routed.writeback_intent,
          registry: registry([project]),
          activation_preflight: preflight,
          tracker_update_issue_state: fn issue_id, state ->
            send(test_pid, {:unexpected_provider_call, issue_id, state})
            :ok
          end
        )

      assert result.status == :permanent_failure
      assert result.error_class == :conflict
      assert result.result_summary.provider_io == false
      assert result.result_summary.error == "activation_preflight_blocked"
      assert result.result_summary.reason == "legacy_ownership_conflict"
      assert "writeback" in result.result_summary.blocked_operations
      refute_received {:unexpected_provider_call, _issue_id, _state}
    after
      File.rm_rf(root)
    end
  end

  test "cutover gate blocks real writeback before provider I/O" do
    root = tmp_root("hub-real-writeback-cutover-gate")
    test_pid = self()

    try do
      project = write_memory_project!(root, "alpha") |> Map.put(:migration_state, "hub_managed")
      routed = routed_call!("tracker_issue", "set_status", %{issue_id: "129", state: "in_progress"}, "alpha", "memory")

      result =
        RealWritebackExecutor.execute(routed.request,
          writeback_intent: routed.writeback_intent,
          registry: registry([project]),
          cutover_gate: cutover_gate("alpha", "blocked", blocked_operations: ["writeback"], reasons: ["operator_acknowledgement_missing"]),
          tracker_update_issue_state: fn issue_id, state ->
            send(test_pid, {:unexpected_provider_call, issue_id, state})
            :ok
          end
        )

      assert result.status == :permanent_failure
      assert result.error_class == :conflict
      assert result.result_summary.provider_io == false
      assert result.result_summary.error == "cutover_gate_blocked"
      assert "writeback" in result.result_summary.blocked_operations
      refute_received {:unexpected_provider_call, _issue_id, _state}
    after
      File.rm_rf(root)
    end
  end

  test "authorization consumption guard blocks real writeback before provider I/O" do
    root = tmp_root("hub-real-writeback-authorization-consumption")
    test_pid = self()

    try do
      project = write_memory_project!(root, "alpha") |> Map.put(:migration_state, "hub_managed")
      routed = routed_call!("tracker_issue", "set_status", %{issue_id: "129", state: "in_progress"}, "alpha", "memory")

      result =
        RealWritebackExecutor.execute(routed.request,
          writeback_intent: routed.writeback_intent,
          registry: registry([project]),
          authorization_consumption_guard: %{authorization_ledger: %{projects: []}},
          tracker_update_issue_state: fn issue_id, state ->
            send(test_pid, {:unexpected_provider_call, issue_id, state})
            :ok
          end
        )

      assert result.status == :permanent_failure
      assert result.error_class == :conflict
      assert result.result_summary.provider_io == false
      assert result.result_summary.error == "authorization_consumption_blocked"
      assert result.result_summary.authorization_consumption.decision == "no_authorization"
      assert result.result_summary.authorization_consumption.side_effect_source == "writeback_executor"
      assert result.result_summary.execution_outcome.status == "not_executed"
      assert result.result_summary.execution_outcome.no_side_effects == true
      refute_received {:unexpected_provider_call, _issue_id, _state}
    after
      File.rm_rf(root)
    end
  end

  test "unresolved execution outcome blocks writeback replay before provider I/O" do
    root = tmp_root("hub-real-writeback-outcome-replay")
    test_pid = self()

    try do
      project = write_memory_project!(root, "alpha")
      routed = routed_call!("tracker_issue", "set_status", %{issue_id: "129", state: "in_progress"}, "alpha", "memory")

      unresolved =
        CutoverExecutionOutcomeLedger.fact_snapshot(%{
          project_id: "alpha",
          provider_scope: %{kind: "memory", key: "memory:alpha", provider_scope_key: "memory:alpha", scope: %{namespace: "alpha"}},
          operation: "writeback",
          side_effect_source: "writeback_executor",
          status: "unknown",
          reason_code: "writeback_ack_lost",
          executor_result: %{provider_io: true, operation_kind: "stage_writeback"},
          side_effect_entered: true,
          side_effect_may_have_happened: true
        })

      outcome_ledger = CutoverExecutionOutcomeLedger.build(%{events: [unresolved]})

      result =
        RealWritebackExecutor.execute(routed.request,
          writeback_intent: routed.writeback_intent,
          registry: registry([project]),
          cutover_execution_outcome_ledger: outcome_ledger,
          tracker_update_issue_state: fn issue_id, state ->
            send(test_pid, {:unexpected_provider_call, issue_id, state})
            :ok
          end
        )

      assert result.status == :unknown_result
      assert result.result_summary.provider_io == false
      assert result.result_summary.error == "execution_outcome_replay_blocked"
      assert result.result_summary.execution_outcome.status == "unknown"
      refute_received {:unexpected_provider_call, _issue_id, _state}
    after
      File.rm_rf(root)
    end
  end

  test "maps provider failures, unsupported providers, and unsafe operations to governed safe results" do
    root = tmp_root("hub-real-writeback-failures")

    try do
      project = write_memory_project!(root, "alpha")
      routed = routed_call!("tracker_issue", "set_status", %{issue_id: "129", state: "in_progress"}, "alpha", "memory")

      rate_limited =
        RealWritebackExecutor.execute(routed.request,
          writeback_intent: routed.writeback_intent,
          registry: registry([project]),
          tracker_update_issue_state: fn _issue_id, _state -> {:error, {:github_api_status, 429}} end
        )

      assert rate_limited.status == :rate_limited
      assert rate_limited.error_class == :rate_limited
      assert rate_limited.backoff_until != nil

      retryable =
        RealWritebackExecutor.execute(routed.request,
          writeback_intent: routed.writeback_intent,
          registry: registry([project]),
          tracker_update_issue_state: fn _issue_id, _state -> {:error, {:github_api_status, 503}} end
        )

      assert retryable.status == :retryable_failure
      assert retryable.error_class == :provider_5xx

      permanent =
        RealWritebackExecutor.execute(routed.request,
          writeback_intent: routed.writeback_intent,
          registry: registry([project]),
          tracker_update_issue_state: fn _issue_id, _state -> {:error, :missing_github_api_token} end
        )

      assert permanent.status == :permanent_failure
      assert permanent.error_class == :auth_config

      unknown =
        RealWritebackExecutor.execute(routed.request,
          writeback_intent: routed.writeback_intent,
          registry: registry([project]),
          tracker_update_issue_state: fn _issue_id, _state -> {:error, :comment_update_failed} end
        )

      assert unknown.status == :unknown_result
      assert unknown.result_summary.error == "provider_error"

      unsupported_provider =
        routed_call!("tracker_issue", "set_status", %{issue_id: "129", state: "in_progress"}, "alpha", "gitlab")
        |> then(fn routed ->
          RealWritebackExecutor.execute(routed.request,
            writeback_intent: routed.writeback_intent,
            registry: registry([write_memory_project!(root, "wrong-kind")])
          )
        end)

      assert unsupported_provider.status == :permanent_failure

      append = routed_call!("tracker_issue", "create_comment", %{issue_id: "129", body: "plain append body should not leak"}, "alpha", "memory")

      append_result =
        RealWritebackExecutor.execute(append.request,
          writeback_intent: append.writeback_intent,
          registry: registry([project])
        )

      assert append_result.status == :unknown_result
      assert append_result.manual_attention == true
      assert append_result.result_summary.provider_io == false

      safe_text = inspect([rate_limited, retryable, permanent, unknown, append_result])
      refute safe_text =~ "plain append body"
      refute safe_text =~ "GITHUB_TOKEN"
      refute safe_text =~ "authorization"
      refute safe_text =~ "raw_provider"
    after
      File.rm_rf(root)
    end
  end

  test "returns safe governed failures for missing routing context and unsafe request kinds before provider I/O" do
    root = tmp_root("hub-real-writeback-validation")
    test_pid = self()

    try do
      project = write_memory_project!(root, "alpha")
      routed = routed_call!("tracker_issue", "set_status", %{issue_id: "129", state: "in_progress"}, "alpha", "memory")

      missing_registry =
        RealWritebackExecutor.execute(routed.request,
          writeback_intent: routed.writeback_intent,
          tracker_update_issue_state: fn issue_id, state ->
            send(test_pid, {:unexpected_provider_call, issue_id, state})
            :ok
          end
        )

      assert missing_registry.status == :permanent_failure
      assert missing_registry.result_summary.error == "invalid_request"
      assert missing_registry.result_summary.reason == "missing_hub_registry"

      {:provider_result, :permanent_failure, missing_request_opts} = RealWritebackExecutor.execute_routed(%{})
      assert missing_request_opts[:result_summary].error == "missing_provider_request"

      dynamic_request =
        Map.put(routed.request, :operation_kind, :dynamic_tool_provider_call)

      dynamic =
        RealWritebackExecutor.execute(dynamic_request,
          writeback_intent: routed.writeback_intent,
          registry: registry([project])
        )

      assert dynamic.status == :permanent_failure
      assert dynamic.result_summary.error == "unsupported_operation"
      assert dynamic.result_summary.reason == "dynamic_tool_provider_call"

      assert {:ok, pr_routed} =
               ProviderToolRouting.build_request(
                 "github_pr",
                 "create_pr",
                 %{
                   head_ref_name: "issue-129-real-writeback",
                   base_ref_name: "main",
                   title: "Add real writeback executor",
                   body: "Issue: Closes #129\n\nbody should not leak",
                   draft: true
                 },
                 routing_opts("alpha", "github")
               )

      pr_result =
        RealWritebackExecutor.execute(pr_routed.request,
          writeback_intent: pr_routed.writeback_intent,
          registry: registry([write_github_project!(root, "alpha")])
        )

      assert pr_result.status == :unknown_result
      assert pr_result.manual_attention == true
      assert pr_result.result_summary.error == "manual_attention"
      assert pr_result.result_summary.reason == "provider_lookup_required:pr_create"

      refute_received {:unexpected_provider_call, _issue_id, _state}

      safe_text = inspect([missing_registry, missing_request_opts, dynamic, pr_result])
      refute safe_text =~ "Issue: Closes #129"
      refute safe_text =~ "body should not leak"
    after
      File.rm_rf(root)
    end
  end

  test "isolates project config and provider scope failures to governed results without provider I/O" do
    root = tmp_root("hub-real-writeback-isolation")
    test_pid = self()

    try do
      project = write_memory_project!(root, "alpha")
      routed = routed_call!("tracker_issue", "set_status", %{issue_id: "129", state: "in_progress"}, "alpha", "memory")

      config_error =
        RealWritebackExecutor.execute(routed.request,
          writeback_intent: routed.writeback_intent,
          registry: registry([Map.merge(project, %{status: :error, load_error: "token $GITHUB_TOKEN invalid"})]),
          tracker_update_issue_state: fn issue_id, state ->
            send(test_pid, {:unexpected_provider_call, issue_id, state})
            :ok
          end
        )

      assert config_error.status == :permanent_failure
      assert config_error.error_class == :auth_config
      assert config_error.result_summary.error == "project_config_error"
      assert config_error.result_summary.reason =~ "[redacted]"

      scope_mismatch =
        RealWritebackExecutor.execute(routed.request,
          writeback_intent: routed.writeback_intent,
          registry: registry([put_in(project, [:tracker_summary, :provider_scope_key], "memory:beta")])
        )

      assert scope_mismatch.status == :permanent_failure
      assert scope_mismatch.error_class == :validation
      assert scope_mismatch.result_summary.error == "scope_mismatch"
      assert scope_mismatch.result_summary.reason == "provider_scope_key_mismatch"

      unsupported_provider =
        routed_call!("tracker_issue", "set_status", %{issue_id: "129", state: "in_progress"}, "alpha", "unknown")
        |> then(fn routed ->
          RealWritebackExecutor.execute(routed.request,
            writeback_intent: routed.writeback_intent,
            registry: registry([project])
          )
        end)

      assert unsupported_provider.status == :permanent_failure
      assert unsupported_provider.result_summary.error == "unsupported_provider"
      assert unsupported_provider.result_summary.reason == "unknown"

      refute_received {:unexpected_provider_call, _issue_id, _state}

      safe_text = inspect([config_error, scope_mismatch, unsupported_provider])
      refute safe_text =~ "$GITHUB_TOKEN"
    after
      File.rm_rf(root)
    end
  end

  test "executes GitHub status writes and rejects GitLab-only label writeback as unsupported" do
    root = tmp_root("hub-real-writeback-github-status")
    test_pid = self()

    try do
      github_project = write_github_project!(root, "alpha")

      github_routed =
        routed_call!("github_issue", "set_status", %{issue_id: "129", state: "Human Review"}, "alpha", "github")

      github_result =
        RealWritebackExecutor.execute(github_routed.request,
          writeback_intent: github_routed.writeback_intent,
          registry: registry([github_project]),
          github_update_issue_state: fn issue_id, state ->
            send(test_pid, {:github_status_write, issue_id, state})
            :ok
          end
        )

      assert github_result.status == :success
      assert github_result.result_summary.provider_kind == "github"
      assert github_result.result_summary.logical_action == "status_set"
      assert_received {:github_status_write, "129", "Human Review"}

      gitlab_project = write_gitlab_project!(root, "alpha")

      gitlab_routed =
        routed_call!("github_issue", "add_labels", %{issue_id: "129", labels: ["enhancement"]}, "alpha", "gitlab")

      gitlab_result =
        RealWritebackExecutor.execute(gitlab_routed.request,
          writeback_intent: gitlab_routed.writeback_intent,
          registry: registry([gitlab_project])
        )

      assert gitlab_result.status == :permanent_failure
      assert gitlab_result.result_summary.error == "unsupported_provider"
      assert gitlab_result.result_summary.reason == "gitlab"
    after
      File.rm_rf(root)
    end
  end

  defp registry(projects), do: %{projects: projects, warnings: [], errors: []}

  defp routed_call!(tool, operation, target, project_id, provider_kind) do
    assert {:ok, routed} =
             ProviderToolRouting.build_request(tool, operation, target, routing_opts(project_id, provider_kind))

    routed
  end

  defp routed_summary(tool, operation, target, execution, project_id, provider_kind) do
    assert {:ok, routed} =
             ProviderToolRouting.execute(
               tool,
               operation,
               target,
               fn -> execution end,
               routing_opts(project_id, provider_kind)
             )

    routed.summary
  end

  defp routing_opts(project_id, "memory") do
    [
      hub_provider_routing: %{
        project_id: project_id,
        provider_scope: %{
          kind: "memory",
          key: "memory:#{project_id}",
          scope: %{namespace: project_id}
        },
        issue_ref: issue_ref(project_id, "memory", "memory:#{project_id}", "129"),
        run_context: %{attempt_id: "attempt-1", correlation_id: "corr-1", current_stage: "in_progress"},
        config_fingerprint: "fingerprint-#{project_id}",
        snapshot_version: "hub-registry:#{project_id}:1"
      }
    ]
  end

  defp routing_opts(project_id, "github") do
    [
      hub_provider_routing: %{
        project_id: project_id,
        provider_scope: %{
          kind: "github",
          key: "github:jhihjian/#{project_id}",
          scope: %{owner: "JhihJian", repo: project_id, project_number: 1}
        },
        issue_ref: issue_ref(project_id, "github", "github:jhihjian/#{project_id}", "129"),
        run_context: %{attempt_id: "attempt-1", correlation_id: "corr-1", current_stage: "in_progress"},
        config_fingerprint: "fingerprint-#{project_id}",
        snapshot_version: "hub-registry:#{project_id}:1"
      }
    ]
  end

  defp routing_opts(project_id, provider_kind) do
    [
      hub_provider_routing: %{
        project_id: project_id,
        provider_scope: %{
          kind: provider_kind,
          key: "#{provider_kind}:#{project_id}",
          scope: %{namespace: project_id}
        },
        issue_ref: issue_ref(project_id, provider_kind, "#{provider_kind}:#{project_id}", "129"),
        run_context: %{attempt_id: "attempt-1", correlation_id: "corr-1", current_stage: "in_progress"},
        config_fingerprint: "fingerprint-#{project_id}",
        snapshot_version: "hub-registry:#{project_id}:1"
      }
    ]
  end

  defp issue_ref(project_id, tracker_kind, provider_scope_key, issue_id) do
    %{
      project_id: project_id,
      tracker_kind: tracker_kind,
      provider_scope: %{namespace: project_id},
      provider_scope_key: provider_scope_key,
      provider_issue_id: issue_id,
      provider_local_id: issue_id,
      identifier: "#{provider_scope_key}:#{issue_id}",
      url: "https://example.test/#{provider_scope_key}/issues/#{issue_id}"
    }
  end

  defp write_memory_project!(root, project_id) do
    project_root = Path.join(root, project_id)
    workflow_path = Path.join(project_root, "WORKFLOW.md")
    tracker_config_path = Path.join(project_root, "TRACKER.yaml")
    File.mkdir_p!(project_root)

    write_workflow_file!(workflow_path,
      tracker_kind: "memory",
      workspace_root: Path.join([root, "workspaces", project_id])
    )

    project(project_id, "memory", "memory:#{project_id}", workflow_path, tracker_config_path, %{namespace: project_id})
  end

  defp write_github_project!(root, project_id) do
    project_root = Path.join(root, project_id)
    workflow_path = Path.join(project_root, "WORKFLOW.md")
    tracker_config_path = Path.join(project_root, "TRACKER.yaml")
    File.mkdir_p!(project_root)

    write_workflow_file!(workflow_path,
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "JhihJian",
      tracker_repo: project_id,
      tracker_project_number: 1,
      workspace_root: Path.join([root, "workspaces", project_id])
    )

    project(project_id, "github", "github:jhihjian/#{project_id}", workflow_path, tracker_config_path, %{
      owner: "JhihJian",
      repo: project_id,
      project_number: 1
    })
  end

  defp write_gitlab_project!(root, project_id) do
    project_root = Path.join(root, "gitlab-#{project_id}")
    workflow_path = Path.join(project_root, "WORKFLOW.md")
    tracker_config_path = Path.join(project_root, "TRACKER.yaml")
    File.mkdir_p!(project_root)

    write_workflow_file!(workflow_path,
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com/api/v4",
      tracker_api_token: "token",
      tracker_project_slug: project_id,
      workspace_root: Path.join([root, "workspaces", "gitlab-#{project_id}"])
    )

    project(project_id, "gitlab", "gitlab:#{project_id}", workflow_path, tracker_config_path, %{project_slug: project_id})
  end

  defp project(project_id, kind, provider_scope_key, workflow_path, tracker_config_path, provider_scope) do
    %{
      project_id: project_id,
      status: :ready,
      load_error: nil,
      workflow_path: workflow_path,
      tracker_config_path: tracker_config_path,
      tracker_summary: %{
        kind: kind,
        provider_scope_key: provider_scope_key,
        provider_scope: provider_scope
      }
    }
  end

  defp cutover_gate(project_id, decision, opts) do
    %{
      projects: [
        %{
          project_id: project_id,
          migration_state: "hub_managed",
          decision: decision,
          allowed_operations: Keyword.get(opts, :allowed_operations, []),
          blocked_operations: Keyword.get(opts, :blocked_operations, ["poll", "dispatch", "worker_start", "writeback"]),
          blocking_reasons:
            opts
            |> Keyword.get(:reasons, [])
            |> Enum.map(&%{code: &1, source: "cutover_gate", level: "blocking"}),
          required_operator_actions: [%{code: "accept_activation_plan"}]
        }
      ]
    }
  end

  defp tmp_root(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end
end
