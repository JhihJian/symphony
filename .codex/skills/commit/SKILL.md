---
name: commit
description:
  Create a well-formed git commit from current changes using session history for
  rationale and summary; use when asked to commit, prepare a commit message, or
  finalize staged work.
---

# Commit

## Goals

- Produce a commit that reflects the actual code changes and the session
  context.
- Follow common git conventions (type prefix, short subject, wrapped body).
- Include readable Chinese `变更`、`原因`、`验证` sections in the body.

## Inputs

- Codex session history for intent and rationale.
- `git status`, `git diff`, and `git diff --staged` for actual changes.
- Repo-specific commit conventions if documented.

## Steps

1. Read session history to identify scope, intent, and rationale.
2. Inspect the working tree and staged changes (`git status`, `git diff`,
   `git diff --staged`).
3. Stage intended changes, including new files (`git add -A`) after confirming
   scope.
4. Sanity-check newly added files; if anything looks random or likely ignored
   (build artifacts, logs, temp files), flag it to the user before committing.
5. If staging is incomplete or includes unrelated files, fix the index or ask
   for confirmation.
6. Choose a conventional type and optional scope that match the change (e.g.,
   `feat(scope): ...`, `fix(scope): ...`, `refactor(scope): ...`).
7. Write a subject line in conventional format, <= 72 characters, no trailing
   period. Prefer a Chinese summary that explains the user-visible or
   maintainer-visible outcome without requiring the diff.
8. 禁止非微小改动只有一行 commit message. Only genuinely tiny mechanical
   changes may use a one-line commit.
9. Write a Chinese body that includes:
   - `变更`：behavioral changes, not just a list of file names.
   - `原因`：why the change is needed plus important trade-offs or risk controls.
   - `验证`：only commands actually run, or an explicit not-run reason.
10. Ensure one commit contains one logical topic. Split unrelated changes before
    committing.
11. Append a `Co-authored-by` trailer for Codex using `Codex <codex@openai.com>`
   unless the user explicitly requests a different identity.
12. Wrap body lines at 72 characters when practical.
13. Create the commit message with a here-doc or temp file and use
    `git commit -F <file>` so newlines are literal (avoid `-m` with `\n`).
14. Commit only when the message matches the staged changes: if the staged diff
    includes unrelated files or the message describes work that isn't staged,
    fix the index or revise the message before committing.

## Output

- A single commit created with `git commit` whose message reflects the session.

## Template

Type and scope are examples only; adjust to fit the repo and changes.

```
<type>(<scope>): <中文摘要>

变更：
- <具体行为变化>
- <具体行为变化>

原因：
- <为什么需要这样改>
- <重要取舍或风险控制>

验证：
- <实际运行的命令>
- <实际运行的命令或未运行原因>

Co-authored-by: Codex <codex@openai.com>
```
