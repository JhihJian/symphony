defmodule Mix.Tasks.PrBody.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.PrBody.Check

  import ExUnit.CaptureIO

  @template """
  #### Context

  <!-- Why is this change needed? -->

  #### TL;DR

  *<!-- A short summary -->*

  #### Summary

  - <!-- Summary bullet -->

  #### Alternatives

  - <!-- Alternative bullet -->

  #### Test Plan

  - [ ] <!-- Test checkbox -->
  """

  @valid_body """
  #### Context

  Context text.

  #### TL;DR

  Short summary.

  #### Summary

  - First change.

  #### Alternatives

  - Alternative considered.

  #### Test Plan

  - [x] Ran targeted checks.
  """

  setup do
    Mix.Task.reenable("pr_body.check")
    :ok
  end

  test "prints help" do
    output = capture_io(fn -> Check.run(["--help"]) end)
    assert output =~ "mix pr_body.check --file /path/to/pr_body.md"
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      Check.run(["lint", "--wat"])
    end
  end

  test "fails when file option is missing" do
    assert_raise Mix.Error, ~r/Missing required option --file/, fn ->
      Check.run(["lint"])
    end
  end

  test "fails when template is missing" do
    in_temp_repo(fn ->
      File.write!("body.md", @valid_body)

      assert_raise Mix.Error, ~r/Unable to read PR template/, fn ->
        Check.run(["lint", "--file", "body.md"])
      end
    end)
  end

  test "fails when template has no headings" do
    in_temp_repo(fn ->
      write_template!("no headings here")
      File.write!("body.md", @valid_body)

      assert_raise Mix.Error, ~r/No markdown headings found/, fn ->
        Check.run(["lint", "--file", "body.md"])
      end
    end)
  end

  test "fails when body file is missing" do
    in_temp_repo(fn ->
      write_template!(@template)

      assert_raise Mix.Error, ~r/Unable to read missing\.md/, fn ->
        Check.run(["lint", "--file", "missing.md"])
      end
    end)
  end

  test "fails when body still has placeholders" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", @template)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "PR description still contains template placeholder comments"
    end)
  end

  test "fails when heading is missing" do
    in_temp_repo(fn ->
      write_template!(@template)

      missing_heading = String.replace(@valid_body, "#### Alternatives\n\n- Alternative considered.\n\n", "")
      File.write!("body.md", missing_heading)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Missing required heading: #### Alternatives"
    end)
  end

  test "fails when headings are out of order" do
    in_temp_repo(fn ->
      write_template!(@template)

      out_of_order = """
      #### TL;DR

      Short summary.

      #### Context

      Context text.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [x] Ran targeted checks.
      """

      File.write!("body.md", out_of_order)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Required headings are out of order."
    end)
  end

  test "fails on empty section" do
    in_temp_repo(fn ->
      write_template!(@template)

      empty_context = String.replace(@valid_body, "Context text.", "")
      File.write!("body.md", empty_context)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: #### Context"
    end)
  end

  test "fails when a middle section is blank before the next heading" do
    in_temp_repo(fn ->
      write_template!(@template)

      blank_alternatives = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives


      #### Test Plan

      - [x] Ran targeted checks.
      """

      File.write!("body.md", blank_alternatives)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: #### Alternatives"
    end)
  end

  test "fails when bullet and checkbox expectations are not met" do
    in_temp_repo(fn ->
      write_template!(@template)

      invalid_body = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      Not a bullet.

      #### Alternatives

      Also not a bullet.

      #### Test Plan

      No checkbox.
      """

      File.write!("body.md", invalid_body)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section must include at least one bullet item: #### Summary"
      assert error_output =~ "Section must include at least one bullet item: #### Alternatives"
      assert error_output =~ "Section must include at least one bullet item: #### Test Plan"
      assert error_output =~ "Section must include at least one checkbox item: #### Test Plan"
    end)
  end

  test "fails when heading has no content delimiter" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", "#### Context\nContext text.")

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
          Check.run(["lint", "--file", "body.md"])
        end
      end)
    end)
  end

  test "fails when heading appears at end of file" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", "#### Context")

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: #### Context"
    end)
  end

  test "passes for valid body" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", @valid_body)

      output =
        capture_io(fn ->
          Check.run(["lint", "--file", "body.md"])
        end)

      assert output =~ "PR body format OK"
    end)
  end

  test "passes for Chinese level-two repository template" do
    in_temp_repo(fn ->
      write_template!("""
      ## 变更说明

      - <!-- 说明行为变化 -->

      ## 影响范围

      - <!-- 说明页面、模块、数据流或配置 -->

      ## 验证

      - [ ] `make -C elixir all`

      ## 风险与限制

      - <!-- 无 / 已知限制 -->

      Issue: <!-- e.g. Closes #123 -->
      """)

      File.write!("body.md", """
      ## 变更说明

      - 让 PR 描述使用统一中文结构。

      ## 影响范围

      - 影响 PR body 模板和本地格式检查。

      ## 验证

      - [x] `make -C elixir all`

      ## 风险与限制

      - 无。

      Issue: Closes #26
      """)

      output =
        capture_io(fn ->
          Check.run(["lint", "--file", "body.md"])
        end)

      assert output =~ "PR body format OK"
    end)
  end

  test "repository template no longer accepts stale Linear-only issue linkage" do
    in_temp_repo(fn ->
      write_template!("""
      ## 变更说明

      - <!-- 说明行为变化 -->

      ## 影响范围

      - <!-- 说明页面、模块、数据流或配置 -->

      ## 验证

      - [ ] `make -C elixir all`

      ## 风险与限制

      - <!-- 无 / 已知限制 -->

      Issue: <!-- e.g. Closes #123 -->
      """)

      File.write!("body.md", """
      ## 变更说明

      - 让 PR 描述使用统一中文结构。

      ## 影响范围

      - 影响 PR body 模板和本地格式检查。

      ## 验证

      - [x] `make -C elixir all`

      ## 风险与限制

      - 无。

      Linear: JIE-26
      """)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Missing required template line: Issue:"
    end)
  end

  test "repository template accepts qualified GitHub and GitLab issue references" do
    in_temp_repo(fn ->
      write_template!(chinese_template_with_issue_line())

      for linkage <- ["Issue: Closes openai/symphony#26", "Issue: Resolves platform/symphony#7"] do
        File.write!("body.md", valid_chinese_body(linkage))

        output =
          capture_io(fn ->
            Check.run(["lint", "--file", "body.md"])
          end)

        assert output =~ "PR body format OK"
        Mix.Task.reenable("pr_body.check")
      end
    end)
  end

  test "repository template accepts Linear references under the Issue line" do
    in_temp_repo(fn ->
      write_template!(chinese_template_with_issue_line())
      File.write!("body.md", valid_chinese_body("Issue: Linear: JIE-26"))

      output =
        capture_io(fn ->
          Check.run(["lint", "--file", "body.md"])
        end)

      assert output =~ "PR body format OK"
    end)
  end

  test "repository template rejects empty issue linkage line" do
    in_temp_repo(fn ->
      write_template!(chinese_template_with_issue_line())
      File.write!("body.md", valid_chinese_body("Issue:   "))

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Issue linkage line cannot be empty."
    end)
  end

  test "repository template rejects unsupported issue linkage values" do
    in_temp_repo(fn ->
      write_template!(chinese_template_with_issue_line())
      File.write!("body.md", valid_chinese_body("Issue: Related #26"))

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Issue linkage line must use a supported closing reference or Linear reference."
    end)
  end

  defp in_temp_repo(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "validate-pr-body-task-test-#{unique}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    original_cwd = File.cwd!()

    try do
      File.cd!(root)
      fun.()
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  defp write_template!(content) do
    File.mkdir_p!(".github")
    File.write!(".github/pull_request_template.md", content)
  end

  defp chinese_template_with_issue_line do
    """
    ## 变更说明

    - <!-- 说明行为变化 -->

    ## 影响范围

    - <!-- 说明页面、模块、数据流或配置 -->

    ## 验证

    - [ ] `make -C elixir all`

    ## 风险与限制

    - <!-- 无 / 已知限制 -->

    Issue: <!-- e.g. Closes #123 -->
    """
  end

  defp valid_chinese_body(linkage) do
    """
    ## 变更说明

    - 让 PR 描述使用统一中文结构。

    ## 影响范围

    - 影响 PR body 模板和本地格式检查。

    ## 验证

    - [x] `make -C elixir all`

    ## 风险与限制

    - 无。

    #{linkage}
    """
  end
end
