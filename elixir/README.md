# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## 仪表盘界面

Phoenix 观测界面使用内嵌静态资源提供，不需要 Node 构建链。`/`、`/workflow`
和 `/admin/instances` 共享一套极简操作台视觉系统：暖白画布、细边框卡片、克制
状态色、编辑感标题字体和基于 IntersectionObserver 的轻量进入动效。样式入口仍是
`priv/static/dashboard.css`，交互入口仍是 `priv/static/dashboard.js`。

## How it works

1. Polls Linear, GitHub Issues, or GitLab Issues for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During Linear-backed app-server sessions, Symphony also serves a client-side `linear_graphql` tool
so that repo skills can make raw Linear GraphQL calls.

For GitHub Issues and GitLab Issues, rendered workflow prompts expose
`{{ issue.closing_reference }}` and `{{ issue.closing_instruction }}`. Use that reference in PR/MR
descriptions as `Issue: Closes #123` or a fully qualified cross-project reference so the provider
links the change and closes the issue automatically when the PR/MR is merged.

If a claimed issue moves to a completion terminal stage such as `done`, Symphony stops the active
agent for that issue and cleans up matching workspaces. Blocked terminal stages such as `blocked`
or `protocol_blocked` are not completion: Symphony keeps the claim visible as blocked and preserves
the workspace or a local recovery artifact.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Configure a tracker token:
   - Linear: set `LINEAR_API_KEY`.
   - GitHub Issues: set `GITHUB_TOKEN`.
   - GitLab Issues: set `GITLAB_TOKEN`.
3. Copy this directory's `WORKFLOW.md` and `TRACKER.yaml` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied files for your project.
   - `WORKFLOW.md` defines provider-neutral workflow stages, outcomes, transitions, and stage
     work prompts. Symphony wraps those values in the system-maintained stage prompt template and
     supplies the structured stage outcome channel at runtime.
   - `TRACKER.yaml` defines provider access, workspace/runtime settings, and maps workflow stages
     to provider-visible states under `tracker.stage_states`.
   - For Linear, `tracker.project_slug` in `TRACKER.yaml` is the Linear project slug from the
     project URL.
   - For GitLab, `tracker.project_slug` is the GitLab project path such as `group/project`, or a
     numeric project ID. To express fine-grained workflow states in GitLab labels, set
     `tracker.state_label_prefix`, for example `status::`.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony --tracker-config ./TRACKER.yaml ./WORKFLOW.md
```

## Configuration

Pass custom workflow and tracker config paths to `./bin/symphony` when starting the service:

```bash
./bin/symphony --tracker-config /path/to/custom/TRACKER.yaml /path/to/custom/WORKFLOW.md
```

If no workflow path is passed, Symphony defaults to `./WORKFLOW.md`. In workflow-stage mode, when
`--tracker-config` is omitted Symphony looks for `TRACKER.yaml` next to the selected `WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)
- `--tracker-config` explicitly selects the provider-specific tracker config file

`WORKFLOW.md` uses YAML front matter for the provider-neutral workflow-stage schema. `TRACKER.yaml`
contains provider access fields, stage-state mapping, workspace hooks, and runtime knobs.
Stage `prompt` values should describe only the work to do in that stage. Do not include dynamic tool
names, structured completion schemas, or required-tool implementation details in `WORKFLOW.md`; the
runner supplies the completion protocol and outcome tool internally.

In workflow-stage mode, a runner keeps one workspace and one app-server session while it advances
the issue through workflow stages. After each successful non-terminal turn, the agent must submit one
structured outcome; the runner computes the next stage from the current stage transitions, writes
that stage through `write_issue_stage(issue_id, next_stage)`, and immediately starts the next stage
turn on the same thread. Provider-visible state is updated for observability, not reread to decide
the next in-process stage.

Scheduler dispatch is stage-aware in workflow-stage mode. The orchestrator fetches runnable issues
only for `workflow.start_stage`, re-reads the issue stage immediately before dispatch, and skips
issues that have already moved to implementation, validation, blocked, done, or any other non-start
stage. Middle-stage progression stays inside the runner stage loop. A normal runner exit at a
completion terminal stage releases the claim and may clean the workspace; a normal runner exit at
`blocked`, `protocol_blocked`, `rework`, or another non-completion terminal stage records a blocked
entry instead. Abnormal/stalled retries refresh only the specific issue by id. If the issue is still
visible at the same non-terminal workflow stage, Symphony can re-dispatch it without requiring it to
move back to `workflow.start_stage`. If the provider-visible stage is a completion terminal stage,
the claim is released and the workspace is cleaned. If the provider-visible stage is a blocked
terminal stage, is unreadable, conflicts with the remembered running stage, is dependency-blocked,
or is no longer routable, Symphony keeps the claim in the local blocked map with retry context
instead of silently orphaning the provider item.

Low-frequency reconciliation still refreshes running and blocked issues by id. If an operator moves
a running issue to a completion terminal workflow stage, the orchestrator stops the worker and
removes the workspace. If it moves to a blocked terminal workflow stage, the orchestrator stops the
worker, keeps the claim blocked, and preserves recovery evidence. If the provider-visible stage
disagrees with the runner's local current stage, Symphony keeps the worker running, logs a
`Workflow stage conflict`, and exposes `current_stage` plus `stage_conflict` in the JSON API and
Live dashboard. Service restart recovery is currently provider state plus workspace metadata only:
running in-memory stage position is not durable, so after a restart a fresh dispatch is only
possible for issues visible in `workflow.start_stage`; issue-id-scoped running retry and blocked
context is in memory and is not restored after process restart.

For local workspaces, a blocked terminal outcome writes recovery evidence under
`.symphony/blocked/<timestamp>-<session>/` in the issue workspace. The artifact includes
`git status --short --branch`, diff stat, name-status, untracked-file list, a patch file, the
session id, and the blocked reason. Remote worker workspaces are retained and reported with their
host/path; remote artifact capture is intentionally not attempted by the local orchestrator.

Minimal example:

```md
---
workflow:
  start_stage: ready
  terminal_stages: [done, blocked, protocol_blocked]
  outcomes: [started, completed, blocked]
  missing_outcome:
    max_retries: 3
    on_exhausted: protocol_blocked
  stages:
    ready:
      prompt: |
        You are working on issue {{ issue.identifier }}.

        Title: {{ issue.title }}
        Body: {{ issue.description }}
      transitions:
        started: in_progress
        blocked: blocked
    in_progress:
      prompt: |
        Implement and validate the accepted scope.
      transitions:
        completed: done
        blocked: blocked
    done:
      prompt: Terminal completion stage.
      transitions: {}
    blocked:
      prompt: Terminal blocked stage.
      transitions: {}
    protocol_blocked:
      prompt: Terminal protocol blocked stage.
      transitions: {}
---
```

Matching `TRACKER.yaml`:

```yaml
tracker:
  kind: linear
  project_slug: "..."
  provider_states: [Todo, In Progress, Done, Cancelled, Protocol Blocked]
  stage_states:
    ready:
      state: Todo
    in_progress:
      state: In Progress
    done:
      state: Done
      terminal: true
    blocked:
      state: Cancelled
      terminal: true
    protocol_blocked:
      state: Protocol Blocked
      terminal: true
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` supports `linear`, `github`, `gitlab`, and `memory`.
- `tracker.stage_states` maps provider-neutral workflow stage ids to provider-visible states. These
  provider states are an external observable and recoverable record; they are not the normal trigger
  for progressing one issue through workflow stages.
- `tracker.workflow_state` can derive `stage_states` for provider-specific strategies. GitHub
  Project v2 Status uses `workflow_state.state_options`; GitLab scoped labels use
  `workflow_state.strategy: scoped_label` and `workflow_state.label_prefix`.
- The runner and recovery path use the same derived stage-state mapping, so a retry can resume from a
  provider-visible status such as GitHub Project v2 `In progress` even when `stage_states` is not
  written explicitly.
- The scheduler uses `tracker.stage_states[workflow.start_stage].state` for new candidate discovery.
- Memory, Linear, GitHub Project v2, and GitLab scoped-label trackers implement the workflow-stage
  dispatch contract. GitHub issues-only mode does not support multi-stage provider-visible workflow
  state and fails fast when configured for more than one visible stage state.
- The runner-internal stage outcome channel drives workflow transitions. Direct provider status
  writes through ordinary tracker tools may still be useful for comments or external metadata, but
  they are not accepted as the stage result.
- If a completed non-terminal turn submits no valid outcome, the runner retries the same stage up to
  `workflow.missing_outcome.max_retries`. After retries are exhausted, it writes
  `workflow.missing_outcome.on_exhausted`, commonly a terminal `protocol_blocked` stage.
- Terminal stages are classified by scheduler semantics, not only by provider state names.
  Completion terminals such as `done` may close provider-native issues and trigger workspace
  cleanup. Non-completion terminals such as `blocked`, `protocol_blocked`, or `rework` remain
  provider-visible but do not close the issue or delete the only workspace evidence.
- `tracker.provider_states` is optional. When present, Symphony validates every
  `tracker.stage_states.*.state` value against this declared provider-visible state set.
- Linear uses `tracker.project_slug` and defaults to `https://api.linear.app/graphql`.
- GitHub uses `tracker.owner` and `tracker.repo`; `tracker.project_number` is optional. When it is
  present, GitHub Project v2 Status is used for workflow stage state. GitHub native `CLOSED` remains
  terminal even if the Project Status field is stale. Project Status updates to non-completion
  terminal stages such as `Blocked` do not close the native GitHub issue; the issue should close
  through the linked PR/MR merge path or a completion terminal stage. When `project_number` is
  omitted, GitHub issues-only mode cannot represent multi-stage provider-visible workflow state.
- GitLab uses `tracker.project_slug` as the project path or ID and defaults to
  `https://gitlab.com/api/v4`. Scoped-label workflow state writes add the target label and remove
  other labels in that configured state-label group. `workflow_state.close_on_terminal` controls
  which terminal stages close the GitLab issue.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- Legacy provider fields in `WORKFLOW.md` front matter are rejected at runtime. Use
  `mix workflow.split_tracker_config` to migrate old single-file configs to `WORKFLOW.md` plus
  `TRACKER.yaml` before starting the service.

### Hub mode project registry

The Elixir implementation includes a model-only Hub mode project registry. Put multiple project
registrations in a `HUB.yaml` file and load it with `SymphonyElixir.Hub.ProjectRegistry.load/1`:

```yaml
projects:
  - project_id: symphony
    name: Symphony
    workflow_path: /path/to/symphony/WORKFLOW.md
    tracker_config_path: /path/to/symphony/TRACKER.yaml
    migration_state: hub_managed
    dispatch_enabled: true
  - project_id: docs
    workflow_path: ./docs/WORKFLOW.md
    migration_state: legacy_only
    paused: true
```

Fields:

- `project_id` is required, unique within the Hub registry, and limited to safe key characters:
  letters, numbers, `.`, `_`, and `-`. It cannot contain path separators, `..`, whitespace padding,
  newlines, or NUL.
- `name` is optional display text.
- `workflow_path` is required. Relative paths are resolved relative to `HUB.yaml`.
- `tracker_config_path` is optional. If omitted, Symphony uses `TRACKER.yaml` next to
  `workflow_path`.
- `migration_state` is optional and defaults to `hub_ready`. Accepted values are `legacy_only`,
  `hub_ready`, and `hub_managed` (dash-separated aliases are normalized). It is an observability and
  activation guardrail marker, not an automatic service migration command.
- `dispatch_enabled` defaults to `true`; `enabled` is accepted as a compatibility alias.
- `paused: true` disables new dispatch for that project snapshot.

Each valid project snapshot contains `project_id`, name, dispatch/paused status, workflow and
tracker paths, workflow summary, tracker kind and provider scope, workspace root, agent concurrency
limit, polling interval, Dashboard/API port, fingerprint, load time, and load error. Snapshots do
not include token values, API keys, env secret names, credentials, or raw secret-bearing tracker
config. A single invalid project is returned as `status: :error` and paused; other valid projects
still produce snapshots. Duplicate or unsafe `project_id` values reject the registry before
snapshots are accepted.

The registry also reports cross-project validation results. Shared workspace roots and shared
provider scopes are warnings. Shared Dashboard/API ports are errors because two live services cannot
bind the same port.

### Hub mode poll tick runtime skeleton

Hub mode now has an explicit runtime entrypoint with a small poll tick execution boundary:

```bash
./bin/symphony --hub-config /path/to/HUB.yaml --host 0.0.0.0 --port 21000
```

The scheduler loop is a separate explicit opt-in:

```bash
./bin/symphony --hub-config /path/to/HUB.yaml --hub-scheduler --host 0.0.0.0 --port 21000
```

The default Hub provider executor is still the safe skeleton. To let Hub candidate scans perform
real provider reads through the governed Hub boundary, opt in explicitly:

```bash
./bin/symphony --hub-config /path/to/HUB.yaml --hub-provider-executor real-candidate-scan --host 0.0.0.0 --port 21000
```

To let Hub execute the first safe writeback subset through the same governed boundary, opt in
explicitly:

```bash
./bin/symphony --hub-config /path/to/HUB.yaml --hub-writeback-executor real-writeback --host 0.0.0.0 --port 21000
```

A production Hub process that owns polling, safe writeback, and worker starts should set the
candidate scan and writeback executors independently:

```bash
./bin/symphony \
  --hub-config /path/to/HUB.yaml \
  --hub-scheduler \
  --hub-provider-executor real-candidate-scan \
  --hub-writeback-executor real-writeback \
  --hub-worker-starter real \
  --hub-activation-probe host-service \
  --host 0.0.0.0 \
  --port 21000
```

`--hub-config` is explicit. Symphony does not switch into Hub mode just because a `HUB.yaml` file is
present. The legacy startup path remains available for migration compatibility and rollback, but it
is no longer the formal production deployment mode:

```bash
./bin/symphony --tracker-config /path/to/TRACKER.yaml /path/to/WORKFLOW.md
```

`--host` overrides the Dashboard/API bind address for both compatibility legacy and Hub startup paths. A Hub
sidecar intended for LAN access should pass `--host 0.0.0.0`; the terminal dashboard URL is still
normalized to a loopback URL for local copy/paste.

In Hub mode the process loads `HUB.yaml`, keeps a safe registry snapshot, builds a poll coordination
plan, and can execute one controlled candidate-scan tick when `/refresh` or
`SymphonyElixir.Hub.Runtime.request_refresh/1` is called. Selected due projects are converted into
`ProviderGovernance` requests, passed through an injectable provider executor, and recorded back as
poll attempt/result facts that influence the next plan's `allow_poll`, `next_due_at`, and
backoff/eligibility fields. Candidate-scan result summaries are also normalized into
`hub_candidate_intake`: a safe provider-neutral list of candidate records with project/provider
scope/IssueRef identity, source poll request/result ids, eligible counts, and skipped reasons such
as invalid candidate, duplicate active attempt, workspace busy, project paused/config error,
provider backoff/manual attention, or capacity full. Eligible candidates are only marked
`ready_for_dispatch_evaluation`. The same refresh also builds `hub_dispatch_planning`: a safe
model-only plan that converts eligible candidates into pending dispatch/start-intent summaries with
stable project/provider-scope/IssueRef identity, source poll correlation, intake candidate ids, and
minimal attempt/intent identity. Planning recovers previous pending plans on refresh instead of
duplicating them, reserves project/global capacity across candidates in the same tick, and explains
already-planned, capacity, active-attempt, workspace, manual-attention, paused/config-error, and
provider-backoff skips. The refresh then builds `hub_dispatch_plan_application`: a safe application
summary that applies eligible planned intents through `DispatchBoundary.dispatch/3` to the in-memory
runtime ledger model, creating claim, attempt, workspace lease, start-intent, and safe run-context
facts. Repeated refreshes or unresolved runtime-ledger start intents are reported as already
applied/already planned rather than creating a duplicate active attempt. It then builds
`hub_worker_start_handoff`: a start handoff summary that reads those pending start intents from
runtime-ledger replay, builds a safe request summary, and calls an injectable starter. Acknowledged
results mark the start intent acknowledged and the attempt running; failures can enter
retry/backoff, blocked, released, or manual attention; unknown results remain unresolved and are
reported on later refreshes instead of starting again. By default this is still the skeleton starter:
it does not start a worker and records an unknown result. Passing `--hub-worker-starter real`
explicitly opts into the first real worker adapter, which hands the safe request to the existing
AgentRunner/Workspace/Codex app-server boundary and acknowledges only after a worker reports a session
start. After acknowledgement the refresh also builds `hub_worker_lifecycle_reconciliation`: a safe
post-ack reconciliation summary that can consume injectable worker/session lifecycle results for
still-running activity, succeeded completion, failed, cancelled, timeout/stopped, heartbeat lost,
unknown, or manual-attention outcomes. Confirmed terminal outcomes release the matching
workspace/capacity or enter retry/backoff, blocked, or released states; lost/unknown/manual-attention
outcomes retain the active attempt/workspace as observable evidence and do not blindly redispatch.
When `--hub-provider-executor real-candidate-scan` is used, the provider executor handles only
`candidate_scan` operations. It finds the request's `project_id` in the Hub registry, reloads that
project's own `WORKFLOW.md` and `TRACKER.yaml`, temporarily scopes adapter reads to those settings,
and normalizes returned issues into safe candidate summaries containing project id, provider kind,
provider scope key, provider-local id/identifier/URL/title, current stage, and poll correlation.
Other operation kinds remain unsupported and provider writeback is not implemented. Config/auth and
validation problems become permanent failures, rate limits become rate-limited/backoff summaries,
network/provider 5xx failures become retryable failures, and unknown results are not treated as
success.
When `--hub-writeback-executor real-writeback` is used, the writeback executor handles only the first
safe writeback subset: status/stage writes, GitHub workpad marker upserts, and GitHub label
additions. Before provider I/O it normalizes the routed writeback intent through
`WritebackProcessor.decide/3`; already-succeeded intents are reused, conflicting intent keys are
blocked, and unknown non-idempotent operations such as PR creation or ordinary append comments go to
manual attention or provider lookup instead of blind replay. The executor resolves `project_id` and
provider scope against the Hub registry, reloads that project's own `WORKFLOW.md` and `TRACKER.yaml`,
and calls the project-local tracker/GitHub write path under `Config.with_settings/2`. Unsupported
providers or operations return governed non-success results. Success, rate limits, retryable
network/provider failures, config/auth/not-found/validation failures, and unknown/manual-attention
outcomes are mapped into safe `ProviderGovernance` result summaries linked to the writeback intent.
The older `--hub-provider-executor real-writeback` spelling remains a compatibility alias, but
production Hub mode should pair `--hub-provider-executor real-candidate-scan` with
`--hub-writeback-executor real-writeback` instead of using one executor flag for both concerns.
Hub cutover replay decisions are closeout-aware but still pre-side-effect guard summaries. After the
execution outcome ledger and outcome closeout read model identify an unresolved `unknown` or
`manual_attention` outcome, `SymphonyElixir.Hub.CutoverReplayDecision` can report whether the same
project/provider scope, operation/source, replay key, outcome fingerprint/status, side-effect
safety, permit, authorization, consumption guard, and safe evidence fingerprints still block a later
explicit execution or allow retry consideration. A matching closeout with
`allow_explicit_retry_consideration` only clears the old unresolved-outcome replay block after the
current authorization consumption guard is already allowed. It does not create or consume
authorization, call providers, apply dispatch mutations, start workers, write back, operate systemd,
edit configuration, or bypass provider/runtime/writeback guardrails.
Hub cutover replay request audit adds the next read-only operator boundary after that decision. A
serialized request can be loaded with `--hub-cutover-replay-request /path/to/request.yaml` or
injected into `SymphonyElixir.Hub.Runtime.build_snapshot/4`. It binds the operator's explicit retry
consideration request to the project/provider scope, operation/source, historical outcome replay
key/fingerprint/status, side-effect safety, matching closeout fingerprint/resolution, current replay
decision fingerprint/status, current cutover request, readiness permit, authorization record,
consumption guard, request source/time/fingerprint, and a safe operator note digest or action/risk
code. `SymphonyElixir.Hub.CutoverReplayRequestAudit` reports `no_request`,
`would_allow_retry_consideration`, `would_block`, `stale`, `conflict`, `manual_attention`,
`malformed`, or `unsupported`, plus a sanitized link to any later outcome ledger fact that references
the replay request. `would_allow_retry_consideration` is not an execution result: this audit never
creates or consumes authorization, calls providers, dispatches, starts workers, writes back, operates
systemd, edits configuration, auto-replays side effects, queues migration work, or takes over legacy
services.
`SymphonyElixir.Hub.CutoverClosureChain` adds the first minimal closure-report chain contract as a
library-only read model. It consumes already-sanitized summaries or test fixtures and binds one
explicit attempt/replay key to project/provider scope, operation/source, cutover request, readiness
permit, execution authorization, consumption guard, outcome, safe evidence fingerprint, and safe
time metadata. It distinguishes only `no_chain`, `no_request`, `closed_succeeded`,
`closed_no_side_effect`, `open_retryable`, `open_manual_attention`, `conflict`, `stale`,
`malformed`, and `unsupported`. A matching `succeeded` outcome is the only source of
`closed_succeeded`; allowed guard, authorization, closeout, replay decision, or replay request
references remain evidence and do not imply execution success. For open chains it also exposes
library-only retained-reference status for closeout, replay decision, and replay request audit:
`missing`, `current`, `stale`, `conflict`, `malformed`, or `unsupported`, with summary/project
counts and recent safe reason/action codes. These statuses are not a full closure report and do not
allow retry. Runtime, Presenter, `/api/v1/state`, DeviceObservability, and the Live Dashboard now
surface the same safe snapshot as read-only device/project status, counts, reference-status counts,
reason/action codes, and safe fingerprints only; they do not queue replay, retry automatically, or
turn allowed replay references into execution success.
Hub activation preflight runs before Hub-owned real actions for projects explicitly marked
`hub_managed`. `SymphonyElixir.Hub.ActivationPreflight.build/2` consumes the safe registry/project
snapshot plus an injected `activation_probe` map or function and returns a serializable,
sanitized summary. The probe can report legacy service active/enabled/unknown state, legacy
instances, provider scope owners, workspace/runtime/log/state path owners, Dashboard/API port
owners, instance registry entries, or probe failure/unknown status. If a `hub_managed` project has a
legacy owner or an unknown probe result, Hub blocks that project from candidate scan, candidate
dispatch/application, real worker start, and real writeback provider I/O by default. The block is
per project: other projects with `safe_to_manage` continue through the same tick. The summary is
exposed as `hub_activation_preflight`, `hub_runtime.activation_preflight`, and per-project
`activation_preflight` in device observability with blocked operation types, reason/source codes,
checked time, probe source, and conflict/manual-attention counts. This is a #74 migration
guardrail, not an automatic tool to stop, disable, replace, or delete `symphony@project.service`.
Passing `--hub-activation-probe host-service` to the Hub entrypoint installs
`SymphonyElixir.Hub.HostServiceProbe` as that injected probe. It reads local, read-only evidence from
the user-level `symphony@<project>.service`, legacy config under
`~/.config/symphony/projects/<project>/env`, `WORKFLOW.md`, `TRACKER.yaml`, systemd-template
runtime/log/state path conventions, and local Dashboard/API listening ports. The resulting summary
is still sanitized before it reaches `hub_activation_preflight` or `/api/v1/state`: raw env,
secrets, raw systemd output, raw config, provider bodies, prompts, transcripts, and exception stacks
are not exposed. Unavailable systemd, unreadable config, parse failures, unavailable port checks, or
single-project probe failures become per-project unknown/manual-attention blockers instead of
crashing the Hub runtime or optimistically passing.
After a legacy unit is stopped and disabled, those project config files may remain as the Hub-owned
project definition and rollback material. The host-service probe treats config-derived
provider/workspace/runtime/log/state ownership as a blocker only when the legacy service is still
active/enabled/failed or its legacy port is still listening; config presence alone is not a legacy
owner for a `hub_managed` project.
启用 `--hub-scheduler` 后，Hub 会在启动时执行一次完整 tick，随后比较项目轮询计划、provider
backoff、最早有效重试 `due_at` 与实时 worker 状态。只有活动 attempt 和待确认 start intent
使用 1 秒 `runtime_reconciliation`；未来重试直接等待最早到期时间，manual attention 不会
触发短循环。缺失或非法重试时间不会生成 `retry_queued`：新失败转入 `manual_attention`，历史
坏记录在加载时隔离并以 30 秒有界错误退避持续暴露诊断。RealWorkerStarter 的可重试启动失败
默认生成 30 秒后的明确 `due_at`。真实 worker acknowledgement 后，Hub 的进程内生命周期存储
继续接收 worker task 的终止结果：正常结束由 WorkerLifecycleReconciliation 释放 attempt 和
workspace lease，异常结束转入带明确 `due_at` 的 retry。结果被账本消费后即从临时存储移除，
runtime ledger 仍是后续 replay 的权威来源。

`runtime_reconciliation` 只运行 WorkerStartHandoff 与 WorkerLifecycleReconciliation，不加载
registry、不执行 provider candidate scan，也不刷新 Host Service Probe。Host Service Probe
默认缓存 60 秒，项目配置身份变化时立即失效。调度状态切换只局部更新已发布快照；没有 ledger
变化的 reconciliation 不重建完整审计、回放、闭环和设备投影。成功且没有 ledger 变化的
空闲 poll 继续更新 poll facts、候选、计划和 scheduler 子快照，完整审计、闭环和设备投影默认
每 5 分钟刷新一次；配置、activation、cutover 或错误状态变化会立即触发完整刷新。Runtime 生成的安全快照带内部
契约标记，Presenter 可直接复用已清洗的 Hub 子快照，同时仍对 legacy/string-key 快照执行原有
兼容投影。若 `/refresh` 在自动 tick 运行或排队时到达，请求仍会合并而不会并发执行第二轮。
Paused projects, config-invalid projects, and projects blocked by activation or cutover gates do not
force an immediate next tick just because their safe snapshot has a current `next_due_at`; if no
project can become due from time/backoff alone, Hub uses the default scheduler interval.
Hub mode still does not start the legacy single-project orchestrator, run the final durable Hub
scheduler, or take ownership of existing `symphony@project.service` instances. The default provider
executor and default start handoff are skeleton boundaries and do not migrate the legacy
GitHub/GitLab/Linear adapters. The opt-in real candidate-scan executor uses those adapters only for
project-local reads behind Hub governance. The opt-in real writeback executor covers only the safe
subset above; it does not migrate all dynamic tools, PR creation, ordinary append comments, legacy
polling, legacy service ownership, or systemd unit lifecycle.
The lifecycle reconciliation source remains injectable and safe-summary based; real Hub workers use
the supervised process-local lifecycle store by default. The existing per-project services and their poll loops keep running until a later
migration explicitly changes ownership.
#203 adds the Hub runtime ledger restart/replay safe fixture baseline for #74 remaining gap 2. The
fixture lives in `test/support/hub_runtime_ledger_restart_replay_fixture.exs` and is exercised by
`hub_runtime_ledger_test.exs` and `hub_device_observability_test.exs`: the same sanitized
multi-project ledger is encoded/decoded like a post-restart snapshot, replayed through
`RuntimeLedger`, projected through DeviceObservability, and exposed through Presenter
`/api/v1/state`. It covers active attempts, completed attempts, retry/backoff, retained/released
workspaces, replay-safe writeback, provider-lookup/manual-attention writeback, and active-attempt
conflict diagnostics. This is a read-only acceptance fixture, not a database/WAL, durable execution
queue, automatic retry/replay path, provider executor, dispatch path, worker starter, systemd or
workspace hook, config mutation, or legacy service takeover.

When `--port` is provided, `/api/v1/state` exposes Hub fields such as `hub_runtime`,
`hub_scheduler`, `hub_activation_preflight`, `hub_cutover_gate`, `hub_project_registry`,
`hub_poll_coordination`, `hub_candidate_intake`, `hub_dispatch_planning`, `hub_dispatch_plan_application`,
`hub_worker_start_handoff`, `hub_worker_lifecycle_reconciliation`, `hub_cutover_replay_decision`,
`hub_cutover_replay_request_audit`,
`hub_cutover_closure_chain`, `hub_cutover_closure_conclusion`, `hub_dispatch_boundary`, and
`hub_device_observability`.
These snapshots are safe summaries: they show tick status, project eligibility, last poll/backoff,
provider queue/scope summaries, intake counts, candidate identities, safe poll correlation ids,
planning counts, planned/skipped outcomes, application applied/skipped/blocked/already-applied
counts, start handoff selected/acked/failed/unknown/manual-attention/already-acked/skipped counts,
post-ack lifecycle succeeded/failed/cancelled/timeout/stopped/lost/unknown/manual-attention counts,
reason counts, workspace released/retained counts, pending or unresolved start-intent summaries,
runtime-ledger replay summaries, scheduler enabled/disabled state, queued/running/coalesced status,
last/next tick times, duration, reason, coalesced/error counts, per-project due/backoff/runtime
summary, provider executor mode (`skeleton`, `real_candidate_scan`, or `real_writeback`), candidate
counts, writeback executor supported/rejected operations, pending/succeeded/failed/unknown/manual
attention counts, per-project writeback pressure, recent safe error categories, cutover gate
decision counts, allowed/blocked operation sets, staged ownership record counts, cutover replay
decision counts for unresolved blocks, retry-consideration allowed/denied, stale/conflict/malformed/
manual-attention decisions, replay request audit allow/block/stale/conflict/manual-attention/
malformed/unsupported counts, safe replay/closeout/authorization/permit/guard fingerprints, linked
outcome status counts, closure chain status/reference counts, error class/backoff/manual attention summaries, and skipped reasons. `hub_device_observability.overview`
adds the operator-oriented device summary: scheduler enabled/disabled/queued/running/coalesced
state and next-tick reason, project status counts, provider queue/backoff/circuit/recent-failure
pressure, active attempts, pending start intents, workspace leases, unreleased capacity, writeback
conflict/unknown/manual-attention/provider-lookup state, activation preflight blocks/unknowns,
lifecycle unknown/manual-attention state, cutover gate status, closeout-aware replay decision
status, replay request audit status, closure chain status/reference counts, and summary errors. Each project in
`hub_device_observability.projects` also includes a `detail` block for safe identity/provider scope,
migration and ownership, config fingerprint/snapshot version, preflight result, poll eligibility,
cutover gate decision, candidate intake, dispatch planning/application, worker start handoff, replay
decision, replay request audit, closure chain, lifecycle reconciliation, and writeback
completed/retryable/unknown/manual-attention/dangerous-replay state.
The live Dashboard keeps the operator queue ahead of Hub internals: it surfaces running issue
sessions, Hub active attempts, blocked sessions, and retry backlog before rate-limit and device
diagnostic panels, so `counts.running = 0` is not mistaken for a fully idle Hub when runtime-ledger
attempts or workspace leases are still active.
`hub_device_observability.migration_readiness` adds a migration readiness report derived from the
same safe summaries. At the device level it reports Hub runtime mode, scheduler status,
provider/writeback executor mode, worker starter mode, activation probe mode, migration-state
counts, readiness-decision counts, global blocking risks, and advisory risks. At the project level
it reports a stable `decision` (`legacy_only`, `ready_for_dry_run`, `ready_for_hub_management`,
`blocked`, `unknown_manual_attention`, or `already_hub_managed`), `blocking_reasons`,
`advisory_reasons`, `required_operator_actions`, and safe `evidence`. Reasons and actions use short
codes such as `legacy_service_active`, `provider_scope_owner_conflict`, `probe_unknown`,
`provider_backoff`, `writeback_unknown`, `worker_lifecycle_unknown`,
`stop_disable_legacy_service`, `enable_host_service_probe`, `wait_provider_backoff`,
`resolve_writeback_manual_attention`, and `confirm_hub_executor_modes`. Evidence references only
safe summary fields, checked times, counts, fingerprints, and request/result identifiers; it does
not re-read raw provider/config/env material.
`hub_device_observability.activation_plan` builds on that readiness report and adds the operator
acknowledgement baseline. It exposes device counts for `plan_ready`, `ack_required`, `ack_stale`,
`ack_conflict`, `blocked`, `unknown_manual_attention`, and `already_managed`, plus ack status counts
for `missing`, `accepted`, `stale`, `conflict`, `malformed`, `unsupported`, and `manual_attention`.
Each project gets a stable `plan_id`, safe provider scope, readiness decision, proposed next state,
required acknowledgement action codes, blocking/advisory reasons, safe evidence, and an
`operator_acknowledgement` summary. The `plan_id` is derived from scope, migration/readiness state,
executor/probe modes, action/reason codes, and non-volatile evidence facts; observation timestamps do
not by themselves rotate it. An acknowledgement must explicitly reference `project_id` and
`plan_id`; stale or conflicting ack input is displayed as such instead of being accepted silently.
Malformed/unsupported ack input is isolated to that project summary. Even with `accepted`, the
summary keeps `hub_owned_actions_allowed: false` and lists the existing safety gates because poll,
dispatch, worker start, and real writeback remain governed by activation preflight, legacy ownership
guardrails, provider governance, runtime ledger, executor mode, workspace leases, and lifecycle
reconciliation.
`hub_cutover_gate` and `hub_device_observability.cutover_gate` are the execution-facing audit gate
after activation plan acknowledgement. The gate is rebuilt from safe runtime inputs for every Hub
snapshot and project: safe provider scope, migration state, activation plan id/fingerprint,
acknowledgement status, readiness decision, activation preflight/probe summary, scheduler mode,
provider/writeback executor mode, and worker starter mode. It returns a stable decision
(`not_applicable`, `blocked`, `manual_attention`, `staged_ready`, or `allowed`), allowed and blocked
operation sets for `poll`, `dispatch`, `worker_start`, and `writeback`, blocking/advisory reason
codes, required operator action codes, and safe evidence. When at least one operation is allowed it
also emits a read-only staged ownership record bound to the current plan fingerprint, ack,
preflight/probe evidence, executor modes, and operation set. The record explains why this tick may
continue; it is not persisted as a migration transaction and does not edit Hub or project config,
systemd units, provider state, or legacy services. Real candidate scan, dispatch plan application,
real worker handoff, and real writeback executors consume this gate before provider I/O, ledger
pending-start mutation, worker start, or writeback side effects; a block is scoped to that project.
`hub_cutover_operation_audit` and
`hub_device_observability.cutover_operation_audit` are the operator-facing dry-run request boundary
after the activation plan and cutover gate. The CLI can load a serialized request with
`--hub-cutover-operation-request /path/to/request.yaml`, and tests/internal callers can inject the
same contract into `SymphonyElixir.Hub.Runtime.build_snapshot/4`. A request binds `project_id`,
safe provider scope, requested operations (`poll`, `dispatch`, `worker_start`, `writeback`),
activation plan id/fingerprint, cutover gate decision/staged ownership evidence, request source,
requested time, request fingerprint, safe project snapshot, and a safe operator intent summary
limited to action/risk codes or a note digest. The audit evaluates only the current safe snapshots
and returns per-operation `would_allow`, `would_block`, `manual_attention`, or `unsupported`
decisions with reason/action codes, safe evidence, and `dry_run_only: true`. It does not call
providers, start workers, write runtime ledger pending-start/attempt/writeback facts, operate
systemd, write provider state, or edit Hub/project config. Malformed requests, unknown projects,
unknown operations, unsupported sources, and stale plan/gate/staged-record/project evidence are
blocked or require manual attention. Projects without an explicit request show `no_request` so the
Dashboard/API does not imply that migration work is queued or running.
`hub_cutover_audit_history` and
`hub_device_observability.cutover_audit_history` build the audit-history and manual attention
closeout baseline on top of that dry-run result. The summary is bounded and safe for Dashboard/API:
it records recent request fingerprints, evaluated operations, dry-run decisions, reason/action
codes, safe evidence fingerprints, unresolved manual attention, and closeout counts. Optional
serialized inputs can be loaded with `--hub-cutover-audit-history /path/to/history.yaml` and
`--hub-manual-attention-closeout /path/to/closeout.yaml`; tests/internal callers can inject the same
values into `SymphonyElixir.Hub.Runtime.build_snapshot/4`. Closeouts bind to project, request,
activation plan, cutover gate, operation, reason/action code, and safe evidence fingerprint. If any
of those inputs changes, the closeout is shown as stale or conflicting rather than clearing current
manual attention. Closeouts only annotate the audit summary: they do not override the cutover gate,
call providers, start workers, write runtime-ledger facts, operate systemd, write provider state, or
edit Hub/project config.
`hub_cutover_readiness_permit` and
`hub_device_observability.cutover_readiness_permit` add the read-only execution readiness permit
baseline after the gate, dry-run audit, audit history, and closeout summaries. The permit summary is
generated from safe snapshots only and binds each explicitly requested operation to the current
request fingerprint, activation plan and acknowledgement evidence, cutover gate and staged
ownership evidence, dry-run audit decision, audit history/closeout currentness, executor/starter
mode, source, safe timestamps, evidence fingerprints, and a stable permit fingerprint. Permit
decisions include `ready_for_execution_consideration`, `blocked`, `stale`, `manual_attention`,
`unsupported`, and `malformed`. Ready means only that a later explicit execution entrypoint may
consider the operation; it does not execute migration, provider I/O, dispatch, worker start,
runtime-ledger mutation, provider writeback, systemd changes, config edits, or legacy service
takeover, and it does not replace the cutover gate.
`hub_cutover_execution_authorization_ledger` and
`hub_device_observability.cutover_execution_authorization_ledger` add the operator-controlled,
read-only execution authorization ledger after the permit. A serialized authorization request can be
loaded with `--hub-cutover-execution-authorization-request /path/to/request.yaml`, and
tests/internal callers can inject it into `SymphonyElixir.Hub.Runtime.build_snapshot/4`. Each record
binds project/provider scope, requested operation, authorization request id/source/requested time
and fingerprint, the cutover operation request fingerprint, readiness permit fingerprint/decision,
activation plan and acknowledgement fingerprints, cutover gate/staged ownership evidence, dry-run
audit evidence, audit-history/closeout currentness, executor/starter mode, safe timestamps, and safe
evidence fingerprints. Decisions include `authorized_for_explicit_execution`, `blocked`, `stale`,
`manual_attention`, `unsupported`, `malformed`, and `no_ready_permit`. A record is authorized only
when the current permit is still `ready_for_execution_consideration` and every bound evidence
fingerprint still matches. The ledger is not an executor, queue, one-click migration, or legacy
service takeover; it does not bypass the gate or permit and does not call providers, dispatch, start
workers, mutate runtime-ledger/provider state, operate systemd, or edit config.
`hub_cutover_authorization_consumption_guard` and
`hub_device_observability.cutover_authorization_consumption_guard` add the shared authorization
consumption boundary for explicit Hub cutover execution paths. When explicit authorization records
are loaded, real candidate scan, dispatch plan application, real worker start handoff, and real
provider writeback evaluate the same guard before provider I/O, runtime-ledger mutation, worker
start, or provider writeback. The summary reports `allowed`, `blocked`, `no_authorization`, `stale`,
`manual_attention`, `unsupported`, and `malformed` counts by operation and side-effect source, recent
safe reason/action codes, blocked sources, and sanitized evidence fingerprints. It is not an
executor, queue, one-click migration, or legacy service takeover, and it does not replace the
cutover gate, readiness permit, authorization ledger, activation preflight, provider governance,
runtime ledger, worker starter, or writeback executor. Empty or non-matching configured
authorization records block as `no_authorization`. When the long-running production scheduler omits
one-shot execution authorization input, normal real executor ticks stay at `no_consumption` rather
than implying pending execution.
`hub_cutover_execution_outcome_ledger` and
`hub_device_observability.cutover_execution_outcome_ledger` add the execution outcome audit boundary
after authorization consumption. It records guard-blocked attempts as no-side-effect outcomes and
normalizes safe executor/starter/writeback returns into `succeeded`, `failed`, `retryable`,
`unknown`, or `manual_attention` facts bound to project/provider scope, operation, side-effect
source, cutover request, authorization request/record, readiness permit, gate, dry-run audit,
history/closeout, guard decision, executor mode, safe timestamps, reason/action codes, and
sanitized evidence fingerprints. Unresolved `unknown` or `manual_attention` outcomes are preserved
so later refreshes do not repeat the same unsafe external side effect or overwrite an unknown result
as success. The ledger is not a durable execution queue, one-click migration, migration executor, or
legacy service takeover, and it does not replace gate/permit/authorization/consumption guard,
provider governance, runtime ledger, worker starter, or writeback executor. No outcome facts are
reported as `no_outcome`, not pending execution.
`hub_cutover_execution_outcome_closeout` and
`hub_device_observability.cutover_execution_outcome_closeout` add the manual closeout baseline for
unresolved outcome facts. The summary is safe for Dashboard/API and binds project/provider scope,
operation/source, outcome replay key/fingerprint/status, side-effect entered/may-have-happened
semantics, cutover request, authorization record, readiness permit, gate/audit/history evidence,
consumption guard fingerprint, safe resolution/reason/action codes, operator request fingerprint,
and safe created/closed timestamps. Matching closeouts can report `resolved` or
`allow_explicit_retry_consideration`; stale evidence, cross-project/source references, malformed
records, unsupported resolution codes, and side-effect safety conflicts remain visible and do not
clear the current outcome. Retry consideration never triggers provider I/O, worker start,
writeback, systemd changes, automatic authorization, or legacy service takeover; a later run must
again pass readiness permit, execution authorization, consumption guard, and existing provider/
runtime/writeback guardrails. No unresolved outcome reports `no_outcome`; unresolved outcomes
without a valid closeout report `no_closeout`, not pending retry.
`hub_cutover_replay_request_audit` and
`hub_device_observability.cutover_replay_request_audit` add the closeout-after explicit retry
request audit baseline. The CLI can load a serialized request with
`--hub-cutover-replay-request /path/to/request.yaml`, and tests/internal callers can inject the same
contract into `SymphonyElixir.Hub.Runtime.build_snapshot/4`. Each request binds project/provider
scope, operation/source, historical outcome replay key/fingerprint/status, side-effect safety,
matching closeout fingerprint/resolution, current replay decision fingerprint/status, current
cutover request, readiness permit, execution authorization record, consumption guard, source,
requested time, request fingerprint, and a safe operator note digest or action/risk code. The audit
reports `no_request`, `would_allow_retry_consideration`, `would_block`, `stale`, `conflict`,
`manual_attention`, `malformed`, or `unsupported`, and can show whether a later outcome ledger fact
is recorded, still pending, blocked, stale, or conflicting for that replay request. It is not an
executor, queue, one-click migration, durable retry mechanism, or legacy service takeover; it does
not create/consume authorization, bypass permit/authorization/guard/provider/runtime/worker/writeback
checks, call providers, dispatch, start workers, write providers, operate systemd, or edit config.
Projects without an explicit replay request show `no_request` / request count 0 rather than pending
execution or automatic retry.
`SymphonyElixir.Hub.CutoverClosureChain` 是 replay request audit 之后的最小 closure chain
合同基线。Runtime 现在会用已有脱敏 cutover summaries 构造
closure safe summary，看到 project/provider scope、operation/source、attempt fingerprint 或 replay key、
request、permit、authorization、guard、outcome、safe evidence fingerprint 和安全时间摘要的绑定关系。
`closed_succeeded` 只能来自 evidence 未漂移的 matching `succeeded` outcome；guard 阻断、无
authorization 或 validation 阻断且 side effect 明确未进入时显示 `closed_no_side_effect`，不会显示
operation 成功。matching `retryable` outcome 显示 `open_retryable`，表示等待后续显式 retry
consideration 重新判断 permit、authorization、consumption guard 和 replay request audit；matching
`unknown` 或 `manual_attention` outcome 显示 `open_manual_attention`，表示需要 operator closeout 或
人工复核。scope/source/operation/key/fingerprint 不匹配、字段不足、malformed 或 unsupported 输入仍
优先显示 `stale`、`conflict`、`malformed` 或 `unsupported`。closeout、replay decision、replay
request audit 只作为安全引用保留，不能把 open outcome 推导为 success、resolved 或 retry allowed。
这些 retained reference 现在会额外输出 `missing`、`current`、`stale`、`conflict`、`malformed`、
`unsupported` 的库级只读状态，并在 summary、project summary、recent chain 中暴露 closeout /
replay decision / replay request audit counts 和最近 reason/action code；输出只包含安全状态、code 和
safe fingerprint / digest，不包含 token、raw provider payload、完整 prompt/transcript、完整评论或 PR
正文、本地私有路径、原始 systemd 输出或异常栈。`/api/v1/state` 会暴露
`hub_cutover_closure_chain`，`hub_device_observability.overview.cutover_closure_chain` 和每个项目的
`cutover_closure_chain` / `detail.closure_chain` 会给 Dashboard 和后续 closure report 提供稳定只读输入。
它不会
创建/消费 authorization、调用 provider、dispatch、启动 worker、writeback、操作 systemd、改配置、
自动 retry 或 replay；它不是完整 operator-facing closure report。Live Dashboard 现在只展示这些
Runtime/API 已有 safe snapshot 的 Hub 设备级和项目级摘要，不会把 `auto_replay_allowed`、resolved
closeout、allowed replay decision 或 allowed replay request audit 显示成自动 retry、已排队 replay、
operation 成功或 legacy takeover。
`SymphonyElixir.Hub.CutoverClosureConclusion` 是 closure chain safe snapshot 之上的 operator
conclusion baseline。Hub Runtime 现在只从既有 `hub_cutover_closure_chain` safe snapshot 派生
`hub_cutover_closure_conclusion`，Presenter 会在 `/api/v1/state` 输出该只读结论；
`hub_device_observability.cutover_closure_conclusion`、
`hub_device_observability.overview.cutover_closure_conclusion` 和每个项目的
`cutover_closure_conclusion` / `detail.closure_conclusion` 会输出稳定的 conclusion、
severity/attention level、summary code、required action codes、blocked-by、safe evidence
references，以及 `read_only: true`、`no_side_effects: true`、`auto_retry_allowed: false`、
`auto_replay_allowed: false` 等边界信号。`closed_no_side_effect` 会被解释为无副作用闭环而不是
operation 成功；`open_retryable` 只会要求显式 retry consideration，不表示自动 retry、queued replay
或执行中；`no_chain` / `no_request` 不表示 pending execution、pending retry、migration queued 或
legacy takeover。Live Dashboard 现在会展示这个 Runtime/API 已有的只读 conclusion snapshot，包含设备级
和项目级 conclusion badge、severity/attention、summary code、required action、blocked-by、安全
evidence/fingerprint 与只读边界信号；它不新增执行入口，不是完整 #171 operator-facing closure report，
不重新聚合底层 request/permit/authorization/guard/outcome evidence，不创建或消费 authorization，
也不调用 provider、dispatch、worker、writeback、systemd 或配置路径。
`SymphonyElixir.Hub.CutoverClosureReportPacket` 是 closure chain/conclusion safe snapshot 之上的库级
只读组织层。它可以从已有 `hub_cutover_closure_chain`、`hub_cutover_closure_conclusion` 或同形测试
fixture 构建设备级和项目级 report packet，输出 report version、generated_at、read-only boundary
flags、report status、operator conclusion、severity/attention、summary code、required action codes、
blocked-by、closure chain counts/reference counts、recent reason/action code、project provider scope 和
safe evidence fingerprint。packet 的 device rollup 继续保守：任一 project open/stale/conflict/malformed/
unsupported 时不显示 fully closed；`closed_no_side_effect` 不显示 operation success；`open_retryable`
不显示自动 retry、queued replay、pending retry 或执行中；`no_chain` / `no_request` 不显示 pending
execution、migration queued 或 legacy takeover。这个模块只消费脱敏 safe fields，不重新聚合 raw
cutover evidence，不调用 provider、dispatch、worker starter、writeback、systemd 或 config mutation
路径。Hub Runtime 现在会从 chain/conclusion safe snapshot 派生
`hub_cutover_closure_report_packet`，Presenter 会在 `/api/v1/state` 输出该只读 packet；
`hub_device_observability.cutover_closure_report_packet`、
`hub_device_observability.overview.cutover_closure_report_packet` 和每个项目的
`cutover_closure_report_packet` / `detail.closure_report_packet` 会暴露 report status、operator
conclusion、section status、required action/blocked-by counts、provider scope 和 safe evidence
fingerprint/reference。Live Dashboard 现在只展示这些 Runtime/API 已有 safe packet 字段，在 Hub 设备
总览和项目明细中呈现 report status、operator conclusion、required actions、blocked-by、section
status、provider scope、safe evidence fingerprint/reference 和只读边界信号。这个展示切片仍不是完整
#171 execution closure report，不新增执行入口、自动 retry/replay 队列、durable execution queue、
一键迁移或 legacy service takeover。
Closure report packet dry-run baseline 通过 `SymphonyElixir.HubCutoverClosureReportPacketDryRunFixture`
提供一个固定 safe fixture，并用 targeted test 复现同一 packet 进入 Presenter、`/api/v1/state` 与
Live Dashboard 的输出：

```bash
mise exec -- mix test test/symphony_elixir/hub_cutover_closure_report_packet_dry_run_test.exs
```

该 dry-run 覆盖 `closed_succeeded`、`closed_no_side_effect`、`open_retryable`、manual/unknown、
`no_request`、`no_chain` 和 stale 降级，并断言 provider scope、required action、blocked-by 和 safe
evidence fingerprint/reference 不跨 project 串项。完整 runbook 见
[`../docs/hub-cutover-closure-report-packet-dry-run.md`](../docs/hub-cutover-closure-report-packet-dry-run.md)。
#171/#172 原始 closure report 范围到 #173-#195 拆分切片的覆盖矩阵和收束建议见
[`../docs/hub-cutover-closure-report-coverage-audit.md`](../docs/hub-cutover-closure-report-coverage-audit.md)；
该文档只是审计入口，不新增 Hub runtime/API/Dashboard 行为。
#74 Hub mode 原始目标、已交付切片、remaining gaps 和后续最小 issue 建议的总覆盖审计见
[`../docs/hub-mode-issue-74-remaining-capability-coverage-audit.md`](../docs/hub-mode-issue-74-remaining-capability-coverage-audit.md)；
该文档只作为证据索引和 Owner 决策输入，不新增 Elixir runtime/API/Dashboard 语义。
#74 provider exit residual coverage 的决策基线见
[`../docs/hub-provider-exit-residual-coverage-decision-baseline.md`](../docs/hub-provider-exit-residual-coverage-decision-baseline.md)；
它逐项标注 Hub-owned candidate scan、structured provider tools、writeback processor、real writeback
safe subset、legacy tracker direct path、raw `linear_graphql`、auto-update/审查类路径和
Dashboard/API safe summary 路径的 `hub_governed` / `legacy_direct_scoped_non_goal` /
`unsupported_manual_attention` / `future_migration_candidate` / `non_runtime_provider_access`
分类。该文档只补 #199 remaining gap 1 的 inventory / decision baseline，不新增 runtime provider I/O。
#74 closure decision packet 见
[`../docs/hub-mode-issue-74-closure-decision-packet.md`](../docs/hub-mode-issue-74-closure-decision-packet.md)；
它把 #199/#201/#203 的结论收束为 `closure_ready`，供 Owner 后续评论或关闭 #74 使用，不新增 Elixir
runtime/API/Dashboard/provider/dispatch/worker/writeback 行为。
The Live Dashboard renders the same Hub device overview and project detail table when this Hub
summary exists; legacy snapshots without Hub fields keep the existing single-runtime Dashboard.
All of these summaries omit provider tokens, API keys, authorization/cookie values, secret env
values, raw env/raw config, raw provider responses, raw systemd output, raw hook/app-server output,
full prompts, full transcripts, provider body text, full comment/PR bodies, and exception stack
traces.

#### Hub production systemd service

For the formal long-running Hub-only production entrypoint, install `symphony-hub.service`:

```bash
../scripts/install-hub-systemd-service.sh \
  --hub-config ~/.config/symphony/hub/HUB.yaml \
  --host 0.0.0.0 \
  --port 21000
```

Optional operator evidence can be loaded into the generated unit:

```bash
../scripts/install-hub-systemd-service.sh \
  --hub-config ~/.config/symphony/hub/HUB.yaml \
  --activation-ack ~/.config/symphony/hub/activation-ack.yaml \
  --cutover-operation-request ~/.config/symphony/hub/cutover-operation-request.yaml \
  --host 0.0.0.0 \
  --port 21000
```

The generated `symphony-hub.service` passes `--hub-scheduler`,
`--hub-provider-executor real-candidate-scan`, `--hub-writeback-executor real-writeback`,
`--hub-worker-starter real`, `--hub-activation-probe host-service`, and the configured
`--host`/`--port`; optional files append the corresponding Hub ack/request CLI flags. Hub-only
production expects all managed projects to live in `HUB.yaml` and the
legacy `symphony@<project>.service` units to be stopped and disabled after readiness and ownership
checks. The installer itself does not stop those units so rollback remains explicit.
`--execution-authorization-request` is one-shot explicit cutover execution audit material and should
not be loaded by the default long-running production scheduler unless an operator is intentionally
running that explicit execution stage.

#### Hub migration readiness dry-run runbook

Use readiness for migration preparation only; it does not execute a migration.

1. Prepare `HUB.yaml` with each project's `WORKFLOW.md` and optional `TRACKER.yaml`. Use
   `migration_state: legacy_only` for projects still owned by `symphony@<project>.service`,
   `hub_ready` for projects that should be evaluated by Hub dry-run, and `hub_managed` only after an
   operator has resolved ownership and executor-mode risks.
2. Start a read-only evidence run with the host-service probe and the default skeleton executor
   modes:

   ```bash
   ./bin/symphony \
     --i-understand-that-this-will-be-running-without-the-usual-guardrails \
     --hub-config /path/to/HUB.yaml \
     --hub-activation-probe host-service \
     --host 0.0.0.0 \
     --port 21000
   ```

3. Inspect `/api/v1/state`, especially `hub_activation_preflight`,
   `hub_device_observability.overview`, and
   `hub_device_observability.migration_readiness` /
   `hub_device_observability.activation_plan`, `hub_cutover_gate`,
   `hub_device_observability.cutover_gate`, `hub_cutover_operation_audit`,
   `hub_device_observability.cutover_operation_audit`, `hub_cutover_audit_history`, and
   `hub_device_observability.cutover_audit_history`, `hub_cutover_readiness_permit`,
   `hub_device_observability.cutover_readiness_permit`, `hub_cutover_execution_authorization_ledger`,
   `hub_device_observability.cutover_execution_authorization_ledger`,
   `hub_cutover_authorization_consumption_guard`, and
   `hub_device_observability.cutover_authorization_consumption_guard`,
   `hub_cutover_execution_outcome_ledger`, and
   `hub_device_observability.cutover_execution_outcome_ledger`,
   `hub_cutover_execution_outcome_closeout`,
   `hub_device_observability.cutover_execution_outcome_closeout`,
   `hub_cutover_replay_decision`,
   `hub_device_observability.cutover_replay_decision`,
   `hub_cutover_replay_request_audit`,
   `hub_device_observability.cutover_replay_request_audit`,
`hub_cutover_closure_chain`, `hub_cutover_closure_conclusion`,
`hub_cutover_closure_report_packet`, `hub_device_observability.cutover_closure_chain`,
`hub_device_observability.cutover_closure_conclusion`, and
`hub_device_observability.cutover_closure_report_packet`。API 会给消费者暴露 conclusion 和 report
   packet 安全数据；Live Dashboard 也会展示已有 closure report packet safe summary。The Dashboard shows the
   same readiness, plan, ack, gate status, dry-run audit status, audit-history/closeout counts,
   permit status, authorization-ledger counts, consumption-guard counts and blocked sources,
   execution-outcome status/unknown/manual-attention/no-side-effect counts, leading reasons,
   replay-request audit counts and linked outcome status, closure-chain status/reference counts,
   allowed/blocked operations, request counts, and action codes when Hub summary fields exist.
4. Treat `ready_for_dry_run` as permission to continue read-only or low-risk Hub checks, not as
   ownership transfer. Treat `ready_for_hub_management` as evidence that an operator may consider
   changing `HUB.yaml` to `hub_managed`. Treat `blocked` and `unknown_manual_attention` as stop
   points until their reason/action codes are resolved or explicitly accepted.
5. Manually confirm any operation that changes ownership: stopping or disabling legacy
   `symphony@<project>.service`, resolving unresolved writeback/manual-attention items, clearing
   active attempts or workspace leases, enabling the Hub scheduler, and selecting real
   provider/writeback executor or worker starter modes. After acknowledgement and `hub_managed`,
   inspect the cutover gate before enabling real Hub-owned actions; `allowed` or `staged_ready`
   explains which specific operations may proceed and why.
   Stopped/disabled legacy project config files can stay in place when `HUB.yaml` references them;
   the blocker to clear is the running/enabled legacy unit or listening legacy port.
6. Optionally pass `--hub-activation-ack /path/to/ack.yaml` to load a serialized operator
   acknowledgement. The file should contain acknowledgement entries with `project_id`, `plan_id`,
   `source`, `created_at`, and confirmed action/risk codes. This only changes the safe ack summary;
   it does not execute migration work.
7. Optionally pass `--hub-cutover-operation-request /path/to/request.yaml` to load a serialized
   request for a pre-migration dry-run audit. The file should bind the target project, requested
   operations, current plan/gate/staged-record evidence, source, requested timestamp, and safe
   project snapshot. The resulting audit is read-only and reports what the current gate would do; it
   is not a queue, migration command, provider write, worker start, or legacy service takeover.
8. Optionally pass `--hub-cutover-audit-history /path/to/history.yaml` and
   `--hub-manual-attention-closeout /path/to/closeout.yaml` to display recovered audit history and
   operator closeout status. Closeouts must bind project, request fingerprint, activation/gate and
   evidence fingerprints, operation, reason code, and required action code. They record operator
   handling only; stale, conflicting, malformed, or unsupported closeouts do not clear unresolved
   manual attention and never bypass the cutover gate.
9. Optionally pass `--hub-cutover-execution-authorization-request /path/to/request.yaml` to record a
   read-only execution authorization request for one explicitly requested operation. Treat this as
   one-shot cutover execution audit input, not as default configuration for the long-running
   production scheduler. The request should bind the current cutover operation request fingerprint,
   readiness permit fingerprint/decision, activation plan/ack fingerprint, cutover gate evidence,
   dry-run audit, audit-history/closeout evidence, and executor/starter mode. The resulting ledger
   record is authorization evidence for a later explicit execution stage only; it is not a queue and
   does not execute migration work, provider I/O, dispatch, worker start, writeback, systemd
   operations, or config changes. Without this input, the ledger reports zero records and normal
   scheduler ticks should report `no_consumption` instead of blocking every real executor as
   `no_authorization`.
10. When a later explicit Hub cutover execution path uses a real side-effect entrypoint, treat the
    consumption guard as the common authorization-consumption boundary before that side effect. A
    missing/mismatched/stale/manual-attention/malformed record blocks as `no_authorization` before
    provider calls, dispatch mutation, worker start, or writeback when explicit authorization
    consumption is configured. If no execution authorization records are loaded, the long-running
    production scheduler may still use real candidate scan, worker start, and writeback under the
    existing gate, activation preflight, provider governance, runtime ledger, starter, and writeback
    checks; the guard reports `no_consumption` instead of manufacturing an empty blocking ledger.
11. After a guard decision, inspect `hub_cutover_execution_outcome_ledger` for the safe execution
    result summary. Guard-blocked paths should appear as `not_executed` with no side effects; real
    side-effect boundaries should normalize their safe return into success, failure, retryable,
    unknown, or manual-attention outcomes. Unresolved unknown/manual-attention outcomes require
    operator review and should not be replayed automatically just because the same authorization
    record still exists. Optionally pass
    `--hub-cutover-execution-outcome-closeout /path/to/closeout.yaml` to display operator closeout
    records for those unresolved outcomes. A closeout can mark the manual handling as resolved or
    allow later explicit retry consideration, but it is only audit input; it never replays the old
    side effect, creates authorization, changes config, touches systemd, or bypasses permit /
    authorization / consumption guard checks.
12. Optionally pass `--hub-cutover-replay-request /path/to/request.yaml` after a valid
    `allow_explicit_retry_consideration` closeout and closeout-aware replay decision to audit a
    specific explicit retry consideration request. The request should bind the unresolved outcome,
    matching closeout, current replay decision, cutover request, readiness permit, authorization
    record, consumption guard, safe evidence fingerprints, source, requested time, and request
    fingerprint. `would_allow_retry_consideration` only means the request can move to later explicit
    execution consideration; it still does not call providers, dispatch, start workers, write back,
    operate systemd, edit config, create/consume authorization, auto-retry, queue migration, or
    bypass existing guardrails.

This baseline does not stop, disable, restart, delete, or migrate legacy services; does not modify
`HUB.yaml`, `WORKFLOW.md`, `TRACKER.yaml`, systemd units, project state, or provider state; and does
not expand the real writeback safety subset.

`SymphonyElixir.Hub.IssueRef` defines the provider-neutral issue reference boundary for future Hub
ledgers and provider queues. It combines `project_id`, tracker kind, provider scope, provider issue
id or provider-local number/key, identifier, and URL. This is intentionally compatible with the
current GitHub adapter where normalized issue `id` may still be the repository-local issue number:
Hub keys include provider scope and never treat a bare GitHub/GitLab number as globally unique.

`SymphonyElixir.Hub.RuntimeLedger` adds the recoverable runtime fact model for the next #74 slice.
It is a pure model API: `new/1` builds normalized ledgers, `to_snapshot/1` returns a stable
JSON/YAML-safe structure, `from_snapshot/1` rejects snapshots that contain secret-bearing fields,
`validate/1` reports unsafe invariants, `replay/1` produces project-level summaries, and
`observability_snapshot/1` exposes the same safe replay projection for Dashboard/API snapshots.

Runtime ledger facts are partitioned by project and keyed by `project_id + IssueRef`. They cover:

- issue claim status such as unclaimed, claimed, running, retry queued, blocked, released, or
  terminal
- run attempts with attempt id/number, timestamps, stage, worker host, workspace path, terminal
  reason, compact agent session usage, and optional safe run context
- workspace leases with active/released/lost status
- start intents with requested/acknowledged/failed/unknown/manual-attention status
- retry/backoff facts tied to a known attempt
- writeback intent/result facts with a stable logical intent key, replay policy, provider marker,
  external reference, and unknown/manual-attention state for non-idempotent results

The ledger validates that one project/issue has at most one active attempt, one workspace has at
most one active lease, active attempts in claimed/running state have a matching workspace lease,
active start intents point at active attempts and leases, terminal/released issues do not retain
active leases, retry records reference known attempts, run contexts match their containing
project/issue/attempt, and logical writeback intent keys stay stable across retry attempts. Replay
summaries include active attempts, pending start intents, active workspace leases, retry/backoff,
blocked candidates, writeback pending/succeeded/failed/unknown/manual-attention lists, conflicts,
and manual-attention diagnostics, and can be filtered by `project_id`. Ledger snapshots must not
include token values, API keys, credentials, cookies, full prompts, full Codex transcripts, raw
secret-bearing provider config, or full provider writeback/comment body text.

`SymphonyElixir.Hub.ProviderGovernance` adds the provider request governance baseline for the next
#74 slice. It is also a pure model API. `new_request/1` builds a safe provider request record with a
stable request id, provider kind and provider scope key, `project_id`, configuration fingerprint or
snapshot version, optional `IssueRef`, operation kind, priority, fairness key, replay policy,
timeout/deadline/cancellation boundary, and sanitized correlation metadata. `new_queue/1`,
`enqueue/3`, `next_request/2`, `record_result/2`, and `queue_summary/2` define an in-memory
scheduling contract for later Hub poll-coordinator integration: higher-priority work is selected
first, requests within one provider scope are constrained by scope concurrency, and equal-priority
same-scope work rotates across fairness keys so one project cannot continuously occupy the shared
scope. Running issue reconciliation has a higher default priority than candidate scans, and manual
refresh requests can be marked as user initiated in summaries.

Provider governance tracks scope-level availability with sanitized quota/rate-limit summaries,
`backoff_until`, circuit state, last error class, and a backpressure reason. Scope state is keyed by
the same safe provider scope key used by `IssueRef`; bare provider-local issue numbers are not used
as Hub queue identifiers. Blocking errors such as rate limits, active backoff, open circuit, or
scope-concurrency saturation delay only matching-scope requests and are reflected in queue
summaries. Request snapshots, queue summaries, scope state, and result summaries must not include
provider tokens, API keys, credentials, cookies, full prompts, full Codex transcripts, cancellation
token values, or raw secret-bearing provider config.

Provider results are classified as `success`, `retryable_failure`, `permanent_failure`,
`rate_limited`, `circuit_open`, `canceled`, `timed_out`, or `unknown_result`. A result can carry a
provider-safe summary, external reference, retry/backoff suggestion, error class, and ledger link to
an issue key or writeback intent. Unknown results for writeback requests whose replay policy is
`non_replayable` or `unknown_requires_manual_attention` are marked for manual attention and are not
treated as automatically replayable; this prevents duplicate comments, PRs, statuses, or other
provider side effects when a timeout leaves the external outcome uncertain.

`SymphonyElixir.Hub.ProviderToolRouting` adds the opt-in provider tool/writeback routing baseline
for #74. It bridges structured app-server dynamic tools to `ProviderGovernance` without changing
the default legacy direct-client path. A caller enables it by passing `hub_provider_routing` context
and, optionally, `hub_provider_executor` into `SymphonyElixir.Codex.DynamicTool.execute/3`; when that
context is absent, `github_issue`, `github_pr`, and `tracker_issue` keep the existing behavior and
call the configured provider client functions directly.

The routing boundary currently covers the structured provider tools:

- `github_issue`: `get_issue`, `list_comments`, `upsert_workpad_comment`, `set_status`,
  `add_labels`
- `github_pr`: `list_for_head`, `get_pr`, `create_pr`, `list_issue_comments`, `list_reviews`,
  `list_review_comments`, `get_check_status`
- `tracker_issue`: `create_comment`, `set_status`

For enabled calls it builds a safe governance request with project id, provider scope, optional
`IssueRef`, operation kind, priority, replay policy, target summary, and run-context correlation. It
then executes through an injectable boundary, classifies the result, and appends a
`providerGovernance` summary to the dynamic tool payload. Workpad upsert uses marker/upsert replay
semantics keyed by header, status set is idempotent by target state, PR lookup is idempotent by
branch or PR number, PR create is keyed by branch/head and requires manual attention on unknown
result, and ordinary append comments are not blindly replayed after unknown results. Comment and PR
bodies are summarized by size and SHA-256 digest rather than copied into request/result snapshots.

The raw `linear_graphql` escape hatch is intentionally not routed through this baseline yet. It
accepts arbitrary GraphQL documents and variables, so it needs a separate structured operation and
scope-validation model before Hub governance can safely infer replay semantics. Its legacy behavior
therefore remains unchanged.

`SymphonyElixir.Hub.WritebackProcessor` adds the #74 writeback intent/result processing baseline on
top of provider tool routing and the runtime ledger. It accepts atom-key summaries, string-key
payloads, or dynamic tool payloads containing `providerGovernance`; normalizes the routed
writeback intent/result into a safe ledger fact; and can apply that fact to a recoverable ledger
snapshot. `decide/3` compares a candidate writeback with existing facts in the same
`project_id + IssueRef` scope and returns whether the Hub should reuse an already completed result,
retry a policy-safe pending/retryable writeback, require a PR lookup by branch/head before replay,
enter manual attention, or report a conflict.

The decision model treats status set and workpad upsert as replay-safe when the intent key and
target remain stable. Unknown PR create and ordinary append-comment results are not blindly
replayed: PR create returns a provider lookup hint for branch/head, while append comment enters
manual attention because the provider may already have accepted the side effect. The processor also
surfaces unstable intent keys and same-intent-key/different-target conflicts through the
`RuntimeLedger` diagnostics already consumed by replay/observability summaries. This remains a
model boundary only; it does not implement the final Hub scheduler, provider writeback executor,
database persistence, or Dashboard page, and the legacy single-project direct provider path remains
the default unless a caller explicitly opts into Hub routing.

`SymphonyElixir.Hub.PollCoordinator` adds the Hub poll coordination baseline. It is a pure model
API: `build_plan/2` combines Hub project snapshots, provider governance queue/scope state, and
recoverable poll facts into a safe poll plan. Each plan entry reports project identity, workflow and
tracker identity, provider scope, effective poll interval, eligibility reason, `next_due_at`,
optional `backoff_until`, governance request metadata, and whether the project may poll now. Poll
requests are represented through `ProviderGovernance` as `candidate_scan` requests with project
fairness keys, so shared-scope backoff, circuit, quota, and concurrency decisions use the same
boundary as future provider exits.

The coordinator also exposes `attempt_fact/2`, `result_fact/3`, `plan_fact/2`, `to_snapshot/1`,
`from_snapshot/1`, and `observability_snapshot/1`. Replaying result/backoff facts into
`build_plan/2` prevents restart or repeated refreshes from immediately polling every registered
project without regard to the previous safe due time. Retryable failures, rate limits, and
timeouts produce backoff/next-due decisions for the affected project or provider scope; permanent
poll failures keep the affected project ineligible with a config/error-style reason until the
configuration or operator action changes the facts. If an orchestrator or Hub runtime snapshot
includes `hub_poll_coordination`, the observability presenter exposes the sanitized plan summary in
`/api/v1/state`; legacy snapshots without that field keep the existing API shape.

`SymphonyElixir.Hub.DeviceObservability` adds the #74 device-level observability / migration
boundary baseline. It is a pure projection API: `build/2` accepts safe Hub model summaries such as
project registry snapshots, provider governance queue summaries, poll coordination observability,
runtime ledger replay, dispatch summaries, writeback observability, and optional legacy project
markers, then returns one Dashboard/API-safe device view. The projection includes device counts
(`project_count`, active agent count, max agent capacity, provider scope count), per-project status
(`running`, `idle`, `ready_to_poll`, `backoff`, `paused`, `blocked`, `manual_attention`,
`legacy_only`, or `config_invalid`), provider queue/quota/backoff/circuit summaries, poll
eligibility and next due time, active workspace/attempt/start-intent facts, writeback
unknown/manual-attention/conflict facts, and backpressure reasons such as provider rate limit,
queue pressure, project pause/backoff, workspace occupied, active attempt exists, writeback unknown,
activation preflight blocked, and manual attention. When a Hub runtime provides
`hub_activation_preflight`, each project also includes the sanitized preflight status, blocked
operations, probe source, checked time, detected legacy ownership summary, unknown probe results,
and conflict/manual-attention counts.

The projection is safe for logs, `/api/v1/state`, and future Dashboard snapshots. It accepts
atom-key or string-key snapshots without dynamically creating atoms, preserves unknown map keys as
strings, and redacts provider tokens, API keys, authorization/cookie fields, secret env values, raw
provider config, full prompts, full transcripts, full comment/PR body text, raw provider responses,
raw systemd output, raw hook/app-server output, and exception stack traces. If one project summary
is malformed, missing expected fields, or carries an incompatible version, only that project is
marked with `summary_error`/manual attention; the overall API/Dashboard payload remains available.
When an orchestrator snapshot contains `hub_device_observability`, the presenter exposes the
sanitized projection in `/api/v1/state` and the Live Dashboard renders the Hub device and project
detail sections. Snapshots without that field keep the existing legacy API and Dashboard shape.
This is not a Hub scheduler, provider executor, migration command, or service migration. The legacy
`symphony@project.service` direct poll/writeback path remains the default until an explicit Hub
integration opts into routing and ownership.

`SymphonyElixir.Hub.DispatchBoundary` adds the Hub atomic dispatch / run context baseline for #74.
It is also a pure model API. `build_context/3` turns a candidate issue into a stable dispatch
context with project id, configuration fingerprint or snapshot version, provider-neutral
`IssueRef`, workflow/tracker summary, trigger source (`poll_plan`, `manual_refresh`, `webhook`,
`running_reconciliation`, or `recovery`), governance/correlation metadata, attempt number/id input,
workspace path/lease id, start intent id, worker/runtime summary, runner summary, and preflight
diagnostics. Preflight reports whether the candidate can start or is blocked by an existing active
attempt, unresolved start intent, workspace conflict, retry/backoff, project pause, config error,
provider backpressure, or explicit block.

`SymphonyElixir.Hub.CandidateIntake` is the preceding poll-to-dispatch boundary. It reads only safe
candidate summaries from governed provider candidate-scan results, supports atom-key and string-key
input, isolates malformed candidates instead of failing the whole tick, and produces project-level
candidate/eligible/skipped counts plus reason counts. Its dispatch eligibility check reuses the
model-only dispatch preflight and runtime ledger facts, but it does not call `dispatch/3`, start a
worker, create a workspace lease, or write back to a provider.
Candidate identity is source-bound: the poll source and registry project provide the authoritative
`project_id`, provider kind, provider scope key, and provider scope. Candidate or input_ref
project/scope fields are accepted only when they match that source; cross-project, cross-provider,
or cross-repository mismatches are isolated as invalid candidates and never become
`ready_for_dispatch_evaluation`.

`SymphonyElixir.Hub.DispatchPlanning` is the Hub runtime's eligible-candidate-to-start-intent
planning baseline. It consumes the safe candidate intake snapshot and emits per-candidate planning
outcomes plus pending intent summaries. A planned record is keyed by `project_id`, provider scope,
IssueRef-derived issue key, stable attempt id, and stable start intent id, and it keeps source poll
and intake correlation. Previous pending plans and unresolved runtime-ledger start intents are
recovered on refresh as `already_planned` rather than duplicated. The planner also reserves
project/global capacity across candidates in the same tick, so one eligible candidate can consume a
project slot and later eligible candidates for that project are reported as capacity unavailable.
Manual attention, provider/project backoff, paused/config-error projects, active attempts,
workspace/lease conflicts, retry backoff, and invalid identity remain skipped outcomes. This
planning boundary is still model-only: it does not call `dispatch/3`, launch Codex, create a real
workspace, write a provider, or take over the legacy `symphony@project.service` path.

`SymphonyElixir.Hub.DispatchPlanApplication` is the Hub runtime's plan-to-ledger skeleton. It
consumes `hub_dispatch_planning`, selects only planned eligible pending intents, and calls
`DispatchBoundary.dispatch/3` against the current runtime ledger. The resulting snapshot records
recoverable model facts for the claim, attempt, workspace lease, pending start intent, and safe run
context, including poll/intake/planning correlation. The application summary exposes per-project
applied, skipped, blocked, already-applied, already-planned, manual-attention, and reason counts,
plus pending start-intent summaries and a runtime-ledger replay summary. It reuses dispatch
preflight and capacity checks, so repeated refreshes, duplicate candidates, active attempts,
workspace conflicts, retry/backoff, project pause/config error, provider backpressure, manual
attention, and capacity limits remain observable instead of causing a blind double start.

This is still not a scheduler or worker launcher. The application boundary does not start Codex,
create a real worker workspace, run workspace hooks, write GitHub/GitLab/Linear provider state,
comments, or PRs, persist a database/WAL transaction, or migrate the legacy
`symphony@project.service` path.

`SymphonyElixir.Hub.WorkerStartHandoff` is the Hub runtime's start-intent-to-acknowledgement
skeleton. It consumes runtime-ledger replay, selects unresolved pending start intents, and builds a
safe handoff request containing project/provider scope/IssueRef, attempt/start intent/workspace
lease, runner/start command summary, and source poll/intake/planning correlation. Tests and future
callers can inject a starter function or module returning `ack`, `failed`, `unknown`, or
`manual_attention`; the default skeleton does not launch a worker and records an unknown result. Ack
updates the ledger through `acknowledge_start/3`; failures use `record_start_failure/4`; unknown uses
`record_start_unknown/3` and remains unresolved so later refreshes report a skipped
`start_intent_unresolved` reason instead of blindly starting a second attempt.

This is still not real worker integration. The handoff boundary does not start Codex app-server,
create worker workspaces, execute workspace hooks, write GitHub/GitLab/Linear provider state,
replace the legacy worker supervisor, persist a durable database/WAL, or provide distributed locks.
Those pieces remain future Hub scheduler/worker integration work.

`SymphonyElixir.Hub.WorkerLifecycleReconciliation` is the Hub runtime's first post-ack lifecycle
reconciliation baseline. It runs after a start intent has been acknowledged and consumes only
controlled worker/session lifecycle summaries, not raw provider payloads. Test callers and future
supervisors can inject a result source returning `running`, `succeeded`, `failed`, `cancelled`,
`timeout`, `stopped`, `lost`, `unknown`, or `manual_attention` summaries with safe attempt/start
intent/session/workspace/source correlation. Reconciliation applies those summaries through the
runtime ledger: succeeded/cancelled/timeout/stopped outcomes release the matching workspace unless a
retained reason is explicitly recorded, retryable failures enter retry/backoff, blocked outcomes are
observable, and lost/unknown/manual-attention outcomes retain the active attempt/workspace so Hub
does not silently release evidence and immediately start a second worker.

The summary is exposed as `hub_worker_lifecycle_reconciliation` and in `hub_runtime` tick summaries.
It reports selected/applied counts, running attempt count, terminal and unresolved status counts,
reason counts, and workspace released/retained counts. The replayed dispatch boundary also exposes
per-project lifecycle summaries. All fields are sanitized; transcripts, prompts, provider bodies,
provider tokens, authorization/cookie values, secret env, raw config, and raw hook/app-server output
are omitted. This remains a model/runtime reconciliation boundary only: it is not a full Hub
scheduler loop, cross-process worker supervisor, provider writeback executor, durable store, or
legacy service migration.

`dispatch/3` applies the context to a runtime ledger snapshot as one model-level transition:
claiming the issue, creating the attempt, acquiring the workspace lease, recording a start intent,
and attaching a safe run context. A repeated candidate for the same `project_id + IssueRef` returns
an idempotent `:ignored` result instead of adding a second active attempt. A workspace already held
by another active attempt returns a workspace-conflict preflight error. `acknowledge_start/3`
connects a start intent to a running attempt and compact agent session summary. `record_start_failure/4`
can move a half-started attempt to retry queued, blocked, released, or manual attention; unknown
worker-start results keep an unresolved start intent so recovery can explain the state and avoid a
blind double start. `record_worker_lifecycle/3` applies post-ack lifecycle results with idempotent
attempt/start-intent/session/workspace matching. Duplicate terminal results are ignored, conflicting
late terminal results are skipped, late still-running results after a confirmed terminal result
cannot revive the attempt, and mismatched workspace leases cannot release the wrong workspace.
`release_attempt/3` closes the attempt and releases the workspace lease.

Run context snapshots include project/workflow/tracker snapshot references, issue identity, stage,
attempt/correlation ids, workspace lease/path, worker host/runtime identity summary, runner/start
command summary, session/activity timestamps, and exit summary. They intentionally do not include
provider tokens, API keys, secret env values, cookies, full prompts, complete Codex transcripts, raw
secret-bearing config, or full provider body fields. Hub provider/poll/runtime summaries redact
`body`, `comment_body`, `pull_request_body`, `pr_body`, `raw_provider_body`, and `full_prompt` to
safe hash/byte metadata even when those fields appear without token or authorization values. If a
runtime snapshot includes `hub_dispatch_boundary`, the observability
presenter exposes the sanitized replay summary in `/api/v1/state`; legacy snapshots without that
field keep the existing API shape.

This remains a #74 Hub execution skeleton only. It does not start a full Hub scheduler, persistent
provider queue, database-backed store, cross-process distributed lock, real legacy provider adapter
migration, or legacy worker lifecycle replacement. The existing
`./bin/symphony --tracker-config ./TRACKER.yaml ./WORKFLOW.md` startup path remains the legacy
single-project runtime, and the legacy `Orchestrator` keeps its current in-memory `running`,
`claimed`, `retry_attempts`, `blocked`, tracker fetch, stage writeback, workpad/PR operation, and
dynamic-tool behavior until a later explicit Hub integration. The provider tool routing adapter can
execute real provider calls only when the dynamic tool caller explicitly opts in to the boundary.

GitHub Project v2 Status `TRACKER.yaml` example:

```yaml
tracker:
  kind: github
  api_key: "$GITHUB_TOKEN"
  owner: your-org
  repo: your-repo
  project_number: 1
  workflow_state:
    strategy: project_v2_status
    field_name: Status
    state_options:
      ready: Context Check
      in_progress: Implementation
      done: Done
      blocked: Blocked
      protocol_blocked: Protocol Blocked
```

GitLab scoped-label `TRACKER.yaml` example:

```yaml
tracker:
  kind: gitlab
  endpoint: "https://gitlab.com/api/v4"
  api_key: "$GITLAB_TOKEN"
  project_slug: "your-group/your-project"
  workflow_state:
    strategy: scoped_label
    label_prefix: "status::"
    state_name_format: kebab_case
    close_on_terminal:
      - done
```
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back workflow-stage turns Symphony will run in a single
  agent invocation. Default: `20`.
- Every Codex turn uses the system-maintained workflow-stage wrapper rendered for the current stage.
  The Markdown body is not used as a legacy issue prompt in the runner path.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- `hooks.timeout_ms` controls workspace hook timeouts. If `after_create` times out or fails,
  Symphony terminates the local hook process tree and removes the newly-created workspace before
  retrying, so a later attempt does not reuse a partial clone.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from the selected tracker's token env var when unset or when value is the
  matching `$VAR`: `LINEAR_API_KEY`, `GITHUB_TOKEN`, or `GITLAB_TOKEN`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  timeout_ms: 300000
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- In workflow-stage mode, if `TRACKER.yaml` is missing or invalid, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/workflow`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.
- The same Phoenix service also exposes an operator-only multi-instance management surface at
  `/admin/instances`, `/api/v1/admin/instances*`, and `/api/v1/admin/auto-update*`. It discovers
  independently deployed `symphony@<project>.service` instances from the systemd-template config
  directory plus user-level systemd units, and does not change the single-instance orchestrator
  scheduling model.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- LiveView for workflow-stage configuration visualization at `/workflow`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Mermaid as a vendored static asset for the workflow-stage graph at `/workflow`

All LiveView pages share a compact workspace navigation bar with three operator paths:

- `Hub 运行总览` for the current process and Hub device dashboard at `/`
- `流程配置` for the read-only workflow/tracker configuration view at `/workflow`
- `实例管理` for the local operator management plane at `/admin/instances`

The navigation bar also shows whether the browser session is a loopback `本机管理员` session or a
`远程只读` session, so operators can tell whether visible controls are executable or only a preview.
On wide screens, the same shell renders a compact left-side page outline built from the current
page's main sections. The outline highlights the section near the current scroll position and its
links jump directly to the section; links targeting collapsed diagnostic details open the containing
detail panel before focusing the target. Narrow screens keep the single-column layout and hide the
outline so content width is preserved.

The dashboard at `/` is the Hub 运行总览 for the current Symphony process:
it shows the local orchestrator snapshot, current attention items, Hub active attempts, retry/blocking
pressure, token totals, and issue detail links. Its first operator section is the source of truth for
current running/Hub/blocking/retry attention; cost-only metrics such as Token 总数 and 运行时长 are
moved into a separate 运行消耗 panel so they do not duplicate the attention summary. In Hub mode the
first operator section prioritizes the current work queue and a compact Hub project focus list, so
active attempts, workspace leases, manual attention, and the next project-level action are visible
before lower-level Hub diagnostics. Hub project next actions are rendered as operator-readable action
text on their own row, with a second line that names the project, the attempt/workspace
lease/lifecycle counts, the Hub 项目明细 evidence entry point, and the read-only boundary. Hub project
focus rows point to the expandable Hub project detail entry instead of jumping into content that is
closed by default；点击后会自动展开 Hub 项目明细并聚焦目标 project 行。When the normal running-session
count is zero but Hub attempts are still active, the first-screen link points to the relevant Hub
project instead of the empty running-session section. The page header also labels the current access
role, whether the first snapshot is loaded, and that the dashboard is a read-only observation surface. The context panel remains
available for traceability and summarizes whether the view is a single instance or Hub device
runtime, the active `WORKFLOW.md` path, the selected `TRACKER.yaml` path, the snapshot timestamp,
and the `/api/v1/state` entry. Empty rate-limit snapshots are hidden, and the full Hub device
diagnostic matrix plus the full Hub project detail table are behind expandable high-detail sections
after the compact health overview.

The workflow dashboard at `/workflow` is a read-only configuration understanding surface. It loads
the current `WORKFLOW.md` directly, renders a Mermaid stage graph with clickable nodes and
outcome-labelled directed edges, marks `workflow.start_stage`, `workflow.terminal_stages`,
blocked/protocol-blocked paths, and shows the selected stage plus
`workflow.missing_outcome.max_retries`/`on_exhausted` separately from ordinary transitions.
The first screen uses a compact status strip for the start stage, stage count, terminal count,
runtime snapshot, and diagnostics. Warning/error diagnostics show the first actionable diagnostic
summary next to the count instead of only a generic number; common reachability warnings are shown
as Chinese operator actions first, with raw diagnostic code and message still available in the
diagnostics list. Mermaid graph nodes are clickable and keyboard-focusable, with a visible focus
style for the rendered SVG node shape.
能定位到具体 stage 的诊断（例如 unreachable stage）会同时提供“查看 ... 阶段”和完整诊断列表入口；
可滚动 prompt 预览会标记为只读预览区域，方便键盘和辅助技术用户理解它不是可执行控件。
On desktop the stage graph and selected-stage inspector share the first workflow panel, so clicking
a graph node updates visible stage details without forcing the operator below the graph. On narrow
screens the page adds a text-first stage flow overview near the Mermaid graph so operators can read
each stage, runtime count, and `outcome -> target` transition without horizontal scrolling or
zooming. Missing-outcome handling and tracker stage-state mapping sit below it. It
also previews each stage prompt, lists outcome targets, reports semantic warnings such as
unreachable stages or non-terminal stages without transitions, and summarizes `TRACKER.yaml`
stage-state coverage. The first summary row includes the warning/error diagnostic count and links
directly to the diagnostics section; when diagnostics contain operator warnings, the header marks the
configuration as needing attention instead of only saying it is readable. Tracker provider details are
limited to non-secret hints such as kind, owner/repo/project number or label prefix; token,
`api_key`, env secret, and credential fields are not rendered. When an orchestrator snapshot is
available, the page overlays running/retrying/blocked
issue counts by `current_stage`; if the snapshot is unavailable, the static workflow graph and
configuration diagnostics still render.

The multi-instance dashboard at `/admin/instances` is a thin operator management plane. It reads
registered instances from `~/.config/symphony/projects` by default, checks each
`symphony@<project>.service` via `systemctl --user`, and queries each reachable instance's
`/api/v1/state`. The page renders its operator shell first, then loads the instance overview in a
bounded background refresh so slow probes do not block the first screen. Instance aggregation,
GitHub main auto-update status, and systemd timer status are displayed as separate loading lanes,
so operators can see which part is still being probed. Stopped, failed, slow, or unreachable
instances are rendered as per-instance health states and do not block the rest of the overview. The
fleet summary puts the unreachable/unknown instance count first and labels running, retrying, and
blocked counts as reachable-instance totals, so missing state snapshots are not mistaken for zero
issue risk. Individual unreachable/unknown cards show Issue 压力 as unknown instead of rendering
`0/0/0`. Dashboard/API links are clickable only when the instance is running and reachable; stopped,
failed, unreachable, or remote-browser `127.0.0.1` targets are shown as disabled entries with a
visible reason and the URL still available for inspection, while missing URLs stay quiet and only
show the missing-port/entry hint. The update timer buttons are also gated by current state, so an
already enabled/active timer does not present “enable” as an available action.
管理页顶部会把当前控制台和被管理 project 实例端口范围分开说明，避免把 project 实例的
`stopped` 或不可达误解成 `/admin/instances` 当前控制台停止。被管理实例不可达或未知时，
update-timer 的启用、禁用、手动触发确认文案会先说明该风险，再让 operator 确认是否继续。
While the instance overview is still loading, create, auto-update, and update-timer write actions
are disabled and linked to a visible loading reason; if the instance overview fails before any
snapshot has loaded, those write actions remain locked until the overview is restored. Disabled
buttons use neutral styling rather than retaining primary or danger colors. Remote read-only sessions
cannot open the create-instance form because submission would still be rejected server-side.
The page can create GitHub-backed instances by delegating to
`scripts/install-systemd-template.sh`, auto-allocates ports after checking existing env files and
listening sockets, and exposes `start`, `stop`, `restart`, `enable`, `disable`, and recent-log
actions for each service. Issue dispatch, retry semantics, workspace isolation, and Codex
app-server behavior remain owned by each individual instance's orchestrator.

Admin instance creation accepts either a one-time token entry or an environment variable reference;
tokens are passed only to the install script environment and are not returned by the JSON API or
rendered back into the page. Project names are restricted to safe systemd instance/path characters.
Admin JSON endpoints and LiveView actions are restricted to loopback clients because they can run
local `systemctl`, `journalctl`, and install-script commands. Remote browser sessions can still
view the management page as a read-only overview, but create, update, lifecycle, timer, and log
buttons are visibly disabled and continue to be guarded server-side; the admin JSON API link is
shown only to loopback administrator sessions. Destructive or high-impact
operations such as creating instances with optional immediate start/timer enablement, starting or
enabling systemd services, stop, restart, disable, manual update execution, and timer enablement or
triggering require a LiveView confirmation prompt that names the affected service or operation and
states that systemd or automation state will change. Long-running actions use LiveView
loading/disable feedback, and operation results render in a status or alert banner rather than as
an unclassified text block. The page also disables actions that do not match the current state, such
as GitHub main update execution while auto-update is unavailable or lifecycle operations for
archived/not-found legacy units, and links each disabled control to a visible reason. Instance
creation validation reports field-level errors with an error summary before the install script is
called, so invalid project names, repo fields, ports, project numbers, max-agent counts, and token
environment references can be corrected in place.

The same management page shows `symphony-update.timer` state, including enabled/active status and
the next run time, and can enable, disable, or manually trigger `symphony-update.service`.

The same page includes a GitHub `main` auto-update control panel. `SymphonyElixir.AutoUpdate`
polls `jhihjian/symphony` with GitHub REST ETag/`If-None-Match` requests, records the current
deployed SHA, remote SHA, next check time, rate-limit metadata, and any last error, and exposes
manual check/update triggers through `/api/v1/admin/auto-update`. Update execution is serialized
with a host-local lock, refuses to proceed when the source checkout has local changes, fetches and
fast-forwards `origin/main`, builds only after code changed, and restarts instances only after a
successful build. If the auto-update state process is busy or unavailable, the management page and
admin auto-update API return an `unavailable` snapshot instead of failing the whole operator view.
The management page treats that state as unavailable/unknown rather than up to date; instance
management remains usable, but operators should inspect the auto-update process before relying on
update status.

Per-instance restart policy is read from `SYMPHONY_UPDATE_STRATEGY` in each instance `env` file:

- `idle_restart` / `defer_until_idle`: active idle instances restart immediately; instances with
  active sessions are marked pending idle.
- `download_only`: update and build the deployed program without restarting the instance.
- `manual_restart`: require an operator to restart after the build.
- `force_restart`: explicit dangerous mode that restarts even when active sessions exist.

Failed instances are never restarted automatically, and inactive enabled instances are updated but
not started by default.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `TRACKER.yaml`: in-repo provider/runtime config used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run deterministic local end-to-end tests without external network dependencies:

```bash
make e2e
```

`make e2e` covers:
- memory tracker dispatch/write-event smoke through the real orchestrator
- GitHub Issues and GitLab Issues tracker dispatch, state refresh, and terminal cleanup
- fake Codex app-server turns, dynamic tools, and workspace creation
- provider contract checks for GitHub GraphQL/REST and GitLab REST request construction

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e-live
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e-live` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e-live` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes temporary workflow/tracker
configuration, runs a real agent turn, verifies the workspace side effect, requires Codex to
comment on and close the Linear issue, then marks the project completed so the run remains visible
in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
