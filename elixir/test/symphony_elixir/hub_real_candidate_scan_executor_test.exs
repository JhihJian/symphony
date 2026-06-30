defmodule SymphonyElixir.HubRealCandidateScanExecutorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{ProviderGovernance, RealCandidateScanExecutor}

  test "rejects unsupported provider kinds without provider I/O" do
    request =
      provider_request!(
        project_id: "linear-alpha",
        provider_scope: %{kind: "unknown", key: "unknown:alpha", scope: %{project_slug: "alpha"}},
        operation_kind: :candidate_scan,
        logical_key: "hub-poll:linear-alpha:candidate_scan"
      )

    result = RealCandidateScanExecutor.execute(request, registry: registry([project("linear-alpha", "unknown", "unknown:alpha")]))

    assert result.status == :permanent_failure
    assert result.error_class == :validation
    assert result.result_summary.error == "unsupported_provider"
    assert result.result_summary.provider_io == false
  end

  test "rejects non candidate scan operations explicitly" do
    request =
      provider_request!(
        project_id: "alpha",
        provider_scope: %{kind: "memory", key: "memory:alpha", scope: %{namespace: "alpha"}},
        operation_kind: :stage_writeback,
        logical_key: "hub-poll:alpha:stage_writeback"
      )

    result = RealCandidateScanExecutor.execute(request, registry: registry([project("alpha", "memory", "memory:alpha")]))

    assert result.status == :permanent_failure
    assert result.error_class == :validation
    assert result.result_summary.error == "unsupported_operation"
    assert result.result_summary.provider_io == false
  end

  test "rejects request scope mismatches before loading project settings" do
    request =
      provider_request!(
        project_id: "alpha",
        provider_scope: %{kind: "memory", key: "memory:other", scope: %{namespace: "other"}},
        operation_kind: :candidate_scan,
        logical_key: "hub-poll:alpha:candidate_scan"
      )

    result = RealCandidateScanExecutor.execute(request, registry: registry([project("alpha", "memory", "memory:alpha")]))

    assert result.status == :permanent_failure
    assert result.error_class == :validation
    assert result.result_summary.error == "scope_mismatch"
    assert result.result_summary.reason == "provider_scope_key_mismatch"
  end

  test "cutover gate blocks candidate scan before project settings or provider I/O" do
    request =
      provider_request!(
        project_id: "alpha",
        provider_scope: %{kind: "memory", key: "memory:alpha", scope: %{namespace: "alpha"}},
        operation_kind: :candidate_scan,
        logical_key: "hub-poll:alpha:candidate_scan"
      )

    result =
      RealCandidateScanExecutor.execute(request,
        registry: registry([project("alpha", "memory", "memory:alpha")]),
        cutover_gate: cutover_gate("alpha", "blocked", blocked_operations: ["poll"], reasons: ["operator_acknowledgement_missing"])
      )

    assert result.status == :permanent_failure
    assert result.error_class == :conflict
    assert result.result_summary.error == "cutover_gate_blocked"
    assert result.result_summary.provider_io == false
    assert "poll" in result.result_summary.blocked_operations
  end

  test "does not expose raw provider error payloads in result summaries" do
    root = Path.join(System.tmp_dir!(), "hub-real-candidate-safe-errors-#{System.unique_integer([:positive])}")

    try do
      project = write_memory_project!(root, "alpha")

      Application.put_env(:symphony_elixir, :memory_tracker_issues_by_project, %{
        "alpha" =>
          {:error,
           %{
             raw_provider_body: "full issue body with ghp_secret_token",
             authorization: "Bearer ghp_secret_token",
             message: "provider returned an ambiguous payload"
           }}
      })

      request =
        provider_request!(
          project_id: "alpha",
          provider_scope: %{kind: "memory", key: "memory:alpha", scope: %{namespace: "alpha"}},
          operation_kind: :candidate_scan,
          logical_key: "hub-poll:alpha:candidate_scan"
        )

      result = RealCandidateScanExecutor.execute(request, registry: registry([project]))

      assert result.status == :unknown_result
      assert result.result_summary.error == "provider_error"
      assert result.result_summary.reason == "map"

      safe_text = inspect(result)
      refute safe_text =~ "ghp_secret_token"
      refute safe_text =~ "full issue body"
      refute safe_text =~ "raw_provider_body"
      refute safe_text =~ "authorization"
    after
      File.rm_rf(root)
    end
  end

  defp registry(projects), do: %{projects: projects, warnings: [], errors: []}

  defp project(project_id, kind, provider_scope_key) do
    %{
      project_id: project_id,
      status: :ready,
      load_error: nil,
      workflow_path: "/tmp/#{project_id}/WORKFLOW.md",
      tracker_config_path: "/tmp/#{project_id}/TRACKER.yaml",
      tracker_summary: %{
        kind: kind,
        provider_scope_key: provider_scope_key,
        provider_scope: %{namespace: project_id}
      }
    }
  end

  defp provider_request!(attrs) do
    assert {:ok, request} = ProviderGovernance.new_request(Map.new(attrs))
    request
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

    %{
      project_id: project_id,
      status: :ready,
      load_error: nil,
      workflow_path: workflow_path,
      tracker_config_path: tracker_config_path,
      tracker_summary: %{
        kind: "memory",
        provider_scope_key: "memory:#{project_id}",
        provider_scope: %{namespace: project_id}
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
end
