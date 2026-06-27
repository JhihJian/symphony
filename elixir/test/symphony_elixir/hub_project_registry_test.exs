defmodule SymphonyElixir.HubProjectRegistryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.ProjectRegistry

  test "loads multiple hub projects into safe observable snapshots" do
    root = tmp_root("hub-project-registry")
    hub_path = Path.join(root, "HUB.yaml")
    alpha_dir = Path.join(root, "alpha")
    beta_dir = Path.join(root, "beta")

    try do
      File.mkdir_p!(alpha_dir)
      File.mkdir_p!(beta_dir)

      alpha_workflow = Path.join(alpha_dir, "WORKFLOW.md")
      beta_workflow = Path.join(beta_dir, "WORKFLOW.md")

      write_workflow_file!(alpha_workflow,
        tracker_kind: "github",
        tracker_api_token: "$GITHUB_TOKEN",
        tracker_owner: "JhihJian",
        tracker_repo: "symphony",
        tracker_project_number: 3,
        tracker_required_labels: ["symphony"],
        workspace_root: Path.join([root, "workspaces", "alpha"]),
        max_concurrent_agents: 2,
        poll_interval_ms: 45_000,
        server_port: 20_001
      )

      write_workflow_file!(beta_workflow,
        tracker_kind: "gitlab",
        tracker_api_token: "$GITLAB_TOKEN",
        tracker_project_slug: "platform/beta",
        workspace_root: Path.join([root, "workspaces", "beta"]),
        max_concurrent_agents: 4,
        poll_interval_ms: 60_000,
        server_port: 20_002
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          name: Alpha Project
          workflow_path: alpha/WORKFLOW.md
          dispatch_enabled: true
        - project_id: beta
          workflow_path: beta/WORKFLOW.md
          tracker_config_path: beta/TRACKER.yaml
          paused: true
      """)

      assert {:ok, registry} = ProjectRegistry.load(hub_path)
      assert registry.errors == []
      assert registry.warnings == []

      assert [alpha, beta] = registry.projects

      assert alpha.project_id == "alpha"
      assert alpha.name == "Alpha Project"
      assert alpha.dispatch_enabled == true
      assert alpha.paused == false
      assert alpha.status == :ready
      assert alpha.workflow_path == alpha_workflow
      assert alpha.tracker_config_path == Path.join(alpha_dir, "TRACKER.yaml")
      assert alpha.workflow_summary.start_stage == "ready"
      assert alpha.workflow_summary.terminal_stages == ["done", "blocked", "protocol_blocked"]
      assert "in_progress" in alpha.workflow_summary.stage_ids
      assert alpha.tracker_summary.kind == "github"
      assert alpha.tracker_summary.provider_scope == %{owner: "JhihJian", repo: "symphony", project_number: 3}
      assert alpha.tracker_summary.provider_scope_key == "github:jhihjian/symphony"
      assert alpha.tracker_summary.required_labels == ["symphony"]
      assert alpha.runtime_summary.workspace_root == Path.join([root, "workspaces", "alpha"])
      assert alpha.runtime_summary.max_concurrent_agents == 2
      assert alpha.runtime_summary.polling_interval_ms == 45_000
      assert alpha.runtime_summary.server_port == 20_001
      assert String.length(alpha.fingerprint) == 64
      assert alpha.load_error == nil

      assert beta.project_id == "beta"
      assert beta.dispatch_enabled == false
      assert beta.paused == true
      assert beta.status == :paused
      assert beta.tracker_summary.kind == "gitlab"
      assert beta.tracker_summary.provider_scope == %{project_slug: "platform/beta"}
      assert beta.tracker_summary.provider_scope_key == "gitlab:platform/beta"
      assert beta.runtime_summary.max_concurrent_agents == 4
      assert beta.runtime_summary.polling_interval_ms == 60_000

      refute snapshot_contains?(registry, "GITHUB_TOKEN")
      refute snapshot_contains?(registry, "GITLAB_TOKEN")
      refute snapshot_contains?(registry, "api_key")
      refute snapshot_contains?(registry, "credential")
    after
      File.rm_rf(root)
    end
  end

  test "isolates invalid project configuration without discarding valid snapshots" do
    root = tmp_root("hub-project-errors")
    hub_path = Path.join(root, "HUB.yaml")
    good_dir = Path.join(root, "good")
    bad_dir = Path.join(root, "bad")

    try do
      File.mkdir_p!(good_dir)
      File.mkdir_p!(bad_dir)

      good_workflow = Path.join(good_dir, "WORKFLOW.md")
      bad_workflow = Path.join(bad_dir, "WORKFLOW.md")

      write_workflow_file!(good_workflow,
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "good"])
      )

      write_workflow_file!(bad_workflow,
        tracker_kind: "github",
        tracker_api_token: "$GITHUB_TOKEN",
        tracker_owner: "JhihJian",
        tracker_repo: nil,
        workspace_root: Path.join([root, "workspaces", "bad"])
      )

      File.write!(hub_path, """
      projects:
        - project_id: good
          workflow_path: good/WORKFLOW.md
        - project_id: bad
          workflow_path: bad/WORKFLOW.md
      """)

      assert {:ok, registry} = ProjectRegistry.load(hub_path)
      assert [good, bad] = registry.projects

      assert good.status == :ready
      assert good.tracker_summary.provider_scope == %{namespace: "good"}
      assert good.load_error == nil

      assert bad.status == :error
      assert bad.paused == true
      assert bad.workflow_path == bad_workflow
      assert bad.tracker_config_path == Path.join(bad_dir, "TRACKER.yaml")
      assert bad.load_error =~ "missing tracker.repo"
      assert bad.fingerprint == nil
      assert bad.tracker_summary == nil
    after
      File.rm_rf(root)
    end
  end

  test "rejects duplicate and unsafe project ids before loading projects" do
    root = tmp_root("hub-project-id-validation")
    hub_path = Path.join(root, "HUB.yaml")
    workflow_path = Path.join(root, "WORKFLOW.md")

    try do
      File.mkdir_p!(root)
      write_workflow_file!(workflow_path)

      File.write!(hub_path, """
      projects:
        - project_id: dup
          workflow_path: WORKFLOW.md
        - project_id: dup
          workflow_path: WORKFLOW.md
      """)

      assert {:error, {:duplicate_project_id, "dup", [0, 1]}} = ProjectRegistry.load(hub_path)

      File.write!(hub_path, """
      projects:
        - project_id: "../bad"
          workflow_path: WORKFLOW.md
      """)

      assert {:error, {:invalid_project_id, "../bad", message}} = ProjectRegistry.load(hub_path)
      assert message =~ "path separators"
    after
      File.rm_rf(root)
    end
  end

  test "detects cross-project resource conflicts" do
    root = tmp_root("hub-project-conflicts")
    hub_path = Path.join(root, "HUB.yaml")
    one_dir = Path.join(root, "one")
    two_dir = Path.join(root, "two")
    shared_workspace = Path.join([root, "workspaces", "shared"])

    try do
      File.mkdir_p!(one_dir)
      File.mkdir_p!(two_dir)

      write_workflow_file!(Path.join(one_dir, "WORKFLOW.md"),
        tracker_kind: "github",
        tracker_api_token: "$GITHUB_TOKEN",
        tracker_owner: "JhihJian",
        tracker_repo: "symphony",
        tracker_project_number: 3,
        workspace_root: shared_workspace,
        server_port: 20_050
      )

      write_workflow_file!(Path.join(two_dir, "WORKFLOW.md"),
        tracker_kind: "github",
        tracker_api_token: "$GITHUB_TOKEN",
        tracker_owner: "jhihjian",
        tracker_repo: "Symphony",
        tracker_project_number: 3,
        workspace_root: shared_workspace,
        server_port: 20_050
      )

      File.write!(hub_path, """
      projects:
        - project_id: one
          workflow_path: one/WORKFLOW.md
        - project_id: two
          workflow_path: two/WORKFLOW.md
      """)

      assert {:ok, registry} = ProjectRegistry.load(hub_path)
      assert Enum.map(registry.warnings, & &1.code) == [:shared_workspace_root, :shared_provider_scope]
      assert Enum.map(registry.errors, & &1.code) == [:shared_dashboard_port]

      assert Enum.all?(registry.warnings ++ registry.errors, fn message ->
               message.project_ids == ["one", "two"]
             end)
    after
      File.rm_rf(root)
    end
  end

  defp tmp_root(name) do
    Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive, :monotonic])}")
  end

  defp snapshot_contains?(registry, value) do
    registry
    |> inspect()
    |> String.contains?(value)
  end
end
