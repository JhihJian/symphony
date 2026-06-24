---
workflow:
  start_stage: ready
  terminal_stages:
    - done
    - blocked
  outcomes:
    - started
    - needs_review
    - approved
    - changes_requested
    - merged
    - blocked
  missing_outcome:
    max_retries: 3
    on_exhausted: blocked
  stages:
    ready:
      prompt: |
        You are working on tracker issue `{{ issue.identifier }}`.

        {% if attempt %}
        Continuation context:

        - This is retry attempt #{{ attempt }} because the ticket is still active.
        - Resume from the current workspace state instead of restarting from scratch.
        - Do not repeat already-completed investigation or validation unless needed for new code changes.
        - Do not end the turn while the issue remains active unless blocked by missing required permissions, secrets, or external services.
        {% endif %}

        Issue context:
        Identifier: {{ issue.identifier }}
        Tracker: {{ issue.tracker_kind }}
        Title: {{ issue.title }}
        Current status: {{ issue.state }}
        Labels: {{ issue.labels }}
        URL: {{ issue.url }}
        PR issue reference: {{ issue.closing_reference }}

        {{ issue.closing_instruction }}

        Description:
        {% if issue.description %}
        {{ issue.description }}
        {% else %}
        No description provided.
        {% endif %}

        Instructions:

        1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
        2. Only stop early for a true blocker: missing required auth, permissions, secrets, or external service availability.
        3. Work only in the provided repository copy. Do not touch any other path.
        4. Start by reading the issue and comments, then maintain one persistent `## Codex Workpad` comment.
        5. Before implementation, record the plan, acceptance criteria, and validation approach in the workpad.
        6. When implementation is complete, run validation that matches the changed scope.
        7. If code needs to be submitted, create a clear commit and PR. The PR body must include `Issue: {{ issue.closing_reference }}`.
        8. When changing tracker state, use the tracker tool provided by the runtime.
        9. Final handoff must record completion summary, validation results, commit, and PR link in the workpad.

        Human-readable delivery requirements:

        - Immediately below the workpad environment stamp, maintain a concise Chinese `### 完成摘要` section before `### 计划`.
        - Keep `### 完成摘要` current throughout the run. At kickoff use honest placeholders such as `待完成`; before handoff replace them with final facts.
        - The summary must use this shape:

          ```md
          ### 完成摘要

          - 业务结果：<一句话说明用户或项目现在获得了什么>
          - 关键变化：<1-4 条主要改动>
          - 影响范围：<页面、模块、数据流或配置>
          - 验证结果：<核心验证命令和结果>
          - PR：<PR URL 或 暂无>
          - Commit：<最终 commit SHA 和标题>
          ```

        - 详细执行过程继续保留在 `### 计划`、`### 验证`、`### 备注`、`### 阻塞` 或 `### 疑问` 中，但详细日志不能替代完成摘要。
        - Commit message for non-trivial changes must include readable Chinese `变更`、`原因`、`验证` sections.
      transitions:
        started: in_progress
        blocked: blocked
    in_progress:
      prompt: |
        Implement the accepted scope for `{{ issue.identifier }}`.

        Keep the workpad current, preserve unrelated user changes, update docs for behavior or config changes, and run validation before handoff.
      transitions:
        needs_review: human_review
        blocked: blocked
    human_review:
      prompt: |
        Prepare validated work for review.

        Ensure the PR body is current, validation results are recorded, and every actionable review comment has either been addressed or explicitly answered.
      transitions:
        approved: merging
        changes_requested: rework
        blocked: blocked
    rework:
      prompt: |
        Address requested changes for `{{ issue.identifier }}`.

        Re-read the feedback, update code/tests/docs as needed, rerun validation, and return the issue to review when complete.
      transitions:
        needs_review: human_review
        blocked: blocked
    merging:
      prompt: |
        Land approved work for `{{ issue.identifier }}`.

        Follow the repository landing flow, monitor checks and conflicts, and record the final result in the workpad.
      transitions:
        merged: done
        blocked: blocked
    done:
      prompt: |
        Terminal completion stage.
      transitions: {}
    blocked:
      prompt: |
        Terminal blocked stage.
      transitions: {}
---
