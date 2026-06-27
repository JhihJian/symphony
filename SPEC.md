# Symphony Service Specification

Status: Draft v1 (language-agnostic)

Purpose: Define a service that orchestrates coding agents to get project work done.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and
`OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract, but this
specification does not prescribe one universal policy. Implementations MUST document the selected
behavior.

## 1. Problem Statement

Symphony is a long-running automation service that continuously reads work from a configured issue
tracker, creates an isolated workspace for each issue, and runs a coding agent session for that
issue inside the workspace.

The service solves four operational problems:

- It turns issue execution into a repeatable daemon workflow instead of manual scripts.
- It isolates agent execution in per-issue workspaces so agent commands run only inside per-issue
  workspace directories.
- It keeps workflow policy in-repo (`WORKFLOW.md`) and tracker/runtime config in explicit
  `TRACKER.yaml` files so teams version agent prompts, workflow stages, and runtime settings with
  their code.
- It provides enough observability to operate and debug multiple concurrent agent runs.

Implementations are expected to document their trust and safety posture explicitly. This
specification does not require a single approval, sandbox, or operator-confirmation policy; some
implementations target trusted environments with a high-trust configuration, while others require
stricter approvals or sandboxing.

Important boundary:

- Symphony is a scheduler/runner and tracker reader.
- Ticket writes (state transitions, comments, PR links) are typically performed by the coding agent
  using tools available in the workflow/runtime environment.
- A successful run can end at a workflow-defined handoff state (for example `Human Review`), not
  necessarily `Done`.

## 2. Goals and Non-Goals

### 2.1 Goals

- Poll the issue tracker on a fixed cadence and dispatch work with bounded concurrency.
- Maintain a single authoritative orchestrator state for dispatch, retries, and reconciliation.
- Create deterministic per-issue workspaces and preserve them across runs.
- Stop active runs when issue state changes make them ineligible.
- Recover from transient failures with exponential backoff.
- Load runtime behavior from a repository-owned `WORKFLOW.md` contract.
- Expose operator-visible observability (at minimum structured logs).
- Support tracker/filesystem-driven restart recovery without requiring a persistent database; exact
  in-memory scheduler state is not restored.

### 2.2 Non-Goals

- Rich web UI or multi-tenant orchestration control plane.
- Making any optional management surface required for issue dispatch, workspace isolation, or agent
  runtime correctness.
- Prescribing a specific dashboard or terminal UI implementation.
- General-purpose workflow engine or distributed job scheduler.
- Built-in business logic for how to edit tickets, PRs, or comments. (That logic lives in the
  workflow prompt and agent tooling.)
- Mandating strong sandbox controls beyond what the coding agent and host OS provide.
- Mandating a single default approval, sandbox, or operator-confirmation posture for all
  implementations.

## 3. System Overview

### 3.1 Main Components

1. `Workflow Loader`
   - Reads `WORKFLOW.md`.
   - Parses provider-neutral workflow YAML front matter and prompt body.
   - Returns raw config, parsed workflow definition, and prompt template.

2. `Config Layer`
   - Loads `TRACKER.yaml` in workflow-stage mode.
   - Exposes typed getters for workflow and tracker/runtime config values.
   - Applies defaults and environment variable indirection.
   - Performs validation used by the orchestrator before dispatch.

3. `Issue Tracker Client`
   - Exposes a stage-aware tracker contract using provider-neutral workflow stage ids.
   - Adapters that have not implemented provider-specific stage mapping MUST report an explicit
     unsupported stage-contract boundary rather than falling back to legacy active-state dispatch.
   - Fetches runnable issues from the provider state mapped to `workflow.start_stage`.
   - Fetches current states for specific issue IDs (reconciliation).
   - Normalizes tracker payloads into a stable issue model.
   - Treats provider-visible state/status/label values as external observation and recovery records,
     not as the normal trigger for progressing one issue through workflow stages.

4. `Orchestrator`
   - Owns the poll tick.
   - Owns the in-memory runtime state.
   - Decides which issues to dispatch, retry, stop, or release.
   - Tracks session metrics and retry queue state.

5. `Workspace Manager`
   - Maps issue identifiers to workspace paths.
   - Ensures per-issue workspace directories exist.
   - Runs workspace lifecycle hooks.
   - Cleans workspaces for terminal issues.

6. `Agent Runner`
   - Creates workspace.
   - Builds prompt from issue + workflow template.
   - Launches the coding agent app-server client.
   - Streams agent updates back to the orchestrator.

7. `Status Surface` (OPTIONAL)
   - Presents human-readable runtime status (for example terminal output, dashboard, or other
     operator-facing view).

8. `Logging`
   - Emits structured runtime logs to one or more configured sinks.

### 3.2 Abstraction Levels

Symphony is easiest to port when kept in these layers:

1. `Policy Layer` (repo-defined)
   - `WORKFLOW.md` workflow-stage schema and stage prompts.
   - Team-specific rules for ticket handling, validation, and handoff.

2. `Configuration Layer` (typed getters)
   - Parses `WORKFLOW.md` and `TRACKER.yaml` into typed runtime settings.
   - Handles defaults, environment tokens, and path normalization.

3. `Coordination Layer` (orchestrator)
   - Polling loop, issue eligibility, concurrency, retries, reconciliation.

4. `Execution Layer` (workspace + agent subprocess)
   - Filesystem lifecycle, workspace preparation, coding-agent protocol.

5. `Integration Layer` (tracker adapter)
   - API calls and normalization for the configured tracker kind.

6. `Observability Layer` (logs + OPTIONAL status surface)
   - Operator visibility into orchestrator and agent behavior.

### 3.3 External Dependencies

- Issue tracker API for the configured tracker kind.
- Local filesystem for workspaces and logs.
- OPTIONAL workspace population tooling (for example Git CLI, if used).
- Coding-agent executable that supports the targeted Codex app-server mode.
- Host environment authentication for the issue tracker and coding agent.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue

Normalized issue record used by orchestration, prompt rendering, and observability output.

Fields:

- `id` (string)
  - Stable tracker-internal ID.
- `identifier` (string)
  - Human-readable ticket key (example: `ABC-123`).
- `title` (string)
- `description` (string or null)
- `priority` (integer or null)
  - Lower numbers are higher priority in dispatch sorting.
- `state` (string)
  - Current tracker state name.
- `branch_name` (string or null)
  - Tracker-provided branch metadata if available.
- `url` (string or null)
- `labels` (list of strings)
  - Normalized to lowercase.
- `blocked_by` (list of blocker refs)
  - Each blocker ref contains:
    - `id` (string or null)
    - `identifier` (string or null)
    - `state` (string or null)
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)

#### 4.1.2 Workflow Definition

Parsed `WORKFLOW.md` payload:

- `config` (map)
  - YAML front matter root object.
- `workflow` (map or typed structure)
  - Provider-neutral workflow stages, outcomes, missing-outcome handling, and transitions.
- `prompt_template` (string)
  - Markdown body after front matter, trimmed.

#### 4.1.3 Service Config (Typed View)

Typed runtime values derived from `WorkflowDefinition.config`, `TRACKER.yaml`, and environment
resolution.

Examples:

- poll interval
- workspace root
- workflow definition and tracker stage-state mapping
- derived active and terminal issue states for legacy scheduler compatibility
- concurrency limits
- coding-agent executable/args/timeouts
- workspace hooks

#### 4.1.4 Workspace

Filesystem workspace assigned to one issue identifier.

Fields (logical):

- `path` (absolute workspace path)
- `workspace_key` (sanitized issue identifier)
- `created_now` (boolean, used to gate `after_create` hook)

#### 4.1.5 Run Attempt

One execution attempt for one issue.

Fields (logical):

- `issue_id`
- `issue_identifier`
- `attempt` (integer or null, `null` for first run, `>=1` for retries/continuation)
- `workspace_path`
- `started_at`
- `status`
- `error` (OPTIONAL)

#### 4.1.6 Live Session (Agent Session Metadata)

State tracked while a coding-agent subprocess is running.

Fields:

- `session_id` (string, `<thread_id>-<turn_id>`)
- `thread_id` (string)
- `turn_id` (string)
- `codex_app_server_pid` (string or null)
- `last_codex_event` (string/enum or null)
- `last_codex_timestamp` (timestamp or null)
- `last_codex_message` (summarized payload)
- `codex_input_tokens` (integer)
- `codex_output_tokens` (integer)
- `codex_total_tokens` (integer)
- `last_reported_input_tokens` (integer)
- `last_reported_output_tokens` (integer)
- `last_reported_total_tokens` (integer)
- `turn_count` (integer)
  - Number of coding-agent turns started within the current worker lifetime.

#### 4.1.7 Retry Entry

Scheduled retry state for an issue.

Fields:

- `issue_id`
- `identifier` (best-effort human ID for status surfaces/logs)
- `attempt` (integer, 1-based for retry queue)
- `due_at_ms` (monotonic clock timestamp)
- `timer_handle` (runtime-specific timer reference)
- `error` (string or null)

#### 4.1.8 Orchestrator Runtime State

Single authoritative in-memory state owned by the orchestrator.

Fields:

- `poll_interval_ms` (current effective poll interval)
- `max_concurrent_agents` (current effective global concurrency limit)
- `running` (map `issue_id -> running entry`)
- `claimed` (set of issue IDs reserved/running/retrying)
- `retry_attempts` (map `issue_id -> RetryEntry`)
- `completed` (set of issue IDs; bookkeeping only, not dispatch gating)
- `codex_totals` (aggregate tokens + runtime seconds)
- `codex_rate_limits` (latest rate-limit snapshot from agent events)

#### 4.1.9 Hub Project Snapshot (OPTIONAL)

Implementations that expose Hub mode MAY load several project registrations into a device-level
project registry. A Hub project snapshot is a safe, observable view of one registered project. It is
used as a model baseline for future Hub ledgers, provider queues, and device-level status surfaces;
it does not by itself require a Hub-owned poll loop.

Fields:

- `project_id` (string)
  - Stable project identity suitable for logs, filesystem keys, and future ledger keys.
- `name` (string or null)
  - Human-readable display name.
- `dispatch_enabled` (boolean)
  - Whether new dispatch is enabled for this project registration.
- `paused` (boolean)
  - True when dispatch is disabled or the project failed to load.
- `status` (`ready`, `paused`, or `error`)
- `workflow_path` (absolute path string)
- `tracker_config_path` (absolute path string)
- `workflow_summary`
  - `start_stage`, `terminal_stages`, and sorted `stage_ids`.
- `tracker_summary`
  - `kind`, provider scope, provider scope key, and required labels.
  - MUST NOT contain tokens, API keys, credentials, or raw secret-bearing tracker config.
- `runtime_summary`
  - Workspace root, agent concurrency limits, polling interval, and Dashboard/API port if any.
- `fingerprint`
  - Stable digest of the non-secret configuration snapshot used to detect project config changes.
- `loaded_at`
  - Timestamp of the most recent load attempt.
- `load_error` (string or null)
  - Diagnostic error for the project only. One invalid project MUST NOT discard valid snapshots for
    other projects.

#### 4.1.10 Hub IssueRef (OPTIONAL)

Hub-compatible implementations SHOULD define a provider-neutral issue reference used by future
ledgers, queues, and cross-project observability.

Fields:

- `project_id`
- `tracker_kind`
- `provider_scope`
  - GitHub: owner/repo, optionally project number.
  - GitLab: project slug or numeric project ID.
  - Linear: project/team scope as configured by the adapter.
  - Memory: namespace.
- `provider_scope_key`
  - Stable string form of `tracker_kind + provider_scope`.
- `provider_issue_id`
  - Provider issue ID when available.
- `provider_local_id`
  - Provider-local number/key when available.
- `identifier`
  - Human-readable issue identifier.
- `url`
  - Provider URL when available.

The Hub key MUST include `project_id` and provider scope. Provider-local numbers such as GitHub
`#42` or GitLab `iid=42` MUST NOT be used alone as globally unique Hub identifiers.

#### 4.1.11 Hub Runtime Ledger Snapshot (OPTIONAL)

Hub-compatible implementations SHOULD define a recoverable runtime ledger fact model keyed by
`project_id + IssueRef`. The ledger is a stable, serializable model for restart/replay diagnostics
and future Hub coordination. It does not by itself require the implementation to move polling,
claiming, workspace cleanup, provider requests, or agent dispatch out of the existing
single-project orchestrator.

Ledger-level fields:

- `version`
  - Integer snapshot schema version.
- `generated_at`
  - Timestamp for initial snapshot creation.
- `updated_at`
  - Timestamp for the most recent snapshot update.
- `projects`
  - Per-project ledger partitions.

Project ledger fields:

- `project_id`
  - MUST follow the Project ID rules in section 4.2.
- `config_fingerprint` or `snapshot_version`
  - Identifies the safe Hub project configuration snapshot used by the ledger facts.
- `issues`
  - Runtime facts for issue scopes keyed by `project_id + IssueRef`.
- `workspace_leases`
  - Workspace occupancy facts for active/released/lost leases.

Issue ledger fields:

- `issue_ref`
  - Provider-neutral Hub `IssueRef`; a bare GitHub/GitLab number MUST NOT be used as the global key.
- `issue_key`
  - Stable key derived from `project_id`, provider scope key, and provider issue identity.
- `claim_status`
  - Diagnostic status such as `unclaimed`, `claimed`, `running`, `retry_queued`, `blocked`,
    `released`, or `terminal`.
- `current_stage`, `claimed_at`, `released_at`, `terminal_reason`
  - Current workflow-stage and lifecycle summary.
- `attempts`
  - Run-attempt facts.
- `retry_backoff`
  - Optional retry/backoff fact referencing a known attempt.
- `writebacks`
  - Writeback intent/result facts.

Run attempt fields:

- `attempt_id` and `attempt_number`
  - Stable attempt identity within one issue ledger scope.
- `status`
  - Diagnostic attempt status such as `pending`, `running`, `succeeded`, `failed`, `cancelled`, or
    `lost`.
- `started_at`, `ended_at`, `terminal_reason`, `current_stage`
- `worker_host`, `workspace_path`
- `agent_session`
  - Compact session summary only: session id, last activity timestamp, and observable statistics
    such as token counts or turn counts. It MUST NOT contain full prompts or full transcripts.

Workspace lease fields:

- `lease_id`
- `issue_key`, `attempt_id`
  - The issue/attempt occupying the workspace.
- `workspace_path`
- `status`
  - `active`, `released`, or `lost`.
- `acquired_at`, `released_at`, `worker_host`

Retry/backoff fields:

- `attempt_id`
  - MUST reference an attempt in the same issue ledger scope.
- `due_at`
- `error_summary`
- `preferred_worker_host`, `preferred_workspace_path`

Writeback fields:

- `intent_key`
  - Stable logical writeback key within the same project/issue scope. It MUST remain stable across
    retry attempts for the same logical external side effect.
- `logical_action`, `operation_type`, `target`
- `replay_policy`
  - `idempotent` or `non_idempotent`.
- `result_status`
  - `pending`, `succeeded`, `failed`, or `unknown`.
- `attempt_id`
- `provider_marker`, `external_ref`, `error_summary`

Replay summary behavior:

- Implementations SHOULD replay a ledger snapshot into project-level summaries that include current
  claimed/running/retry/blocked/released counts.
- Replay summaries SHOULD list active issues with issue ref, stage, attempt id/number, workspace,
  worker host, last error, and backoff due time.
- Replay summaries SHOULD expose conflicts/orphans and manual-attention items, for example active
  workspace leases that do not reference active attempts or non-idempotent writebacks whose result
  is `unknown`.

Safety invariants:

- One `project_id + IssueRef` MUST have at most one active attempt.
- One workspace path MUST NOT have more than one active lease.
- `released` or `terminal` issue ledger facts MUST NOT retain active workspace leases.
- Retry/backoff facts MUST reference recognizable project/issue/attempt facts.
- Writeback intent keys MUST not change merely because a retry attempt changed.
- Ledger snapshots MUST NOT contain token values, API keys, credentials, full prompts, full Codex
  transcripts, or raw secret-bearing provider configuration.

#### 4.1.12 Hub Provider Request Governance (OPTIONAL)

Hub-compatible implementations SHOULD define a provider request governance model as the future
single Hub-owned exit for external tracker/provider access. This model is a contract for later Hub
poll coordination, writeback execution, Dashboard/API backpressure reporting, and provider quota
observation. It does not by itself require existing tracker adapters or single-project orchestrator
paths to stop calling providers directly.

Provider request fields:

- `request_id` or stable logical key
  - Stable request identity suitable for logs, queue summaries, and replay diagnostics.
- `provider_kind`
  - Provider kind such as `github`, `gitlab`, `linear`, or `memory`.
- `provider_scope` and `provider_scope_key`
  - Safe scope summary from the same boundary as Hub project snapshots and `IssueRef`.
  - MUST NOT be replaced by a bare provider-local issue or repository number.
- `project_id`
  - Stable Hub project identity.
- `config_fingerprint` or `snapshot_version`
  - Identifies the safe project configuration snapshot used when the request was built.
- `issue_ref` or `issue_key`
  - OPTIONAL. When present, MUST use the Hub `IssueRef` boundary or a key derived from
    `project_id + IssueRef`.
- `operation_kind`
  - Examples include `candidate_scan`, `running_reconciliation`, `stage_writeback`,
    `comment_workpad_upsert`, `pr_lookup`, `pr_create`, `dynamic_tool_provider_call`, and
    `manual_refresh`.
- `priority`
  - Lower numeric values indicate higher scheduling priority unless documented otherwise.
  - Running reconciliation SHOULD have higher default priority than ordinary candidate scans.
- `fairness_key`
  - A key, typically `project_id`, used to avoid one project monopolizing a shared provider scope.
- `replay_policy`
  - Should distinguish idempotent requests, marker/upsert requests, non-replayable requests, and
    requests whose unknown result requires manual attention.
- `timeout`, `deadline`, or cancellation boundary
  - Defines when the provider request should stop waiting. Observable snapshots SHOULD expose only
    the existence of a cancellation boundary, not secret token values.
- `correlation`
  - Sanitized metadata for logs, ledgers, and Dashboard/API summaries.

Queue and scheduling behavior:

- Implementations SHOULD provide a testable queue, scheduler model, or in-memory executor API.
- Higher-priority requests SHOULD be selected before lower-priority requests.
- Requests within the same provider scope SHOULD execute sequentially or under an explicit
  controlled-concurrency limit.
- Equal-priority requests sharing a provider scope SHOULD apply basic fairness across projects or
  fairness keys.
- Manual/user-triggered refresh requests SHOULD be observable in queue summaries.
- Queue summaries SHOULD include pending count, running count, wait/running duration, current
  running requests, recent safe results, provider-scope state, and backpressure reasons.

Provider-scope availability state:

- Scope state SHOULD be keyed by `provider_scope_key`.
- Scope state SHOULD record a sanitized quota/rate-limit summary, optional `backoff_until`, circuit
  state such as `closed`, `half_open`, or `open`, and the latest error class.
- Error classes SHOULD cover at least auth/config, rate-limited, network timeout, provider 5xx,
  validation, not found, conflict, and unknown.
- Blocking conditions such as active rate limit, active backoff, open circuit, or scope concurrency
  saturation SHOULD delay new matching-scope requests and expose a backpressure reason. Errors that
  affect only one request SHOULD NOT block unrelated scopes.

Provider result classifications:

- `success`
  - Contains provider-safe result summary and external reference when available.
- `retryable_failure`
  - Contains error class and optional retry/backoff suggestion.
- `permanent_failure`
  - Contains diagnostic error class.
- `rate_limited` or `circuit_open`
  - Explains provider-scope availability blocking.
- `canceled` or `timed_out`
- `unknown_result`
  - Used when the implementation cannot determine whether a provider side effect happened.

For writeback-like requests, result summaries SHOULD be able to link to the runtime ledger issue key
or writeback intent key. Unknown results for non-replayable writebacks MUST require manual attention
and MUST NOT be marked automatically replayable.

Privacy boundary:

- Request snapshots, queue summaries, provider-scope summaries, and result summaries MUST NOT
  contain provider tokens, API keys, credentials, cookies, raw secret-bearing config, full prompts,
  full Codex transcripts, or cancellation token values.

#### 4.1.12.1 Hub Provider Tool / Writeback Routing (OPTIONAL)

Hub-compatible implementations MAY add an opt-in provider tool routing boundary for dynamic tools
and writeback helpers. This boundary connects worker-initiated provider operations to
`ProviderGovernance` without requiring the legacy single-project runtime to stop calling provider
clients directly by default.

A routed provider tool call SHOULD:

- Build a `ProviderGovernance` request before provider execution.
- Carry `project_id`, provider scope, provider scope key, optional `IssueRef`, operation kind,
  priority, replay policy, and sanitized correlation.
- Accept an injectable executor or adapter so tests can replace real provider I/O.
- Classify execution outcomes as `success`, `retryable_failure`, `permanent_failure`,
  `rate_limited`, `circuit_open`, `timed_out`, `canceled`, or `unknown_result`.
- Return a payload compatible with the existing dynamic tool response protocol.
- Expose a sanitized summary that explains project, provider scope, operation type, retryability,
  manual-attention state, and ledger/writeback linkage.

Structured tools that create this routing boundary SHOULD at least cover:

- GitHub issue operations: get issue, list comments, workpad marker upsert, status set, and label
  add.
- GitHub pull request operations: list by branch head, get PR, create PR, list issue comments, list
  reviews, list review comments, and get check status.
- Provider-neutral tracker issue operations: create comment and set status.

Operation mapping SHOULD distinguish:

- Workpad upsert as marker/upsert replay semantics using a stable header or marker key.
- Status set as idempotent replay semantics keyed by target state.
- PR lookup and comment/review/check reads as idempotent lookup semantics.
- PR create as non-blind replay semantics keyed by branch/head marker; if the create result is
  unknown, the implementation MUST NOT create another PR without first checking for an existing PR
  or requiring manual attention.
- Ordinary append comments as non-blind replay semantics; unknown results MUST require manual
  attention because the provider may already have accepted the side effect.

Correlation snapshots MUST be safe. They MAY include run-context identifiers such as attempt id,
attempt number, session id, current stage, workspace lease id, tool name, and operation. They MUST
NOT include provider tokens, API keys, authorization headers, cookies, secret env values, full
prompts, full transcripts, or raw secret-bearing config. Large provider payloads such as comment or
PR bodies SHOULD be summarized with size and digest rather than copied into governance snapshots.

Raw provider escape hatches such as `linear_graphql` MAY remain outside this boundary until the
implementation defines a structured GraphQL operation model and scope validator. Implementations
that leave such a tool direct MUST document that decision and keep its legacy response behavior
unchanged.

#### 4.1.13 Hub Poll Coordination (OPTIONAL)

Hub-compatible implementations MAY define a provider-neutral poll coordination model that plans Hub
polls across several project snapshots before any provider I/O is performed. This model is the
bridge between `HUB.yaml` project identity, runtime ledger recovery facts, and provider request
governance. It does not by itself require the legacy single-project poll loop to be replaced.

Poll plan entries SHOULD include:

- `project_id`, optional display name, project status, config fingerprint or snapshot version.
- Provider scope kind, safe provider scope summary, and `provider_scope_key`.
- Workflow/tracker identity such as workflow start stage, terminal stages, tracker kind, and
  required labels.
- Effective poll interval, `next_due_at`, optional `backoff_until`, last poll result summary, and a
  boolean `allow_poll`.
- Eligibility reason such as `ready`, `not_due`, `paused`, `config_error`, `backoff`,
  `rate_limited`, `circuit_open`, `scope_concurrency`, or `provider_unavailable`.
- Governance request metadata proving that poll requests are represented as provider governance
  requests, commonly with `operation_kind: candidate_scan`, idempotent replay policy, and
  `project_id` fairness key.

Scheduling behavior:

- A single project's config error, provider backoff, circuit state, quota state, or poll failure MUST
  NOT make unrelated project snapshots ineligible.
- When several projects are due at the same time, selection SHOULD be deterministic and SHOULD use a
  fairness key, typically `project_id`, so one project cannot monopolize a shared provider scope.
- Scope-level backpressure from provider governance MUST apply only to matching provider scopes.
- The poll coordinator SHOULD expose the planned poll order separately from blocked or not-yet-due
  entries.

Recoverable facts:

- Poll coordination SHOULD emit or accept recoverable facts for poll plan generation, poll attempts,
  poll results, and backoff/circuit changes.
- Result facts SHOULD carry provider governance result classifications such as `success`,
  `retryable_failure`, `permanent_failure`, `rate_limited`, `circuit_open`, `timed_out`, or
  `unknown_result`.
- Restart planning SHOULD replay persisted poll result/backoff facts before deciding eligibility,
  so restart does not unconditionally poll every registered project at once.

Observability:

- API, snapshot, or dashboard output SHOULD expose a sanitized Hub poll coordination summary:
  allowed projects, blocked/not-due/error projects, next due time, backoff/circuit state, recent
  result summary, and provider queue/backpressure summary.
- Poll coordination snapshots MUST NOT contain provider tokens, API keys, credentials, cookies, raw
  secret-bearing config, full prompts, full Codex transcripts, or cancellation token values.

### 4.2 Stable Identifiers and Normalization Rules

- `Project ID`
  - Use as the Hub project identity and future per-project ledger partition key.
  - MUST be non-empty and contain only safe key characters such as ASCII letters, digits, `.`, `_`,
    and `-`.
  - MUST NOT contain whitespace padding, path separators, path traversal (`..`), newlines, or NUL.
  - MUST be unique within one Hub registry.
- `Issue ID`
  - Use for tracker lookups and internal map keys.
- `Issue Identifier`
  - Use for human-readable logs and workspace naming.
- `IssueRef`
  - Use for Hub ledgers and provider queues.
  - Compose from `project_id`, provider scope, and provider issue identity/local key.
- `Runtime Ledger Issue Key`
  - Derive from `project_id`, `IssueRef.provider_scope_key`, and the provider issue identity/local
    key.
  - MUST remain stable across process restarts and retry attempts.
- `Provider Request Key`
  - Derive from `project_id`, `provider_scope_key`, optional runtime ledger issue key, and the
    request logical key.
  - MUST NOT use a bare provider-local issue number as a globally unique provider request key.
- `Workspace Key`
  - Derive from `issue.identifier` by replacing any character not in `[A-Za-z0-9._-]` with `_`.
  - Use the sanitized value for the workspace directory name.
- `Normalized Issue State`
  - Compare states after `lowercase`.
- `Session ID`
  - Compose from coding-agent `thread_id` and `turn_id` as `<thread_id>-<turn_id>`.

## 5. Workflow Specification (Repository Contract)

### 5.1 File Discovery and Path Resolution

Workflow file path precedence:

1. Explicit application/runtime setting (set by CLI startup path).
2. Default: `WORKFLOW.md` in the current process working directory.

Loader behavior:

- If the file cannot be read, return `missing_workflow_file` error.
- The workflow file is expected to be repository-owned and version-controlled.

### 5.2 File Format

`WORKFLOW.md` is a Markdown file with YAML front matter for provider-neutral workflow stages.
`TRACKER.yaml` is a separate YAML file for provider-specific tracker access, stage-state mapping,
workspace/runtime settings, hooks, and agent/Codex runtime knobs.

Design note:

- New configurations SHOULD keep provider access and provider-visible state names out of
  `WORKFLOW.md`. Use `WORKFLOW.md` + `TRACKER.yaml` for workflow-stage configurations.
- Legacy single-file `WORKFLOW.md` tracker front matter is rejected at runtime. Use the migration
  task to split old configs into `WORKFLOW.md` plus `TRACKER.yaml` before starting the service.

Parsing rules:

- If file starts with `---`, parse lines until the next `---` as YAML front matter.
- Remaining lines become the prompt body.
- If front matter is absent, treat the entire file as prompt body and use an empty config map.
- YAML front matter MUST decode to a map/object; non-map YAML is an error.
- Prompt body is trimmed before use.
- In workflow-stage mode, the stage turn prompt is rendered from a system-maintained template.
  `WORKFLOW.md` supplies provider-neutral variables: current stage metadata, stage prompt text,
  workflow outcomes, stage transitions, missing-outcome policy, and issue context.

Returned workflow object:

- `config`: front matter root object (not nested under a `config` key).
- `workflow`: parsed provider-neutral workflow definition when workflow-stage front matter is
  present.
- `prompt_template`: trimmed Markdown body.

### 5.3 `WORKFLOW.md` Front Matter Schema

Top-level keys:

- `workflow`
- legacy runtime keys such as `polling`, `workspace`, `hooks`, `agent`, and `codex` MAY be accepted
  by an implementation for compatibility, but new workflow-stage examples should keep them in
  `TRACKER.yaml`.

Unknown keys SHOULD be ignored for forward compatibility.

#### 5.3.1 `workflow` (object)

Fields:

- `start_stage` (string)
  - REQUIRED.
  - MUST name a key in `workflow.stages`.
- `terminal_stages` (non-empty list of strings)
  - REQUIRED.
  - Every entry MUST name a key in `workflow.stages`.
- `outcomes` (non-empty list of strings)
  - REQUIRED.
  - Stage transition keys MUST be present in this list.
- `missing_outcome` (object)
  - `max_retries` (non-negative integer), REQUIRED.
  - `on_exhausted` (string), REQUIRED and MUST name a key in `workflow.stages`.
- `stages` (object)
  - REQUIRED non-empty map keyed by stage name.
  - Each stage has:
    - `prompt` (string): stage work content for the agent. It MUST NOT include dynamic tool names,
      structured completion implementation fields, required-tool settings, or the completion
      protocol; the runtime owns those details.
    - `transitions` (object): map of outcome name to target stage. Every target MUST name a key in
      `workflow.stages`.

Example:

```yaml
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
        Work on issue {{ issue.identifier }}.
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
```

### 5.4 `TRACKER.yaml` Schema

Top-level keys:

- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`
- `codex`

Unknown keys SHOULD be ignored for forward compatibility.

Note:

- The tracker config is extensible. Extensions MAY define additional top-level keys without
  changing the core schema above.
- Extensions SHOULD document their field schema, defaults, validation rules, and whether changes
  apply dynamically or require restart.

#### 5.4.1 `tracker` (object)

Fields:

- `kind` (string)
  - REQUIRED for dispatch.
  - Current supported values: `linear`, `github`, `gitlab`, `memory`
- `endpoint` (string)
  - Default for `tracker.kind == "linear"`: `https://api.linear.app/graphql`
  - Default for `tracker.kind == "gitlab"`: `https://gitlab.com/api/v4`
- `api_key` (string)
  - MAY be a literal token or `$VAR_NAME`.
  - Canonical environment variable for `tracker.kind == "linear"`: `LINEAR_API_KEY`.
  - Canonical environment variable for `tracker.kind == "github"`: `GITHUB_TOKEN`.
  - Canonical environment variable for `tracker.kind == "gitlab"`: `GITLAB_TOKEN`.
  - If `$VAR_NAME` resolves to an empty string, treat the key as missing.
- `project_slug` (string)
  - REQUIRED for dispatch when `tracker.kind == "linear"`.
  - REQUIRED for dispatch when `tracker.kind == "gitlab"`.
- `owner` (string)
  - REQUIRED for dispatch when `tracker.kind == "github"`.
- `repo` (string)
  - REQUIRED for dispatch when `tracker.kind == "github"`.
- `project_number` (integer)
  - OPTIONAL for `tracker.kind == "github"`.
  - When present, GitHub Project v2 status is used as the normalized scheduling state.
  - When omitted, GitHub native issue state is mapped to the configured active and terminal states.
- `required_labels` (list of strings)
  - Default: `[]`.
  - An issue MUST contain every configured label to dispatch or continue.
  - Matching ignores case and surrounding whitespace.
  - A blank configured label matches no issue.
- `state_label_prefix` (string)
  - OPTIONAL.
  - For `tracker.kind == "gitlab"`, when set, Symphony derives fine-grained workflow state from
    GitLab labels named `<prefix><normalized-state>`, for example `status::human-review`.
  - State label matching ignores case and surrounding whitespace.
- `workflow_state` (object)
  - OPTIONAL alternative strategy config for deriving `tracker.stage_states`.
  - `strategy: project_v2_status` for GitHub Project v2 Status. `field_name` defaults the Project
    single-select field name and `state_options` maps workflow stage ids to Project option names.
  - `strategy: scoped_label` for GitLab scoped labels. `label_prefix` defines the scoped-label group,
    `state_name_format` defaults to `kebab_case`, and `close_on_terminal` lists terminal stage ids
    that should close the GitLab issue.
  - All runtime stage-state consumers, including candidate discovery, stage prompt recovery, and
    runner issue context rendering, MUST use the derived mapping as if it were explicit
    `tracker.stage_states`.
- `provider_states` (list of strings)
  - OPTIONAL.
  - Declares provider-visible state/status/label names that are valid mapping targets.
  - When present, `tracker.stage_states.*.state` MUST map to one of these values.
- `stage_states` (object)
  - REQUIRED in workflow-stage mode unless `tracker.workflow_state` can derive a mapping for every
    workflow stage.
  - Keys are workflow stage names.
  - Each value has:
    - `state` (string): provider-visible state/status/label name.
    - `terminal` (boolean, OPTIONAL): marks the mapped provider state as terminal for provider
      recovery and reconciliation. Terminal workflow stages are also terminal even if this
      flag is omitted.
- `active_states` and `terminal_states` MUST NOT be used in runtime configuration. When present in
  old `WORKFLOW.md` front matter, startup fails with a migration diagnostic.

#### 5.4.2 `polling` (object)

Fields:

- `interval_ms` (integer)
  - Default: `30000`
  - Changes SHOULD be re-applied at runtime and affect future tick scheduling without restart.

#### 5.4.3 `workspace` (object)

Fields:

- `root` (path string or `$VAR`)
  - Default: `<system-temp>/symphony_workspaces`
  - `~` is expanded.
  - Relative paths are resolved relative to the directory containing `WORKFLOW.md`.
  - The effective workspace root is normalized to an absolute path before use.

#### 5.4.4 `hooks` (object)

Fields:

- `after_create` (multiline shell script string, OPTIONAL)
  - Runs only when a workspace directory is newly created.
  - Failure aborts workspace creation.
- `before_run` (multiline shell script string, OPTIONAL)
  - Runs before each agent attempt after workspace preparation and before launching the coding
    agent.
  - Failure aborts the current attempt.
- `after_run` (multiline shell script string, OPTIONAL)
  - Runs after each agent attempt (success, failure, timeout, or cancellation) once the workspace
    exists.
  - Failure is logged but ignored.
- `before_remove` (multiline shell script string, OPTIONAL)
  - Runs before workspace deletion if the directory exists.
  - Failure is logged but ignored; cleanup still proceeds.
- `timeout_ms` (integer, OPTIONAL)
  - Default: `60000`
  - Applies to all workspace hooks.
  - Invalid values fail configuration validation.
  - Changes SHOULD be re-applied at runtime for future hook executions.

#### 5.4.5 `agent` (object)

Fields:

- `max_concurrent_agents` (integer)
  - Default: `10`
  - Changes SHOULD be re-applied at runtime and affect subsequent dispatch decisions.
- `max_turns` (positive integer)
  - Default: `20`
  - Limits the number of coding-agent turns within one worker session.
  - Invalid values fail configuration validation.
- `max_retry_backoff_ms` (integer)
  - Default: `300000` (5 minutes)
  - Changes SHOULD be re-applied at runtime and affect future retry scheduling.
- `max_concurrent_agents_by_state` (map `state_name -> positive integer`)
  - Default: empty map.
  - State keys are normalized (`lowercase`) for lookup.
  - Invalid entries (non-positive or non-numeric) are ignored.
#### 5.4.6 `codex` (object)

Fields:

For Codex-owned config values such as `approval_policy`, `thread_sandbox`, and
`turn_sandbox_policy`, supported values are defined by the targeted Codex app-server version.
Implementors SHOULD treat them as pass-through Codex config values rather than relying on a
hand-maintained enum in this spec. To inspect the installed Codex schema, run
`codex app-server generate-json-schema --out <dir>` and inspect the relevant definitions referenced
by `v2/ThreadStartParams.json` and `v2/TurnStartParams.json`. Implementations MAY validate these
fields locally if they want stricter startup checks.

- `command` (string shell command)
  - Default: `codex app-server`
  - The runtime launches this command via `bash -lc` in the workspace directory.
  - The launched process MUST speak a compatible app-server protocol over stdio.
- `approval_policy` (Codex `AskForApproval` value)
  - Default: implementation-defined.
- `thread_sandbox` (Codex `SandboxMode` value)
  - Default: implementation-defined.
- `turn_sandbox_policy` (Codex `SandboxPolicy` value)
  - Default: implementation-defined.
- `turn_timeout_ms` (integer)
  - Default: `3600000` (1 hour)
- `read_timeout_ms` (integer)
  - Default: `5000`
- `stall_timeout_ms` (integer)
  - Default: `300000` (5 minutes)
  - If `<= 0`, stall detection is disabled.

### 5.5 Prompt Template Contract

In workflow-stage mode, the Markdown body of `WORKFLOW.md` is not the full turn prompt. The runtime
uses the current stage prompt plus workflow variables to render a system-owned stage turn template
that includes stage, issue, outcomes, transitions, the unified completion protocol, and
missing-outcome handling.

Rendering requirements:

- Use a strict template engine (Liquid-compatible semantics are sufficient).
- Unknown variables MUST fail rendering.
- Unknown filters MUST fail rendering.

Template input variables:

- `issue` (object)
  - Includes all normalized issue fields, including labels and blockers.
- `attempt` (integer or null)
  - `null`/absent on first attempt.
  - Integer on retry or continuation run.

Prompt behavior:

- Runtime worker turns require a workflow-stage definition and use the system-maintained stage prompt
  wrapper.
- Workflow file read/parse failures or missing workflow-stage definitions are configuration errors
  and SHOULD NOT silently fall back to a prompt.

### 5.6 Workflow Validation and Error Surface

Error classes:

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `invalid_workflow_definition`
- `missing_tracker_config_file`
- `tracker_config_parse_error`
- `tracker_config_not_a_map`
- `invalid_tracker_config`
- `legacy_workflow_tracker_config`
- `template_parse_error` (during prompt rendering)
- `template_render_error` (unknown variable/filter, invalid interpolation)

Dispatch gating behavior:

- Workflow file read/YAML errors block new dispatches until fixed.
- Template errors fail only the affected run attempt.

### 5.7 `HUB.yaml` Project Registry (OPTIONAL)

An implementation MAY define `HUB.yaml` as the Hub mode project registry. This registry declares
several independent projects on one device while preserving each project's own workflow, tracker
scope, workspace root, and dispatch capacity.

Minimal schema:

```yaml
projects:
  - project_id: symphony
    name: Symphony
    workflow_path: /path/to/project/WORKFLOW.md
    tracker_config_path: /path/to/project/TRACKER.yaml
    dispatch_enabled: true
  - project_id: docs
    workflow_path: ./docs/WORKFLOW.md
    paused: true
```

Fields:

- `projects` (list)
  - REQUIRED.
- `project_id` (string)
  - REQUIRED.
  - MUST follow the stable project ID rules in section 4.2.
- `name` (string)
  - OPTIONAL.
- `workflow_path` (path)
  - REQUIRED.
  - Relative paths are resolved relative to the `HUB.yaml` file.
- `tracker_config_path` (path)
  - OPTIONAL.
  - If omitted, defaults to `TRACKER.yaml` next to the selected `workflow_path`.
- `dispatch_enabled` (boolean)
  - OPTIONAL, default `true`.
- `enabled` (boolean)
  - OPTIONAL compatibility alias for `dispatch_enabled`.
- `paused` (boolean)
  - OPTIONAL. When `true`, the project snapshot is paused and new dispatch is disabled.

Loading behavior:

- The Hub loader MUST load each project as `WORKFLOW.md + TRACKER.yaml` using the same workflow and
  tracker/runtime parsing rules as the single-project mode.
- A single invalid project MUST produce a paused/error project snapshot and MUST NOT discard other
  valid snapshots.
- Duplicate or invalid `project_id` values MUST fail registry loading before project snapshots are
  treated as valid.
- Snapshots MUST include workflow summary, provider scope summary, workspace root, agent concurrency
  limits, polling interval, Dashboard/API port when configured, fingerprint, load time, and load
  error.
- Snapshot output MUST NOT expose token values, API keys, env secret names, credential fields, or
  raw secret-bearing config.
- The Hub loader SHOULD detect shared workspace roots and shared provider scopes as warnings.
- Shared Dashboard/API ports SHOULD be treated as an error because two live services cannot safely
  bind the same local port.

Compatibility boundary:

- `HUB.yaml` defines a model and validation entrypoint. It does not require the existing
  single-project orchestrator to become a Hub scheduler.
- Hub runtime ledgers define recoverable claim/attempt/workspace/retry/session/writeback facts for
  future Hub coordination. They also define start-intent and safe run-context facts for the atomic
  dispatch boundary. They do not by themselves implement a provider poll loop,
  database/transaction backend, cross-process distributed lock, full Hub scheduler, or provider
  writeback execution.
- Hub provider request governance defines the model and in-memory scheduling contract for a shared
  provider exit, and Hub poll coordination may build candidate-scan poll plans and safe observable
  snapshots from that contract. These model APIs do not perform provider I/O or require existing
  legacy tracker/provider calls, dynamic tools, or writeback paths to be migrated until an explicit
  Hub integration enables that path.
- Hub provider tool/writeback routing MAY provide an opt-in dynamic-tool execution boundary that
  builds `ProviderGovernance` requests for structured provider calls and returns safe result
  summaries. It MUST remain opt-in unless the implementation explicitly documents a Hub-owned
  provider exit migration; legacy direct provider calls stay compatible by default.
- Hub atomic dispatch defines the candidate-to-run-intent model boundary. It MUST key active
  attempts by `project_id + IssueRef`, bind claim, attempt, workspace lease, start intent, and run
  context in one model transition, and expose replay diagnostics for duplicate candidates, workspace
  conflicts, pending/unknown start acknowledgements, retry/backoff, blocked candidates, and manual
  attention. This boundary MAY be model-only until a later persistent transaction store or scheduler
  integration is introduced.
- Without explicit Hub mode usage, legacy single-project startup using one `WORKFLOW.md` and one
  `TRACKER.yaml` MUST remain compatible.

## 6. Configuration Specification

### 6.1 Configuration Resolution Pipeline

Configuration is resolved in this order:

1. Select the workflow file path (explicit runtime setting, otherwise cwd default).
2. Parse `WORKFLOW.md` YAML front matter into a raw provider-neutral workflow map.
3. In workflow-stage mode, select `TRACKER.yaml` from explicit runtime setting or the selected
   `WORKFLOW.md` directory and parse provider/runtime configuration from it.
4. Reject legacy provider tracker fields in workflow-stage `WORKFLOW.md` with a migration diagnostic
   that points to `WORKFLOW.md + TRACKER.yaml`.
5. Apply built-in defaults for missing OPTIONAL fields.
6. Resolve `$VAR_NAME` indirection only for config values that explicitly contain `$VAR_NAME`.
7. Coerce and validate typed values.

Environment variables do not globally override YAML values. They are used only when a config value
explicitly references them.

Value coercion semantics:

- Path/command fields support:
  - `~` home expansion
  - `$VAR` expansion for env-backed path values
  - Apply expansion only to values intended to be local filesystem paths; do not rewrite URIs or
    arbitrary shell command strings.
- Relative `workspace.root` values resolve relative to the directory containing the selected
  `WORKFLOW.md`.

### 6.2 Dynamic Reload Semantics

Dynamic reload is REQUIRED:

- The software MUST detect `WORKFLOW.md` changes.
- In workflow-stage mode, the software MUST also detect the selected `TRACKER.yaml` changes.
- On change, it MUST re-read and re-apply workflow config, tracker config, and prompt template
  without restart.
- The software MUST attempt to adjust live behavior to the new config (for example polling
  cadence, concurrency limits, active/terminal states, codex settings, workspace paths/hooks, and
  prompt content for future runs).
- Reloaded config applies to future dispatch, retry scheduling, reconciliation decisions, hook
  execution, and agent launches.
- Implementations are not REQUIRED to restart in-flight agent sessions automatically when config
  changes.
- Extensions that manage their own listeners/resources (for example an HTTP server port change) MAY
  require restart unless the implementation explicitly supports live rebind.
- Implementations SHOULD also re-validate/reload defensively during runtime operations (for example
  before dispatch) in case filesystem watch events are missed.
- Invalid reloads MUST NOT crash the service; keep operating with the last known good effective
  configuration and emit an operator-visible error.

### 6.3 Dispatch Preflight Validation

This validation is a scheduler preflight run before attempting to dispatch new work. It validates
the workflow/config needed to poll and launch workers, not a full audit of all possible workflow
behavior.

Startup validation:

- Validate configuration before starting the scheduling loop.
- If startup validation fails, fail startup and emit an operator-visible error.

Per-tick dispatch validation:

- Re-validate before each dispatch cycle.
- If validation fails, skip dispatch for that tick, keep reconciliation active, and emit an
  operator-visible error.

Validation checks:

- Workflow file can be loaded and parsed.
- Workflow-stage schema validates `start_stage`, `terminal_stages`, transitions, and
  `missing_outcome.on_exhausted`.
- Tracker config can be loaded and maps every workflow stage to a provider-visible state in
  `tracker.stage_states`.
- `tracker.kind` is present and supported.
- `tracker.api_key` is present after `$` resolution.
- `tracker.project_slug` is present when REQUIRED by the selected tracker kind.
- `codex.command` is present and non-empty.

### 6.4 Core Config Fields Summary (Cheat Sheet)

This section is intentionally redundant so a coding agent can implement the config layer quickly.
Extension fields are documented in the extension section that defines them. Core conformance does
not require recognizing or validating extension fields unless that extension is implemented.

- `workflow.start_stage`: string in `WORKFLOW.md`, REQUIRED and present in `workflow.stages`
- `workflow.terminal_stages`: non-empty list in `WORKFLOW.md`; all entries present in
  `workflow.stages`
- `workflow.outcomes`: non-empty list in `WORKFLOW.md`; every transition key is listed here
- `workflow.missing_outcome.max_retries`: non-negative integer in `WORKFLOW.md`
- `workflow.missing_outcome.on_exhausted`: string in `WORKFLOW.md`, present in `workflow.stages`
- `workflow.stages.<stage>.prompt`: string in `WORKFLOW.md`
- `workflow.stages.<stage>.transitions`: map of outcome to target stage in `WORKFLOW.md`
- `tracker.kind`: string in `TRACKER.yaml`, REQUIRED, currently `linear`, `github`, `gitlab`, or `memory`
- `tracker.endpoint`: string in `TRACKER.yaml`, default `https://api.linear.app/graphql` when `tracker.kind=linear`
- `tracker.api_key`: string or `$VAR` in `TRACKER.yaml`, canonical env depends on tracker kind
- `tracker.project_slug`: string in `TRACKER.yaml`, REQUIRED when `tracker.kind=linear` or `tracker.kind=gitlab`
- `tracker.owner`: string in `TRACKER.yaml`, REQUIRED when `tracker.kind=github`
- `tracker.repo`: string in `TRACKER.yaml`, REQUIRED when `tracker.kind=github`
- `tracker.project_number`: integer in `TRACKER.yaml`, OPTIONAL when `tracker.kind=github`
- `tracker.required_labels`: list of strings in `TRACKER.yaml`, default `[]`
- `tracker.state_label_prefix`: string in `TRACKER.yaml`, OPTIONAL for GitLab scoped label workflow states
- `tracker.provider_states`: optional list of provider-visible states accepted by stage-state mapping
- `tracker.stage_states`: map in `TRACKER.yaml` from workflow stage to provider-visible state
- `polling.interval_ms`: integer in `TRACKER.yaml`, default `30000`
- `workspace.root`: path in `TRACKER.yaml` resolved to absolute, default `<system-temp>/symphony_workspaces`
- `hooks.after_create`: shell script or null in `TRACKER.yaml`
- `hooks.before_run`: shell script or null in `TRACKER.yaml`
- `hooks.after_run`: shell script or null in `TRACKER.yaml`
- `hooks.before_remove`: shell script or null in `TRACKER.yaml`
- `hooks.timeout_ms`: integer in `TRACKER.yaml`, default `60000`
- `agent.max_concurrent_agents`: integer in `TRACKER.yaml`, default `10`
- `agent.max_turns`: integer in `TRACKER.yaml`, default `20`
- `agent.max_retry_backoff_ms`: integer in `TRACKER.yaml`, default `300000` (5m)
- `agent.max_concurrent_agents_by_state`: map of positive integers in `TRACKER.yaml`, default `{}`
- `codex.command`: shell command string in `TRACKER.yaml`, default `codex app-server`
- `codex.approval_policy`: Codex `AskForApproval` value in `TRACKER.yaml`, default implementation-defined
- `codex.thread_sandbox`: Codex `SandboxMode` value in `TRACKER.yaml`, default implementation-defined
- `codex.turn_sandbox_policy`: Codex `SandboxPolicy` value, default implementation-defined
- `codex.turn_timeout_ms`: integer, default `3600000`
- `codex.read_timeout_ms`: integer, default `5000`
- `codex.stall_timeout_ms`: integer, default `300000`

## 7. Orchestration State Machine

The orchestrator is the only component that mutates scheduling state. All worker outcomes are
reported back to it and converted into explicit state transitions.

### 7.1 Issue Orchestration States

This is not the same as tracker states (`Todo`, `In Progress`, etc.). This is the service's internal
claim state.

1. `Unclaimed`
   - Issue is not running and has no retry scheduled.

2. `Claimed`
   - Orchestrator has reserved the issue to prevent duplicate dispatch.
   - In practice, claimed issues are either `Running` or `RetryQueued`.

3. `Running`
   - Worker task exists and the issue is tracked in `running` map.

4. `RetryQueued`
   - Worker is not running, but a retry timer exists in `retry_attempts`.

5. `Blocked`
   - Claim retained because the issue cannot be safely completed or retried automatically.
   - Entries SHOULD include issue id, stage, blocked reason, session id, workspace path, worker host,
     and recovery artifact path when available.

6. `Released`
   - Claim removed because issue is terminal, non-active, missing, or retry path completed without
     re-dispatch.

### 7.1.1 Hub Atomic Dispatch Boundary

The Hub atomic dispatch boundary is a model-level contract for converting a candidate issue into an
active agent run intent. It is part of the #74 Hub direction and is separate from the legacy
single-project orchestrator implementation.

Inputs:

- `project_id`
- configuration fingerprint or snapshot version
- provider-neutral `IssueRef`
- workflow and tracker state summary
- trigger source: poll plan, manual refresh, webhook, running reconciliation, or recovery
- provider governance or poll coordination request/correlation summary
- attempt number or stable attempt-id input
- workspace path/lease input
- preflight observations

Required preflight observations:

- existing active attempt for the same `project_id + IssueRef`
- existing active workspace lease for the requested workspace
- active retry/backoff
- project pause or configuration error
- provider governance backpressure
- explicit blocked/manual-attention state

Invariants:

- At most one active attempt MAY exist for one `project_id + IssueRef`.
- An active attempt in claimed/running state MUST have one matching active workspace lease.
- A workspace path MUST NOT have more than one active lease.
- A start intent MUST reference an active attempt and matching workspace lease while pending,
  unknown, or manual-attention.
- Repeated candidates from duplicate ticks, webhooks, or recovery scans MUST be idempotent and MUST
  NOT create a second active attempt.
- An unknown worker-start result MUST be represented as pending/unknown/manual attention or another
  safe retry state; implementations MUST NOT blindly start a second worker.

Failure outcomes:

- `retry_queued`: attempt failed before a durable worker run; retry/backoff records the due time and
  releases the workspace lease.
- `blocked`: dispatch cannot safely proceed automatically; replay exposes the blocked candidate and
  diagnostic.
- `released`: claim and workspace lease are released because no active run remains necessary.
- `manual_attention`: start outcome is unknown or unsafe to replay; the unresolved start intent and
  workspace lease remain observable until an operator or later recovery policy resolves them.

Run context snapshots:

- MUST include safe references to project/workflow/tracker configuration, issue identity, current
  stage, attempt id/number, correlation id, workspace lease/path, worker host/runtime identity
  summary, runner/start command summary, session id, start/activity timestamps, and exit summary.
- MUST NOT include provider tokens, API keys, credentials, cookies, secret env values, full prompts,
  complete Codex transcripts, or raw secret-bearing config.

Important nuance:

- A successful worker exit does not mean the issue is done forever.
- In workflow-stage mode, the worker MAY continue through multiple back-to-back stage turns before
  it exits. It keeps the same workspace, app-server subprocess, and coding-agent thread for those
  stage turns.
- After each successful non-terminal stage turn, the worker validates the structured stage outcome,
  computes the next stage from the current stage transitions, writes that next stage through the
  tracker adapter, and immediately starts the next stage turn if the next stage is not terminal.
- Workflow-stage progression MUST NOT use provider issue state refresh as the normal decision point
  between in-process stages. Provider-visible stage writes are external observability/recovery
  records.
- Once the worker exits normally at a completion terminal stage, the orchestrator MUST NOT schedule a
  continuation retry; the runner has already completed the in-process stage loop.
- A worker exit at a non-completion terminal stage, including `blocked`, `protocol_blocked`,
  `rework`, or equivalent diagnostic stages, MUST NOT be interpreted as delivered work. The issue
  MUST remain open or provider-visible as blocked/rework/protocol-blocked, MUST NOT be counted as
  completed, and MUST NOT lose its only recoverable workspace evidence.

### 7.2 Run Attempt Lifecycle

A run attempt transitions through these phases:

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `Finishing`
7. `Succeeded`
8. `Failed`
9. `TimedOut`
10. `Stalled`
11. `CanceledByReconciliation`

Distinct terminal reasons are important because retry logic and logs differ.

### 7.3 Transition Triggers

- `Poll Tick`
  - Reconcile active runs.
  - Validate config.
  - Fetch candidate issues.
  - Dispatch until slots are exhausted.

- `Worker Exit (normal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Mark the issue completed locally and release the claim without scheduling continuation retry.

- `Worker Exit (abnormal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule exponential-backoff retry.

- `Codex Update Event`
  - Update live session fields, token counters, and rate limits.

- `Retry Timer Fired`
  - Refresh the specific issue and attempt re-dispatch if still eligible, or release claim if no
    longer eligible.

- `Reconciliation State Refresh`
  - Stop runs whose issue states are terminal or no longer active.

- `Stall Timeout`
  - Kill worker and schedule retry.

### 7.4 Idempotency and Recovery Rules

- The orchestrator serializes state mutations through one authority to avoid duplicate dispatch.
- `claimed` and `running` checks are REQUIRED before launching any worker.
- Reconciliation runs before dispatch on every tick.
- Restart recovery is tracker-driven and filesystem-driven (without a durable orchestrator DB).
- Startup terminal cleanup removes stale workspaces for issues already in terminal states in legacy
  prompt mode. Workflow-stage mode does not perform provider-wide terminal scans at startup.

## 8. Polling, Scheduling, and Reconciliation

### 8.1 Poll Loop

At startup, the service validates config, performs startup cleanup, schedules an immediate tick, and
then repeats every `polling.interval_ms`.

The effective poll interval SHOULD be updated when workflow config changes are re-applied.

Tick sequence:

1. Reconcile running issues.
2. Run dispatch preflight validation.
3. Fetch candidate issues from tracker using `workflow.start_stage`.
4. Sort issues by dispatch priority.
5. Dispatch eligible issues while slots remain.
6. Notify observability/status consumers of state changes.

If per-tick validation fails, dispatch is skipped for that tick, but reconciliation still happens
first.

### 8.2 Candidate Selection Rules

An issue is dispatch-eligible only if all are true:

- It has `id`, `identifier`, `title`, and `state`.
- Its provider-visible stage maps to `workflow.start_stage`.
- It is routed to this worker by the configured assignee and contains every
  label in `tracker.required_labels`.
- It is not already in `running`.
- It is not already in `claimed`.
- Global concurrency slots are available.
- Per-state concurrency slots are available.
- Blocker rule passes:
  - Do not dispatch when any blocker cannot be confirmed terminal.
  - Blocker terminality is evaluated through provider-state to workflow-stage mapping.

Dispatch MUST revalidate a candidate immediately before spawning a worker. In workflow-stage mode,
that revalidation reads the issue's current workflow stage and skips the issue unless it is still
`workflow.start_stage`. Non-start stages such as implementation, validation, done, or blocked are
never new-work candidates.

Sorting order (stable intent):

1. `priority` ascending (1..4 are preferred; null/unknown sorts last)
2. `created_at` oldest first
3. `identifier` lexicographic tie-breaker

### 8.3 Concurrency Control

Global limit:

- `available_slots = max(max_concurrent_agents - running_count, 0)`

Per-state limit:

- `max_concurrent_agents_by_state[state]` if present (state key normalized)
- otherwise fallback to global limit

The runtime counts issues by their current tracked state in the `running` map.

### 8.4 Retry and Backoff

Retry entry creation:

- Cancel any existing retry timer for the same issue.
- Store `attempt`, `identifier`, `error`, `due_at_ms`, and new timer handle.

Backoff formula:

- Normal continuation retries after a clean worker exit use a short fixed delay of `1000` ms.
- Failure-driven retries use `delay = min(10000 * 2^(attempt - 1), agent.max_retry_backoff_ms)`.
- Power is capped by the configured max retry backoff (default `300000` / 5m).

Retry handling behavior:

1. Refresh the specific issue by `issue_id`.
3. If not found, release claim.
4. If found and still candidate-eligible:
   - Dispatch if slots are available.
   - Otherwise requeue with error `no available orchestrator slots`.
5. If found but no longer eligible, release claim.

Note:

- Terminal-state workspace cleanup is handled by startup cleanup and active-run reconciliation only
  for completion terminal stages. Non-completion terminal stages keep the claim blocked and preserve
  workspace recovery evidence.
- Retries can only re-dispatch issues that are back at `workflow.start_stage`; they MUST NOT advance
  middle stages through a provider-wide scan.

### 8.5 Active Run Reconciliation

Reconciliation runs every tick and has two parts.

Part A: Stall detection

- For each running issue, compute `elapsed_ms` since:
  - `last_codex_timestamp` if any event has been seen, else
  - `started_at`
- If `elapsed_ms > codex.stall_timeout_ms`, terminate the worker and queue a retry.
- If `stall_timeout_ms <= 0`, skip stall detection entirely.

Part B: Tracker state refresh

- Fetch current issue states for all running issue IDs.
- For each running issue:
  - If provider state maps to a completion terminal workflow stage: terminate worker and clean
    workspace.
  - If provider state maps to a blocked/protocol-blocked/rework terminal workflow stage: terminate
    worker, keep the claim in blocked state, and preserve recovery evidence.
  - If provider state disagrees with the runner's local current stage: keep the worker running,
    update the in-memory issue snapshot, log a stage conflict, and expose
    `stage_conflict` through observability.
- If state refresh fails, keep workers running and try again on the next tick.

### 8.6 Startup Terminal Workspace Cleanup

Startup no longer performs a provider-wide terminal-state cleanup scan. Terminal workspace cleanup is
handled by active-run reconciliation and normal completion terminal stage completion.
4. In workflow-stage mode, provider-wide terminal cleanup is not scanned at startup. Restart
   recovery is bounded by provider-visible stage plus workspace metadata; a fresh dispatch is only
   possible for issues visible in `workflow.start_stage`, while running in-memory stage position is
   not durable across process restarts.

This prevents stale terminal workspaces from accumulating after restarts.

## 9. Workspace Management and Safety

### 9.1 Workspace Layout

Workspace root:

- `workspace.root` (normalized absolute path)

Per-issue workspace path:

- `<workspace.root>/<sanitized_issue_identifier>`

Workspace persistence:

- Workspaces are reused across runs for the same issue.
- Completion terminal runs may delete workspaces according to the configured cleanup path.
- Blocked terminal runs MUST retain the workspace or write enough recovery artifact data before any
  cleanup. Local recovery artifacts SHOULD include `git status --short --branch`, `git diff --stat`,
  `git diff --name-status`, an untracked-file list, patch data, session id, and blocked reason.

### 9.2 Workspace Creation and Reuse

Input: `issue.identifier`

Algorithm summary:

1. Sanitize identifier to `workspace_key`.
2. Compute workspace path under workspace root.
3. Ensure the workspace path exists as a directory.
4. Mark `created_now=true` only if the directory was created during this call; otherwise
   `created_now=false`.
5. If `created_now=true`, run `after_create` hook if configured.

Notes:

- This section does not assume any specific repository/VCS workflow.
- Workspace preparation beyond directory creation (for example dependency bootstrap, checkout/sync,
  code generation) is implementation-defined and is typically handled via hooks.

### 9.3 OPTIONAL Workspace Population (Implementation-Defined)

The spec does not require any built-in VCS or repository bootstrap behavior.

Implementations MAY populate or synchronize the workspace using implementation-defined logic and/or
hooks (for example `after_create` and/or `before_run`).

Failure handling:

- Workspace population/synchronization failures return an error for the current attempt.
- If failure happens while creating a brand-new workspace, implementations MAY remove the partially
  prepared directory.
- Reused workspaces SHOULD NOT be destructively reset on population failure unless that policy is
  explicitly chosen and documented.

### 9.4 Workspace Hooks

Supported hooks:

- `hooks.after_create`
- `hooks.before_run`
- `hooks.after_run`
- `hooks.before_remove`

Execution contract:

- Execute in a local shell context appropriate to the host OS, with the workspace directory as
  `cwd`.
- On POSIX systems, `sh -lc <script>` (or a stricter equivalent such as `bash -lc <script>`) is a
  conforming default.
- Hook timeout uses `hooks.timeout_ms`; default: `60000 ms`.
- Log hook start, failures, and timeouts.

Failure semantics:

- `after_create` failure or timeout is fatal to workspace creation.
- `before_run` failure or timeout is fatal to the current run attempt.
- `after_run` failure or timeout is logged and ignored.
- `before_remove` failure or timeout is logged and ignored.

### 9.5 Safety Invariants

This is the most important portability constraint.

Invariant 1: Run the coding agent only in the per-issue workspace path.

- Before launching the coding-agent subprocess, validate:
  - `cwd == workspace_path`

Invariant 2: Workspace path MUST stay inside workspace root.

- Normalize both paths to absolute.
- Require `workspace_path` to have `workspace_root` as a prefix directory.
- Reject any path outside the workspace root.

Invariant 3: Workspace key is sanitized.

- Only `[A-Za-z0-9._-]` allowed in workspace directory names.
- Replace all other characters with `_`.

## 10. Agent Runner Protocol (Coding Agent Integration)

This section defines Symphony's language-neutral responsibilities when integrating a Codex
app-server. The Codex app-server protocol for the targeted Codex version is the source of truth for
protocol schemas, message payloads, transport framing, and method names.

Protocol source of truth:

- Implementations MUST send messages that are valid for the targeted Codex app-server version.
- Implementations MUST consult the targeted Codex app-server documentation or generated schema
  instead of treating this specification as a protocol schema.
- If this specification appears to conflict with the targeted Codex app-server protocol, the Codex
  protocol controls protocol shape and transport behavior.
- Symphony-specific requirements in this section still control orchestration behavior, workspace
  selection, prompt construction, continuation handling, and observability extraction.

### 10.1 Launch Contract

Subprocess launch parameters:

- Command: `codex.command`
- Invocation: `bash -lc <codex.command>`
- Working directory: workspace path
- Transport/framing: the protocol transport required by the targeted Codex app-server version

Notes:

- The default command is `codex app-server`.
- Approval policy, sandbox policy, cwd, prompt input, and OPTIONAL tool declarations are supplied
  using fields supported by the targeted Codex app-server version.

RECOMMENDED additional process settings:

- Max line size: 10 MB (for safe buffering)

### 10.2 Session Startup Responsibilities

Reference: https://developers.openai.com/codex/app-server/

Startup MUST follow the targeted Codex app-server contract. Symphony additionally requires the
client to:

- Start the app-server subprocess in the per-issue workspace.
- Initialize the app-server session using the targeted Codex app-server protocol.
- Create or resume a coding-agent thread according to the targeted protocol.
- Supply the absolute per-issue workspace path as the thread/turn working directory wherever the
  targeted protocol accepts cwd.
- Start every non-terminal stage turn with the system-maintained stage turn prompt rendered for the
  current workflow stage.
- Supply the implementation's documented approval and sandbox policy using fields supported by the
  targeted protocol.
- Include issue-identifying metadata, such as `<issue.identifier>: <issue.title>`, when the targeted
  protocol supports turn or session titles.
- Advertise implemented client-side tools using the targeted protocol.

Session identifiers:

- Extract `thread_id` from the thread identity returned by the targeted Codex app-server protocol.
- Extract `turn_id` from each turn identity returned by the targeted Codex app-server protocol.
- Emit `session_id = "<thread_id>-<turn_id>"`
- Reuse the same `thread_id` for all continuation turns inside one worker run

### 10.3 Streaming Turn Processing

The client processes app-server updates according to the targeted Codex app-server protocol until
the active turn terminates.

Completion conditions:

- Targeted-protocol turn completion signal -> success
- Targeted-protocol turn failure signal -> failure
- Targeted-protocol turn cancellation signal -> failure
- turn timeout (`turn_timeout_ms`) -> failure
- subprocess exit -> failure

Continuation processing:

- If the worker decides to continue after a successful turn, it SHOULD start another turn on the same
  live thread using the targeted protocol.
- In workflow-stage mode, that decision comes from the structured stage outcome and current stage
  transition graph. Turn completion without one valid non-terminal outcome is a protocol error that
  retries the same stage up to `workflow.missing_outcome.max_retries`; after exhaustion, the worker
  writes `workflow.missing_outcome.on_exhausted`.
- The app-server subprocess SHOULD remain alive across those continuation turns and be stopped only
  when the worker run is ending.

Transport handling requirements:

- Follow the transport and framing rules of the targeted Codex app-server version.
- For stdio-based transports, keep protocol stream handling separate from diagnostic stderr
  handling unless the targeted protocol specifies otherwise.

### 10.4 Emitted Runtime Events (Upstream to Orchestrator)

The app-server client emits structured events to the orchestrator callback. Each event SHOULD
include:

- `event` (enum/string)
- `timestamp` (UTC timestamp)
- `codex_app_server_pid` (if available)
- OPTIONAL `usage` map (token counts)
- payload fields as needed

Important emitted events include, for example:

- `session_started`
- `startup_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_ended_with_error`
- `turn_input_required`
- `approval_auto_approved`
- `unsupported_tool_call`
- `notification`
- `other_message`
- `malformed`

### 10.5 Approval, Tool Calls, and User Input Policy

Approval, sandbox, and user-input behavior is implementation-defined.

Policy requirements:

- Each implementation MUST document its chosen approval, sandbox, and operator-confirmation
  posture.
- Approval requests and user-input-required events MUST NOT leave a run stalled indefinitely. An
  implementation MAY either satisfy them, surface them to an operator, auto-resolve them, or
  fail the run according to its documented policy.

Example high-trust behavior:

- Auto-approve command execution approvals for the session.
- Auto-approve file-change approvals for the session.
- Treat user-input-required turns as hard failure.

Unsupported dynamic tool calls:

- Supported dynamic tool calls that are explicitly implemented and advertised by the runtime SHOULD
  be handled according to their extension contract.
- If the agent requests a dynamic tool call that is not supported, return a tool failure response
  using the targeted protocol and continue the session.
- This prevents the session from stalling on unsupported tool execution paths.

Optional client-side tool extension:

- An implementation MAY expose a limited set of client-side tools to the app-server session.
- Current standardized optional tool: `linear_graphql`.
- If implemented, supported tools SHOULD be advertised to the app-server session during startup
  using the protocol mechanism supported by the targeted Codex app-server version.
- Unsupported tool names SHOULD still return a failure result using the targeted protocol and
  continue the session.

`linear_graphql` extension contract:

- Purpose: execute a raw GraphQL query or mutation against Linear using Symphony's configured
  tracker auth for the current session.
- Availability: only meaningful when `tracker.kind == "linear"` and valid Linear auth is configured.
- Preferred input shape:

  ```json
  {
    "query": "single GraphQL query or mutation document",
    "variables": {
      "optional": "graphql variables object"
    }
  }
  ```

- `query` MUST be a non-empty string.
- `query` MUST contain exactly one GraphQL operation.
- `variables` is OPTIONAL and, when present, MUST be a JSON object.
- Implementations MAY additionally accept a raw GraphQL query string as shorthand input.
- Execute one GraphQL operation per tool call.
- If the provided document contains multiple operations, reject the tool call as invalid input.
- `operationName` selection is intentionally out of scope for this extension.
- Reuse the configured Linear endpoint and auth from the active Symphony workflow/runtime config; do
  not require the coding agent to read raw tokens from disk.
- Tool result semantics:
  - transport success + no top-level GraphQL `errors` -> `success=true`
  - top-level GraphQL `errors` present -> `success=false`, but preserve the GraphQL response body
    for debugging
  - invalid input, missing auth, or transport failure -> `success=false` with an error payload
- Return the GraphQL response or error payload as structured tool output that the model can inspect
  in-session.

User-input-required policy:

- Implementations MUST document how targeted-protocol user-input-required signals are handled.
- A run MUST NOT stall indefinitely waiting for user input.
- A conforming implementation MAY fail the run, surface the request to an operator, satisfy it
  through an approved operator channel, or auto-resolve it according to its documented policy.
- The example high-trust behavior above fails user-input-required turns immediately.

### 10.6 Timeouts and Error Mapping

Timeouts:

- `codex.read_timeout_ms`: request/response timeout during startup and sync requests
- `codex.turn_timeout_ms`: total turn stream timeout
- `codex.stall_timeout_ms`: enforced by orchestrator based on event inactivity

Error mapping (RECOMMENDED normalized categories):

- `codex_not_found`
- `invalid_workspace_cwd`
- `response_timeout`
- `turn_timeout`
- `port_exit`
- `response_error`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`

### 10.7 Agent Runner Contract

The `Agent Runner` wraps workspace + prompt + app-server client.

Behavior:

1. Create/reuse workspace for issue.
2. Build the legacy prompt or workflow-stage turn prompt.
3. Start app-server session.
4. Forward app-server events to orchestrator.
5. In workflow-stage mode, validate each completed turn's structured outcome, write the next stage,
   and keep advancing in the same workspace/session/thread until a terminal stage, failure, or
   runner turn limit is reached.
6. On any turn failure/cancellation/timeout or tracker stage-write error, fail the worker attempt
   (the orchestrator will retry).

Note:

- Workspaces are intentionally preserved after successful runs.

## 11. Issue Tracker Integration Contract

### 11.1 REQUIRED Operations

An implementation MUST support these tracker adapter operations:

1. `fetch_candidate_issues()`
   - Return issues in configured active states for a configured project.

2. `fetch_issues_by_states(state_names)`
   - Used for startup terminal cleanup.

3. `fetch_issue_states_by_ids(issue_ids)`
   - Used for active-run reconciliation.

### 11.2 Query Semantics

Linear-specific requirements for `tracker.kind == "linear"`:

- `tracker.kind == "linear"`
- GraphQL endpoint (default `https://api.linear.app/graphql`)
- Auth token sent in `Authorization` header
- `tracker.project_slug` maps to Linear project `slugId`
- Candidate issue query filters project using `project: { slugId: { eq: $projectSlug } }`
- Candidate and issue-state refresh queries include issue labels. Required
  label filtering happens after normalization so refresh can observe label
  removal and stop or release existing work.
- Issue-state refresh query uses GraphQL issue IDs with variable type `[ID!]`
- Pagination REQUIRED for candidate issues
- Page size default: `50`
- Network timeout: `30000 ms`

GitHub-specific requirements for `tracker.kind == "github"`:

- `tracker.owner` and `tracker.repo` define the repository scope.
- `tracker.project_number` is optional. When present, GitHub Project v2 Status is used as the
  provider-visible workflow stage state. `tracker.workflow_state.state_options` maps workflow stage
  ids to Status option names.
- GitHub Project v2 writes MUST fail clearly when the configured issue is not in the project, the
  configured Status field is missing, or the requested Status option is missing.
- GitHub native `CLOSED` is authoritative terminal state even if the Project Status field is stale.
- GitHub Project v2 Status writes to non-completion terminal stages such as `Blocked` or
  `Protocol Blocked` MUST NOT close the native GitHub issue. Native issue close is reserved for
  completion terminal stages or the linked PR merge path.
- When `tracker.project_number` is omitted, GitHub issues-only mode MUST NOT claim support for
  multi-stage provider-visible workflow state. Multi-stage workflow-stage config that needs
  provider-visible state MUST fail fast and point users to Project v2 Status or another tracker with
  multi-stage state support.
- Issue numbers are only repository-local; normalized IDs and identifiers must include repository
  scope.

GitLab-specific requirements for `tracker.kind == "gitlab"`:

- `tracker.project_slug` defines the project scope. It can be a path such as `group/project` or a
  numeric project ID.
- The default endpoint is `https://gitlab.com/api/v4`.
- GitLab native `opened` maps to the first configured active state and `closed` maps to the first
  configured terminal state.
- GitLab native state writes SHOULD close issues only for completion terminal stages; non-completion
  terminal workflow stages remain provider-visible without being treated as delivered work.
- GitLab scoped-label workflow state maps stage ids to labels such as
  `status::context-check`. Reads reject unmapped/conflicting provider states through the adapter
  stage contract; writes add the target scoped label and remove other labels in the configured
  workflow-state group. Unrelated labels are not removed.
- GitLab scoped-label writes close an issue only for terminal stages listed in
  `tracker.workflow_state.close_on_terminal`; other terminal stages may remain opened but
  provider-visible as terminal workflow stages.
- Issue `iid` values are only project-local; normalized IDs and identifiers must include project
  scope.

Important:

- Linear GraphQL schema details can drift. Keep query construction isolated and test the exact query
  fields/types REQUIRED by this specification.
- GitHub and GitLab API details can drift. Keep REST/GraphQL construction isolated and test the
  provider payload fields required for normalization.

Each tracker adapter MAY change transport details, but the normalized outputs MUST match the domain
model in Section 4.

### 11.3 Normalization Rules

Candidate issue normalization SHOULD produce fields listed in Section 4.1.1.

Additional normalization details:

- Label names are trimmed and lowercased.

- `labels` -> lowercase strings
- `blocked_by` -> derived from inverse relations where relation type is `blocks`
- `priority` -> integer only (non-integers become null)
- `created_at` and `updated_at` -> parse ISO-8601 timestamps

### 11.4 Error Handling Contract

RECOMMENDED error categories:

- `unsupported_tracker_kind`
- `missing_tracker_api_key`
- `missing_tracker_project_slug`
- `linear_api_request` (transport failures)
- `linear_api_status` (non-200 HTTP)
- `linear_graphql_errors`
- `linear_unknown_payload`
- `linear_missing_end_cursor` (pagination integrity error)
- `github_api_request`, `github_api_status`, `github_graphql_errors`, `github_unknown_payload`
- `gitlab_api_request`, `gitlab_api_status`, `gitlab_unknown_payload`

Orchestrator behavior on tracker errors:

- Candidate fetch failure: log and skip dispatch for this tick.
- Running-state refresh failure: log and keep active workers running.
- Startup terminal cleanup failure: log warning and continue startup.

### 11.5 Tracker Writes (Important Boundary)

Symphony does not require first-class tracker write APIs in the orchestrator.

- Ticket mutations (state transitions, comments, PR metadata) are typically handled by the coding
  agent using ordinary tracker/provider tools.
- Runner-internal stage outcome submission is a distinct structured channel that drives workflow
  transitions. Direct provider status updates MUST NOT be interpreted as the stage outcome.
- The service remains a scheduler/runner and tracker reader.
- Workflow-specific success often means "reached the next handoff state" (for example
  `Human Review`) rather than tracker terminal state `Done`.
- If the `linear_graphql` client-side tool extension is implemented, it is still part of the agent
  toolchain rather than orchestrator business logic.
- If Hub provider tool/writeback routing is implemented, it is an opt-in execution boundary for
  structured provider tools. It does not make tracker writes first-class orchestrator business
  logic, and it does not imply that the Hub scheduler owns all provider I/O.

## 12. Prompt Construction and Context Assembly

### 12.1 Inputs

Inputs to legacy prompt rendering:

- `workflow.prompt_template`
- normalized `issue` object
- OPTIONAL `attempt` integer (retry/continuation metadata)

Implementations MAY enrich the template `issue` object with derived, provider-aware fields that are
not persisted back to the tracker. Standard derived prompt fields:

- `issue.tracker_kind`: active tracker kind such as `linear`, `github`, or `gitlab`.
- `issue.closing_reference`: PR/MR description reference for the current issue.
  - GitHub/GitLab same-scope issues SHOULD use a provider closing keyword such as `Closes #123`.
  - GitHub/GitLab cross-scope issues SHOULD keep the qualified reference, for example
    `Closes owner/repo#123` or `Closes group/project#123`.
  - Linear issues SHOULD keep a readable non-closing reference such as `Linear: ABC-123`.
- `issue.closing_instruction`: human-readable guidance describing how to use the closing reference in
  the PR/MR description.

### 12.2 Rendering Rules

- Render with strict variable checking.
- Render with strict filter checking.
- Convert issue object keys to strings for template compatibility.
- Preserve nested arrays/maps (labels, blockers) so templates can iterate.

### 12.3 Retry/Continuation Semantics

`attempt` SHOULD be passed to the template because the workflow prompt can provide different
instructions for:

- first run (`attempt` null or absent)
- continuation run after a successful prior session
- retry after error/timeout/stall

### 12.4 Failure Semantics

If prompt rendering fails:

- Fail the run attempt immediately.
- Let the orchestrator treat it like any other worker failure and decide retry behavior.

### 12.5 Stage Turn Prompt and Outcome Channel

In workflow-stage mode, implementations MUST render each non-legacy turn with a system-maintained
stage prompt template. The rendered prompt MUST include:

- current stage id/name
- issue context
- rendered stage work prompt
- workflow outcomes
- current stage transitions
- unified stage completion protocol
- missing-outcome retry/fallback policy

The completion protocol MUST require exactly one structured stage outcome for non-terminal stages.
The outcome channel MAY be implemented as a dynamic tool, but `WORKFLOW.md` MUST NOT expose tool
names, structured completion types, or required-tool implementation fields. If a turn completes
without one valid structured outcome, the runner MUST represent that as a stage outcome protocol
error for later retry handling instead of parsing the final natural-language response.

## 13. Logging, Status, and Observability

### 13.1 Logging Conventions

REQUIRED context fields for issue-related logs:

- `issue_id`
- `issue_identifier`

REQUIRED context for coding-agent session lifecycle logs:

- `session_id`

Message formatting requirements:

- Use stable `key=value` phrasing.
- Include action outcome (`completed`, `failed`, `retrying`, etc.).
- Include concise failure reason when present.
- Avoid logging large raw payloads unless necessary.

### 13.2 Logging Outputs and Sinks

The spec does not prescribe where logs are written (stderr, file, remote sink, etc.).

Requirements:

- Operators MUST be able to see startup/validation/dispatch failures without attaching a debugger.
- Implementations MAY write to one or more sinks.
- If a configured log sink fails, the service SHOULD continue running when possible and emit an
  operator-visible warning through any remaining sink.

### 13.3 Runtime Snapshot / Monitoring Interface (OPTIONAL but RECOMMENDED)

If the implementation exposes a synchronous runtime snapshot (for dashboards or monitoring), it
SHOULD return:

- `running` (list of running session rows)
- each running row SHOULD include `turn_count`
- `retrying` (list of retry queue rows)
- `codex_totals`
  - `input_tokens`
  - `output_tokens`
  - `total_tokens`
  - `seconds_running` (aggregate runtime seconds as of snapshot time, including active sessions)
- `rate_limits` (latest coding-agent rate limit payload, if available)

RECOMMENDED snapshot error modes:

- `timeout`
- `unavailable`

### 13.4 OPTIONAL Human-Readable Status Surface

A human-readable status surface (terminal output, dashboard, etc.) is OPTIONAL and
implementation-defined.

If present, it SHOULD draw from orchestrator state/metrics only and MUST NOT be REQUIRED for
correctness.

### 13.5 Session Metrics and Token Accounting

Token accounting rules:

- Agent events can include token counts in multiple payload shapes.
- Prefer absolute thread totals when available, such as:
  - `thread/tokenUsage/updated` payloads
  - `total_token_usage` within token-count wrapper events
- Ignore delta-style payloads such as `last_token_usage` for dashboard/API totals.
- Extract input/output/total token counts leniently from common field names within the selected
  payload.
- For absolute totals, track deltas relative to last reported totals to avoid double-counting.
- Do not treat generic `usage` maps as cumulative totals unless the event type defines them that
  way.
- Accumulate aggregate totals in orchestrator state.

Runtime accounting:

- Runtime SHOULD be reported as a live aggregate at snapshot/render time.
- Implementations MAY maintain a cumulative counter for ended sessions and add active-session
  elapsed time derived from `running` entries (for example `started_at`) when producing a
  snapshot/status view.
- Add run duration seconds to the cumulative ended-session runtime when a session ends (normal exit
  or cancellation/termination).
- Continuous background ticking of runtime totals is not REQUIRED.

Rate-limit tracking:

- Track the latest rate-limit payload seen in any agent update.
- Any human-readable presentation of rate-limit data is implementation-defined.

### 13.6 Humanized Agent Event Summaries (OPTIONAL)

Humanized summaries of raw agent protocol events are OPTIONAL.

If implemented:

- Treat them as observability-only output.
- Do not make orchestrator logic depend on humanized strings.

### 13.7 OPTIONAL HTTP Server Extension

This section defines an OPTIONAL HTTP interface for observability and operational control.

If implemented:

- The HTTP server is an extension and is not REQUIRED for conformance.
- The implementation MAY serve server-rendered HTML or a client-side application for the dashboard.
- The dashboard/API MUST be observability/control surfaces only and MUST NOT become REQUIRED for
  orchestrator correctness.

Extension config:

- `server.port` (integer, OPTIONAL)
  - Enables the HTTP server extension.
  - `0` requests an ephemeral port for local development and tests.
  - CLI `--port` overrides `server.port` when both are present.

Enablement (extension):

- Start the HTTP server when a CLI `--port` argument is provided.
- Start the HTTP server when `server.port` is present in `TRACKER.yaml`.
- The `server` top-level key is owned by this extension.
- Positive `server.port` values bind that port.
- Implementations SHOULD bind loopback by default (`127.0.0.1` or host equivalent) unless explicitly
  configured otherwise.
- Changes to HTTP listener settings (for example `server.port`) do not need to hot-rebind;
  restart-required behavior is conformant.

#### 13.7.1 Human-Readable Dashboard (`/`)

- Host a human-readable dashboard at `/`.
- The returned document SHOULD depict the current state of the system (for example active sessions,
  retry delays, token consumption, runtime totals, recent events, and health/error indicators).
- It is up to the implementation whether this is server-generated HTML or a client-side app that
  consumes the JSON API below.

#### 13.7.1.1 Workflow Configuration Visualization (`/workflow`)

An implementation MAY host a read-only workflow configuration visualization at `/workflow`.

If provided:

- The page MUST treat `WORKFLOW.md` and `TRACKER.yaml` as data sources only; it MUST NOT edit or
  persist workflow configuration.
- The page SHOULD render workflow stages as nodes and ordinary `transitions` as outcome-labelled
  directed edges.
- The page SHOULD visually distinguish `workflow.start_stage`, `workflow.terminal_stages`,
  blocked/protocol-blocked paths, and `workflow.missing_outcome.on_exhausted`.
- `workflow.missing_outcome.max_retries` and `on_exhausted` SHOULD be shown separately from ordinary
  business transitions so operators do not mistake protocol fallback for a normal outcome path.
- The page SHOULD expose configuration diagnostics such as unknown transition targets, unknown
  outcomes, missing terminal stages, non-terminal stages without transitions, stages unreachable
  from `workflow.start_stage`, and terminal stages not reachable from normal or missing-outcome
  paths.
- When `TRACKER.yaml` is available, the page SHOULD summarize tracker kind, stage-to-provider-state
  mapping, and whether every workflow stage has a provider-visible state mapping.
- The page MUST NOT render raw credential values, including `api_key`, token, env secret, password,
  or credential fields from tracker/runtime config.
- When an orchestrator snapshot is available, the page MAY overlay running, retrying, and blocked
  issue counts by `current_stage`; snapshot timeout or unavailability MUST NOT prevent the static
  workflow graph and diagnostics from rendering.

#### 13.7.2 JSON REST API (`/api/v1/*`)

Provide a JSON REST API under `/api/v1/*` for current runtime state and operational debugging.

Minimum endpoints:

- `GET /api/v1/state`
  - Returns a summary view of the current system state (running sessions, retry queue/delays,
    aggregate token/runtime totals, latest rate limits, and any additional tracked summary fields).
  - Suggested response shape:

    ```json
    {
      "generated_at": "2026-02-24T20:15:30Z",
      "counts": {
        "running": 2,
        "retrying": 1,
        "blocked": 1
      },
      "running": [
        {
          "issue_id": "abc123",
          "issue_identifier": "MT-649",
          "state": "In Progress",
          "session_id": "thread-1-turn-1",
          "turn_count": 7,
          "last_event": "turn_completed",
          "last_message": "",
          "started_at": "2026-02-24T20:10:12Z",
          "last_event_at": "2026-02-24T20:14:59Z",
          "tokens": {
            "input_tokens": 1200,
            "output_tokens": 800,
            "total_tokens": 2000
          }
        }
      ],
      "retrying": [
        {
          "issue_id": "def456",
          "issue_identifier": "MT-650",
          "attempt": 3,
          "due_at": "2026-02-24T20:16:00Z",
          "error": "no available orchestrator slots"
        }
      ],
      "blocked": [
        {
          "issue_id": "ghi789",
          "issue_identifier": "MT-651",
          "state": "In Progress",
          "error": "codex MCP elicitation requires operator input",
          "recovery_artifact": {
            "artifact_dir": "/workspaces/MT-651/.symphony/blocked/2026-02-24T20-12-00Z-thread-2-turn-3",
            "available?": true
          },
          "session_id": "thread-2-turn-3",
          "blocked_at": "2026-02-24T20:12:00Z",
          "last_event": "turn_input_required",
          "last_message": "Operator input required",
          "last_event_at": "2026-02-24T20:12:00Z"
        }
      ],
      "codex_totals": {
        "input_tokens": 5000,
        "output_tokens": 2400,
        "total_tokens": 7400,
        "seconds_running": 1834.2
      },
      "rate_limits": null
    }
    ```

- `GET /api/v1/<issue_identifier>`
  - Returns issue-specific runtime/debug details for the identified issue, including any information
    the implementation tracks that is useful for debugging.
  - Suggested response shape:

    ```json
    {
      "issue_identifier": "MT-649",
      "issue_id": "abc123",
      "status": "running",
      "workspace": {
        "path": "/tmp/symphony_workspaces/MT-649"
      },
      "attempts": {
        "restart_count": 1,
        "current_retry_attempt": 2
      },
      "running": {
        "session_id": "thread-1-turn-1",
        "turn_count": 7,
        "state": "In Progress",
        "started_at": "2026-02-24T20:10:12Z",
        "last_event": "notification",
        "last_message": "Working on tests",
        "last_event_at": "2026-02-24T20:14:59Z",
        "tokens": {
          "input_tokens": 1200,
          "output_tokens": 800,
          "total_tokens": 2000
        }
      },
      "retry": null,
      "logs": {
        "codex_session_logs": [
          {
            "label": "latest",
            "path": "/var/log/symphony/codex/MT-649/latest.log",
            "url": null
          }
        ]
      },
      "recent_events": [
        {
          "at": "2026-02-24T20:14:59Z",
          "event": "notification",
          "message": "Working on tests"
        }
      ],
      "last_error": null,
      "tracked": {}
    }
    ```

  - If the issue is unknown to the current in-memory state, return `404` with an error response (for
    example `{\"error\":{\"code\":\"issue_not_found\",\"message\":\"...\"}}`).

- `POST /api/v1/refresh`
  - Queues an immediate tracker poll + reconciliation cycle (best-effort trigger; implementations
    MAY coalesce repeated requests).
  - Suggested request body: empty body or `{}`.
  - Suggested response (`202 Accepted`) shape:

    ```json
    {
      "queued": true,
      "coalesced": false,
      "requested_at": "2026-02-24T20:15:30Z",
      "operations": ["poll", "reconcile"]
    }
    ```

API design notes:

- The JSON shapes above are the RECOMMENDED baseline for interoperability and debugging ergonomics.
- Implementations MAY add fields, but SHOULD avoid breaking existing fields within a version.
- Endpoints SHOULD be read-only except for operational triggers like `/refresh`.
- Unsupported methods on defined routes SHOULD return `405 Method Not Allowed`.
- API errors SHOULD use a JSON envelope such as `{"error":{"code":"...","message":"..."}}`.
- If the dashboard is a client-side app, it SHOULD consume this API rather than duplicating state
  logic.

#### 13.7.3 Multi-Instance Operator Management (OPTIONAL)

An implementation MAY expose a thin multi-instance operator dashboard/API for deployments where
several independent Symphony processes run side by side, for example under a systemd template.

If implemented:

- Each managed instance MUST remain an independent Symphony runtime with its own workflow file,
  environment, workspace root, log directory, port, and in-memory orchestrator state.
- The management surface MAY discover registered instances from implementation-defined config
  directories and MAY aggregate service-manager state plus each instance's observability API.
- Stopped, failed, or unreachable instances MUST be represented as per-instance health states and
  MUST NOT prevent other instances from being shown.
- Lifecycle actions such as start, stop, and restart MAY be exposed as operational triggers, but
  failures MUST be reported with operator-readable errors.
- The management surface MAY coordinate deployment updates for the Symphony program itself. If it
  does, it SHOULD poll the upstream source with conditional requests where available, serialize
  update execution, refuse updates when the source checkout has local changes, build before any
  restart, and decide per instance whether to restart immediately, defer until idle, skip failed
  services, or require manual confirmation.
- The management surface MUST NOT become a prerequisite for issue dispatch, retry/reconciliation
  semantics, workspace isolation, or coding-agent protocol correctness.

## 14. Failure Model and Recovery Strategy

### 14.1 Failure Classes

1. `Workflow/Config Failures`
   - Missing `WORKFLOW.md`
   - Invalid YAML front matter
   - Unsupported tracker kind or missing tracker credentials/project slug
   - Missing coding-agent executable

2. `Workspace Failures`
   - Workspace directory creation failure
   - Workspace population/synchronization failure (implementation-defined; can come from hooks)
   - Invalid workspace path configuration
   - Hook timeout/failure

3. `Agent Session Failures`
   - Startup handshake failure
   - Turn failed/cancelled
   - Turn timeout
   - User input requested and handled as failure by the implementation's documented policy
   - Subprocess exit
   - Stalled session (no activity)

4. `Tracker Failures`
   - API transport errors
   - Non-200 status
   - GraphQL errors
   - malformed payloads

5. `Observability Failures`
   - Snapshot timeout
   - Dashboard render errors
   - Log sink configuration failure

### 14.2 Recovery Behavior

- Dispatch validation failures:
  - Skip new dispatches.
  - Keep service alive.
  - Continue reconciliation where possible.

- Worker failures:
  - Convert to retries with exponential backoff.

- Tracker candidate-fetch failures:
  - Skip this tick.
  - Try again on next tick.

- Reconciliation state-refresh failures:
  - Keep current workers.
  - Retry on next tick.

- Dashboard/log failures:
  - Do not crash the orchestrator.

### 14.3 Partial State Recovery (Restart)

Current design is intentionally in-memory for scheduler state.
Restart recovery means the service can resume useful operation by polling tracker state and reusing
preserved workspaces. It does not mean retry timers, running sessions, or live worker state survive
process restart.

After restart:

- No retry timers are restored from prior process memory.
- No running sessions are assumed recoverable.
- Service recovers by:
  - startup terminal workspace cleanup
  - fresh polling of active issues
  - re-dispatching eligible work

### 14.4 Operator Intervention Points

Operators can control behavior by:

- Editing `WORKFLOW.md` (workflow stages and prompts) or `TRACKER.yaml` (provider/runtime settings).
- `WORKFLOW.md` and `TRACKER.yaml` changes are detected and re-applied automatically without
  restart according to Section 6.2.
- Changing issue states in the tracker:
  - terminal state -> running session is stopped and workspace cleaned when reconciled
  - non-active state -> running session is stopped without cleanup
- Restarting the service for process recovery or deployment (not as the normal path for applying
  workflow config changes).

## 15. Security and Operational Safety

### 15.1 Trust Boundary Assumption

Each implementation defines its own trust boundary.

Operational safety requirements:

- Implementations SHOULD state clearly whether they are intended for trusted environments, more
  restrictive environments, or both.
- Implementations SHOULD state clearly whether they rely on auto-approved actions, operator
  approvals, stricter sandboxing, or some combination of those controls.
- Workspace isolation and path validation are important baseline controls, but they are not a
  substitute for whatever approval and sandbox policy an implementation chooses.

### 15.2 Filesystem Safety Requirements

Mandatory:

- Workspace path MUST remain under configured workspace root.
- Coding-agent cwd MUST be the per-issue workspace path for the current run.
- Workspace directory names MUST use sanitized identifiers.

RECOMMENDED additional hardening for ports:

- Run under a dedicated OS user.
- Restrict workspace root permissions.
- Mount workspace root on a dedicated volume if possible.

### 15.3 Secret Handling

- Support `$VAR` indirection in tracker/runtime config.
- Do not log API tokens or secret env values.
- Validate presence of secrets without printing them.

### 15.4 Hook Script Safety

Workspace hooks are arbitrary shell scripts from `TRACKER.yaml`.

Implications:

- Hooks are fully trusted configuration.
- Hooks run inside the workspace directory.
- Hook output SHOULD be truncated in logs.
- Hook timeouts are REQUIRED to avoid hanging the orchestrator.

### 15.5 Harness Hardening Guidance

Running Codex agents against repositories, issue trackers, and other inputs that can contain
sensitive data or externally-controlled content can be dangerous. A permissive deployment can lead
to data leaks, destructive mutations, or full machine compromise if the agent is induced to execute
harmful commands or use overly-powerful integrations.

Implementations SHOULD explicitly evaluate their own risk profile and harden the execution harness
where appropriate. This specification intentionally does not mandate a single hardening posture, but
implementations SHOULD NOT assume that tracker data, repository contents, prompt inputs, or tool
arguments are fully trustworthy just because they originate inside a normal workflow.

Possible hardening measures include:

- Tightening Codex approval and sandbox settings described elsewhere in this specification instead
  of running with a maximally permissive configuration.
- Adding external isolation layers such as OS/container/VM sandboxing, network restrictions, or
  separate credentials beyond the built-in Codex policy controls.
- Filtering which Linear issues, projects, teams, labels, or other tracker sources are eligible for
  dispatch so untrusted or out-of-scope tasks do not automatically reach the agent.
- Narrowing the `linear_graphql` tool so it can only read or mutate data inside the
  intended project scope, rather than exposing general workspace-wide tracker access.
- Reducing the set of client-side tools, credentials, filesystem paths, and network destinations
  available to the agent to the minimum needed for the workflow.

The correct controls are deployment-specific, but implementations SHOULD document them clearly and
treat harness hardening as part of the core safety model rather than an optional afterthought.

## 16. Reference Algorithms (Language-Agnostic)

### 16.1 Service Startup

```text
function start_service():
  configure_logging()
  start_observability_outputs()
  start_workflow_watch(on_change=reload_and_reapply_workflow)

  state = {
    poll_interval_ms: get_config_poll_interval_ms(),
    max_concurrent_agents: get_config_max_concurrent_agents(),
    running: {},
    claimed: set(),
    retry_attempts: {},
    completed: set(),
    codex_totals: {input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    codex_rate_limits: null
  }

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    fail_startup(validation)

  startup_terminal_workspace_cleanup()
  schedule_tick(delay_ms=0)

  event_loop(state)
```

### 16.2 Poll-and-Dispatch Tick

```text
on_tick(state):
  state = reconcile_running_issues(state)

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  if workflow_stage_mode:
    issues = tracker.fetch_runnable_issues(workflow.start_stage)
  else:
    issues = tracker.fetch_candidate_issues()
  if issues failed:
    log_tracker_error()
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  for issue in sort_for_dispatch(issues):
    if no_available_slots(state):
      break

    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)

  notify_observers()
  schedule_tick(state.poll_interval_ms)
  return state
```

### 16.3 Reconcile Active Runs

```text
function reconcile_running_issues(state):
  state = reconcile_stalled_runs(state)

  running_ids = keys(state.running)
  if running_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(running_ids)
  if refreshed failed:
    log_debug("keep workers running")
    return state

  for issue in refreshed:
    if workflow_stage_mode and tracker.read_issue_stage(issue) is completion_terminal_stage:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=true)
    else if workflow_stage_mode and tracker.read_issue_stage(issue) in workflow.terminal_stages:
      state = stop_worker_and_block_issue(state, issue.id, preserve_recovery_artifact=true)
    else if workflow_stage_mode and tracker.read_issue_stage(issue) != state.running[issue.id].current_stage:
      state.running[issue.id].issue = issue
      state.running[issue.id].stage_conflict = {
        local_stage: state.running[issue.id].current_stage,
        provider_stage: tracker.read_issue_stage(issue)
      }
      log_warning("workflow stage conflict")
    else:
      state.running[issue.id].issue = issue

  return state
```

### 16.4 Dispatch One Issue

```text
function dispatch_issue(issue, state, attempt):
  worker = spawn_worker(
    fn -> run_agent_attempt(issue, attempt, parent_orchestrator_pid) end
  )

  if worker spawn failed:
    return schedule_retry(state, issue.id, next_attempt(attempt), {
      identifier: issue.identifier,
      error: "failed to spawn agent"
    })

  state.running[issue.id] = {
    worker_handle,
    monitor_handle,
    identifier: issue.identifier,
    issue,
    session_id: null,
    codex_app_server_pid: null,
    last_codex_message: null,
    last_codex_event: null,
    last_codex_timestamp: null,
    codex_input_tokens: 0,
    codex_output_tokens: 0,
    codex_total_tokens: 0,
    last_reported_input_tokens: 0,
    last_reported_output_tokens: 0,
    last_reported_total_tokens: 0,
    retry_attempt: normalize_attempt(attempt),
    started_at: now_utc()
  }

  state.claimed.add(issue.id)
  state.retry_attempts.remove(issue.id)
  return state
```

### 16.5 Worker Attempt (Workspace + Prompt + Agent)

```text
function run_agent_attempt(issue, attempt, orchestrator_channel):
  workspace = workspace_manager.create_for_issue(issue.identifier)
  if workspace failed:
    fail_worker("workspace error")

  if run_hook("before_run", workspace.path) failed:
    fail_worker("before_run hook error")

  session = app_server.start_session(workspace=workspace.path)
  if session failed:
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent session startup error")

  max_turns = config.agent.max_turns
  turn_number = 1

  while true:
    prompt = build_turn_prompt(
      workflow_template,
      issue,
      attempt,
      turn_number,
      max_turns
    )
    if prompt failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("prompt error")

    turn_result = app_server.run_turn(
      session=session,
      prompt=prompt,
      issue=issue,
      on_message=(msg) -> send(orchestrator_channel, {codex_update, issue.id, msg})
    )

    if turn_result failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("agent turn error")

    refreshed_issue = tracker.fetch_issue_states_by_ids([issue.id])
    if refreshed_issue failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("issue state refresh error")

    issue = refreshed_issue[0] or issue

    if issue.state is not active:
      break

    if turn_number >= max_turns:
      break

    turn_number = turn_number + 1

  app_server.stop_session(session)
  run_hook_best_effort("after_run", workspace.path)

  exit_normal()
```

### 16.6 Worker Exit and Retry Handling

```text
on_worker_exit(issue_id, reason, state):
  running_entry = state.running.remove(issue_id)
  state = add_runtime_seconds_to_totals(state, running_entry)

  if reason == normal:
    if running_entry.current_stage is completion_terminal_stage:
      state.completed.add(issue_id)  # bookkeeping only
      remove_workspace(running_entry.identifier, running_entry.worker_host)
      state.claimed.remove(issue_id)
    else if running_entry.current_stage in workflow.terminal_stages:
      state.blocked[issue_id] = blocked_context(running_entry, "terminal blocked stage")
      preserve_recovery_artifact(running_entry.workspace_path, running_entry.session_id)
    else:
      state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
        retry_kind: "running",
        identifier: running_entry.identifier,
        current_stage: running_entry.current_stage,
        workspace_path: running_entry.workspace_path,
        session_id: running_entry.session_id,
        error: "worker exited before terminal stage"
      })
  else:
    state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
      retry_kind: "running",
      identifier: running_entry.identifier,
      current_stage: running_entry.current_stage,
      workspace_path: running_entry.workspace_path,
      session_id: running_entry.session_id,
      error: format("worker exited: %reason")
    })

  notify_observers()
  return state
```

```text
on_retry_timer(issue_id, state):
  retry_entry = state.retry_attempts.pop(issue_id)
  if missing:
    return state

  refreshed = tracker.fetch_issue_states_by_ids([issue_id])
  if refresh failed:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: retry_entry.identifier,
      error: "retry refresh failed"
    })

  issue = refreshed[0]
  if issue is null:
    if retry_entry.retry_kind == "running":
      state.blocked[issue_id] = blocked_retry_context(retry_entry, "issue not found")
    else:
      state.claimed.remove(issue_id)
    return state

  if retry_entry.retry_kind == "running":
    provider_stage = tracker.read_issue_stage(issue)
    if provider_stage is completion_terminal_stage:
      remove_workspace(issue.identifier, retry_entry.worker_host)
      state.claimed.remove(issue_id)
      return state
    if provider_stage in workflow.terminal_stages:
      state.blocked[issue_id] = blocked_retry_context(retry_entry, "terminal blocked stage")
      preserve_recovery_artifact(retry_entry.workspace_path, retry_entry.session_id)
      return state

    if provider_stage is unreadable or issue is no longer routable or has unresolved blockers:
      state.blocked[issue_id] = blocked_retry_context(retry_entry, "running retry recovery blocked")
      return state

    if retry_entry.current_stage exists and provider_stage != retry_entry.current_stage:
      state.blocked[issue_id] = blocked_retry_context(retry_entry, "workflow stage conflict")
      return state

  if available_slots(state) == 0:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      retry_kind: retry_entry.retry_kind,
      identifier: issue.identifier,
      current_stage: provider_stage or retry_entry.current_stage,
      error: "no available orchestrator slots"
    })

  return dispatch_issue(issue, state, attempt=retry_entry.attempt)
```

## 17. Test and Validation Matrix

A conforming implementation SHOULD include tests that cover the behaviors defined in this
specification.

Validation profiles:

- `Core Conformance`: deterministic tests REQUIRED for all conforming implementations.
- `Extension Conformance`: REQUIRED only for OPTIONAL features that an implementation chooses to
  ship.
- `Real Integration Profile`: environment-dependent smoke/integration checks RECOMMENDED before
  production use.

Unless otherwise noted, Sections 17.1 through 17.7 are `Core Conformance`. Bullets that begin with
`If ... is implemented` are `Extension Conformance`.

### 17.1 Workflow and Config Parsing

- Workflow file path precedence:
  - explicit runtime path is used when provided
  - cwd default is `WORKFLOW.md` when no explicit runtime path is provided
- Tracker config path precedence:
  - explicit `--tracker-config` path is used when provided
  - in workflow-stage mode, default is `TRACKER.yaml` next to the selected `WORKFLOW.md`
- Workflow and tracker config changes are detected and trigger re-read/re-apply without restart
- Invalid workflow reload keeps last known good effective configuration and emits an
  operator-visible error
- Missing `WORKFLOW.md` returns typed error
- Missing explicit or sibling `TRACKER.yaml` returns typed error in workflow-stage mode
- Invalid YAML front matter returns typed error
- Front matter non-map returns typed error
- Workflow-stage schema validates `start_stage`, non-empty `terminal_stages`, transition targets,
  and `missing_outcome.on_exhausted`
- Legacy provider tracker fields in workflow-stage `WORKFLOW.md` return a typed migration error
- Config defaults apply when OPTIONAL values are missing
- `tracker.kind` validation enforces currently supported kinds (`linear`, `github`, `gitlab`, `memory`)
- `tracker.api_key` works (including `$VAR` indirection)
- `$VAR` resolution works for tracker API key and path values
- `~` path expansion works
- `codex.command` is preserved as a shell command string
- Per-state concurrency override map normalizes state names and ignores invalid values
- Prompt template renders `issue` and `attempt`
- Prompt rendering fails on unknown variables (strict mode)

### 17.2 Workspace Manager and Safety

- Deterministic workspace path per issue identifier
- Missing workspace directory is created
- Existing workspace directory is reused
- Existing non-directory path at workspace location is handled safely (replace or fail per
  implementation policy)
- OPTIONAL workspace population/synchronization errors are surfaced
- `after_create` hook runs only on new workspace creation
- `before_run` hook runs before each attempt and failure/timeouts abort the current attempt
- `after_run` hook runs after each attempt and failure/timeouts are logged and ignored
- `before_remove` hook runs on cleanup and failures/timeouts are ignored
- Workspace path sanitization and root containment invariants are enforced before agent launch
- Agent launch uses the per-issue workspace path as cwd and rejects out-of-root paths

### 17.3 Issue Tracker Client

- Workflow-stage candidate fetch uses `workflow.start_stage` and `tracker.stage_states`
- Non-Memory provider adapters may keep the workflow-stage contract unsupported until their
  provider-specific mappings are implemented, but they must not advertise stage support without
  matching tests
- Legacy candidate issue fetch uses active states and project slug
- Linear query uses the specified project filter field (`slugId`)
- Empty `fetch_issues_by_states([])` returns empty without API call
- Pagination preserves order across multiple pages
- Blockers are normalized from inverse relations of type `blocks`
- Labels are normalized to lowercase
- Issue state refresh by ID returns minimal normalized issues
- Issue state refresh query uses GraphQL ID typing (`[ID!]`) as specified in Section 11.2
- Error mapping for request errors, non-200, GraphQL errors, malformed payloads

### 17.4 Orchestrator Dispatch, Reconciliation, and Retry

- Dispatch sort order is priority then oldest creation time
- `Todo` issue with non-terminal blockers is not eligible
- `Todo` issue with terminal blockers is eligible
- Active-state issue refresh updates running entry state
- Non-active state stops running agent without workspace cleanup
- Terminal state stops running agent and cleans workspace
- Reconciliation with no running issues is a no-op
- Workflow-stage normal worker exit releases the claim without scheduling continuation retry
- Legacy normal worker exit schedules a short continuation retry (attempt 1)
- Abnormal worker exit increments retries with 10s-based exponential backoff
- Workflow-stage abnormal/stalled running retries recover the same issue by id at a non-terminal
  middle stage without applying the new-dispatch start-stage filter
- Workflow-stage running retries release terminal provider stages and block unreadable, conflicting,
  unroutable, or dependency-blocked recovery state instead of orphaning the claim
- Retry backoff cap uses configured `agent.max_retry_backoff_ms`
- Retry queue entries include attempt, due time, retry kind, identifier, current stage, and error
- Stall detection kills stalled sessions and schedules retry
- Slot exhaustion requeues retries with explicit error reason
- If a snapshot API is implemented, it returns running rows, retry rows, token totals, and rate
  limits
- If a snapshot API is implemented, timeout/unavailable cases are surfaced

### 17.5 Coding-Agent App-Server Client

- Launch command uses workspace cwd and invokes `bash -lc <codex.command>`
- Session startup follows the targeted Codex app-server protocol.
- Client identity/capability payloads are valid when the targeted Codex app-server protocol requires
  them.
- Policy-related startup payloads use the implementation's documented approval/sandbox settings
- Thread and turn identities exposed by the targeted protocol are extracted and used to emit
  `session_started`
- Request/response read timeout is enforced
- Turn timeout is enforced
- Transport framing required by the targeted protocol is handled correctly
- For stdio-based transports, diagnostic stderr handling is kept separate from the protocol stream
- Command/file-change approvals are handled according to the implementation's documented policy
- Unsupported dynamic tool calls are rejected without stalling the session
- User input requests are handled according to the implementation's documented policy and do not
  stall indefinitely
- Usage and rate-limit telemetry exposed by the targeted protocol is extracted
- Approval, user-input-required, usage, and rate-limit signals are interpreted according to the
  targeted protocol
- If client-side tools are implemented, session startup advertises the supported tool specs
  using the targeted app-server protocol
- If the `linear_graphql` client-side tool extension is implemented:
  - the tool is advertised to the session
  - valid `query` / `variables` inputs execute against configured Linear auth
  - top-level GraphQL `errors` produce `success=false` while preserving the GraphQL body
  - invalid arguments, missing auth, and transport failures return structured failure payloads
  - unsupported tool names still fail without stalling the session

### 17.6 Observability

- Validation failures are operator-visible
- Structured logging includes issue/session context fields
- Logging sink failures do not crash orchestration
- Token/rate-limit aggregation remains correct across repeated agent updates
- If a human-readable status surface is implemented, it is driven from orchestrator state and does
  not affect correctness
- If humanized event summaries are implemented, they cover key wrapper/agent event classes without
  changing orchestrator behavior

### 17.7 CLI and Host Lifecycle

- CLI accepts a positional workflow path argument (`path-to-WORKFLOW.md`)
- CLI accepts `--tracker-config <path-to-TRACKER.yaml>`
- CLI uses `./WORKFLOW.md` when no workflow path argument is provided
- CLI uses sibling `TRACKER.yaml` for workflow-stage configs when `--tracker-config` is omitted
- CLI errors on nonexistent explicit workflow path or missing default `./WORKFLOW.md`
- CLI errors on nonexistent explicit tracker config path
- CLI surfaces startup failure cleanly
- CLI exits with success when application starts and shuts down normally
- CLI exits nonzero when startup fails or the host process exits abnormally

### 17.8 Real Integration Profile (RECOMMENDED)

These checks are RECOMMENDED for production readiness and MAY be skipped in CI when credentials,
network access, or external service permissions are unavailable.

- A real tracker smoke test can be run with valid credentials supplied by `LINEAR_API_KEY` or a
  documented local bootstrap mechanism (for example `~/.linear_api_key`).
- Real integration tests SHOULD use isolated test identifiers/workspaces and clean up tracker
  artifacts when practical.
- A skipped real-integration test SHOULD be reported as skipped, not silently treated as passed.
- If a real-integration profile is explicitly enabled in CI or release validation, failures SHOULD
  fail that job.

## 18. Implementation Checklist (Definition of Done)

Use the same validation profiles as Section 17:

- Section 18.1 = `Core Conformance`
- Section 18.2 = `Extension Conformance`
- Section 18.3 = `Real Integration Profile`

### 18.1 REQUIRED for Conformance

- Workflow path selection supports explicit runtime path and cwd default
- Tracker config path selection supports explicit `--tracker-config` and workflow-sibling default
- `WORKFLOW.md` loader with YAML front matter + prompt body split
- `TRACKER.yaml` loader with YAML map parsing
- Typed config layer with defaults and `$` resolution
- Dynamic `WORKFLOW.md` and `TRACKER.yaml` watch/reload/re-apply for config and prompt
- Polling orchestrator with single-authority mutable state
- Issue tracker client with candidate fetch + state refresh + terminal fetch
- Workspace manager with sanitized per-issue workspaces
- Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`)
- Hook timeout config (`hooks.timeout_ms`, default `60000`)
- Coding-agent app-server subprocess client with JSON line protocol
- Codex launch command config (`codex.command`, default `codex app-server`)
- Strict prompt rendering with `issue` and `attempt` variables
- Exponential retry queue with continuation retries after normal exit
- Configurable retry backoff cap (`agent.max_retry_backoff_ms`, default 5m)
- Reconciliation that stops runs on terminal/non-active tracker states
- Workspace cleanup for terminal issues (startup sweep + active transition)
- Structured logs with `issue_id`, `issue_identifier`, and `session_id`
- Operator-visible observability (structured logs; OPTIONAL snapshot/status surface)

### 18.2 RECOMMENDED Extensions (Not REQUIRED for Conformance)

- HTTP server extension honors CLI `--port` over `server.port`, uses a safe default bind host, and
  exposes the baseline endpoints/error semantics in Section 13.7 if shipped.
- `linear_graphql` client-side tool extension exposes raw Linear GraphQL access through the
  app-server session using configured Symphony auth.
- TODO: Persist retry queue and session metadata across process restarts.
- TODO: Make observability settings configurable in tracker/runtime config without prescribing UI
  implementation details.
- TODO: Add first-class tracker write APIs (comments/state transitions) in the orchestrator instead
  of only via agent tools.
- TODO: Add pluggable issue tracker adapters beyond Linear.

### 18.3 Operational Validation Before Production (RECOMMENDED)

- Run the `Real Integration Profile` from Section 17.8 with valid credentials and network access.
- Verify hook execution and workflow path resolution on the target host OS/shell environment.
- If the OPTIONAL HTTP server is shipped, verify the configured port behavior and loopback/default
  bind expectations on the target environment.

## Appendix A. SSH Worker Extension (OPTIONAL)

This appendix describes a common extension profile in which Symphony keeps one central
orchestrator but executes worker runs on one or more remote hosts over SSH.

Extension config:

- `worker.ssh_hosts` (list of SSH host strings, OPTIONAL)
  - When omitted, work runs locally.
- `worker.max_concurrent_agents_per_host` (positive integer, OPTIONAL)
  - Shared per-host cap applied across configured SSH hosts.

### A.1 Execution Model

- The orchestrator remains the single source of truth for polling, claims, retries, and
  reconciliation.
- `worker.ssh_hosts` provides the candidate SSH destinations for remote execution.
- Each worker run is assigned to one host at a time, and that host becomes part of the run's
  effective execution identity along with the issue workspace.
- `workspace.root` is interpreted on the remote host, not on the orchestrator host.
- The coding-agent app-server is launched over SSH stdio instead of as a local subprocess, so the
  orchestrator still owns the session lifecycle even though commands execute remotely.
- Continuation turns inside one worker lifetime SHOULD stay on the same host and workspace.
- A remote host SHOULD satisfy the same basic contract as a local worker environment: reachable
  shell, writable workspace root, coding-agent executable, and any required auth or repository
  prerequisites.

### A.2 Scheduling Notes

- SSH hosts MAY be treated as a pool for dispatch.
- Implementations MAY prefer the previously used host on retries when that host is still
  available.
- `worker.max_concurrent_agents_per_host` is an OPTIONAL shared per-host cap across configured SSH
  hosts.
- When all SSH hosts are at capacity, dispatch SHOULD wait rather than silently falling back to a
  different execution mode.
- Implementations MAY fail over to another host when the original host is unavailable before work
  has meaningfully started.
- Once a run has already produced side effects, a transparent rerun on another host SHOULD be
  treated as a new attempt, not as invisible failover.

### A.3 Problems to Consider

- Remote environment drift:
  - Each host needs the expected shell environment, coding-agent executable, auth, and repository
    prerequisites.
- Workspace locality:
  - Workspaces are usually host-local, so moving an issue to a different host is typically a cold
    restart unless shared storage exists.
- Path and command safety:
  - Remote path resolution, shell quoting, and workspace-boundary checks matter more once execution
    crosses a machine boundary.
- Startup and failover semantics:
  - Implementations SHOULD distinguish host-connectivity/startup failures from in-workspace agent
    failures so the same ticket is not accidentally re-executed on multiple hosts.
- Host health and saturation:
  - A dead or overloaded host SHOULD reduce available capacity, not cause duplicate execution or an
    accidental fallback to local work.
- Cleanup and observability:
  - Operators need to know which host owns a run, where its workspace lives, and whether cleanup
    happened on the right machine.
