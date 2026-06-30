# Human-Readable Delivery Examples

This document shows the expected delivery shape for Symphony-managed issues.
The detailed execution log should still stay in the workpad, but it must not
replace the top-level completion summary.

## Linear Workpad

````md
## Codex Workpad

这是 Codex 持久工作记录，用于集中维护本 issue 的计划、进度、验证与交付摘要。

```text
devbox-01:/home/dev-user/code/symphony-workspaces/JIE-26@abc1234
```

### 完成摘要

- 业务结果：维护者打开 Linear 后能先看到交付结论，而不是先读执行日志。
- 关键变化：新增固定完成摘要；commit 使用中文正文；PR body 使用统一中文结构。
- 影响范围：`WORKFLOW.md`、`commit` skill、`push` skill、PR 模板。
- 验证结果：`mix test test/symphony_elixir/core_test.exs:118` 通过。
- PR：https://github.com/openai/symphony/pull/123
- Commit：abc1234 docs: 统一自动交付内容格式

### 计划

- [x] 1. 更新交付模板
- [x] 2. 验证模板要求

### 验证

- [x] `mix test test/symphony_elixir/core_test.exs:118`

### 备注

- 2026-05-14：详细执行记录保留在这里，但不替代完成摘要。
````

## Commit Message

```text
docs(workflow): 统一自动交付内容格式

变更：
- Linear workpad 顶部固定展示中文完成摘要。
- commit message 默认使用中文 `变更 / 原因 / 验证` 正文。
- PR body 使用中文结构呈现变更、影响、验证和风险。

原因：
- 维护者需要先读到业务结果、影响范围和验证结论，再按需查看细节。
- 详细日志信息量高但不适合替代交付摘要。

验证：
- mix test test/symphony_elixir/core_test.exs:118
- mix test test/mix/tasks/pr_body_check_test.exs:319

Co-authored-by: Codex <codex@openai.com>
```

## PR Body

```md
## 变更说明

- 在 Symphony workflow 中加入 Linear 完成摘要要求。
- 将 commit 和 PR 交付文本统一为中文可读结构。

## 影响范围

- 影响默认 `WORKFLOW.md`、`.codex/skills/commit/SKILL.md`、
  `.codex/skills/push/SKILL.md` 和 `.github/pull_request_template.md`。

## 验证

- [x] `make -C elixir all`

## 风险与限制

- 无。

Linear: JIE-26
```
