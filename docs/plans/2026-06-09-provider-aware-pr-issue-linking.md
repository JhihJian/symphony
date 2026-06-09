# Provider-Aware PR Issue Linking Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use summ:executing-plans to implement this plan task-by-task.

**Goal:** 让 GitHub/GitLab issue 来源下创建的 PR/MR 描述包含平台可识别的关闭关键字，避免继续写入 Linear 专用引用。

**Architecture:** 在 PromptBuilder 渲染给 agent 的上下文中注入 tracker-aware 的 `issue.closing_reference` 与 `issue.closing_instruction`，由现有工作流提示词和 PR 模板要求 agent 写入对应关闭行。PR body 校验从 Linear 专用尾行改为通用 `Issue: <closing reference>` 格式，并接受 GitHub/GitLab 的 `Closes #N` / `Closes owner/repo#N` / `Closes group/project#N`。

**Tech Stack:** Elixir、ExUnit、Solid 模板、Mix task。

---

### Task 1: 回归测试覆盖 GitHub/GitLab closing reference

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/test/mix/tasks/pr_body_check_test.exs`

**Step 1: Write the failing tests**

新增 PromptBuilder 测试：
- GitHub tracker + `owner/repo#3` issue identifier 渲染 `issue.closing_reference == "Closes #3"`。
- GitLab tracker + `group/project#7` issue identifier 渲染 `issue.closing_reference == "Closes #7"`。
- GitHub 跨仓库 identifier 渲染 `Closes other-org/other-repo#9`。

更新 PR body checker 测试：
- 通用中文模板正文使用 `Issue: Closes #26` 通过。
- 只写 `Linear: JIE-26` 不再作为当前仓库模板要求。

**Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/core_test.exs:<line> test/mix/tasks/pr_body_check_test.exs:<line>`
Expected: FAIL because `issue.closing_reference` is currently not available and template/checker still assumes Linear.

### Task 2: 实现 provider-aware PromptBuilder fields

**Files:**
- Modify: `elixir/lib/symphony_elixir/prompt_builder.ex`

**Step 1: Add minimal implementation**

在转为 Solid map 前补充：
- `issue.tracker_kind`
- `issue.closing_reference`
- `issue.closing_instruction`

GitHub/GitLab 规则：
- 与配置仓库/项目一致时使用 `Closes #N`。
- 跨 scope 时保留完整 identifier：`Closes owner/repo#N` 或 `Closes group/project#N`。
- Linear 保留 `Linear: <identifier>`，不声明自动关闭。

**Step 2: Run focused tests**

Run targeted PromptBuilder tests until green.

### Task 3: 更新模板、prompt 和校验测试

**Files:**
- Modify: `.github/pull_request_template.md`
- Modify: `.codex/skills/push/SKILL.md`
- Modify: `elixir/WORKFLOW.md`
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/test/mix/tasks/pr_body_check_test.exs`
- Modify: `elixir/README.md`

**Step 1: Replace Linear-specific PR body requirement**

把模板尾行改为 `Issue: <!-- e.g. Closes #123, Closes owner/repo#123, or Linear: ABC-123 -->`。

**Step 2: Update runtime instructions**

让 agent 在 PR/MR 描述中使用 `{{ issue.closing_reference }}`，并说明 GitHub/GitLab 合并后会自动关闭关联 issue。

**Step 3: Run validation**

Run:
- `mix test test/symphony_elixir/core_test.exs test/mix/tasks/pr_body_check_test.exs`
- `mix specs.check`
- `make all`
