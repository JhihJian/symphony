# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

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
    dispatch_enabled: true
  - project_id: docs
    workflow_path: ./docs/WORKFLOW.md
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
blocked candidates, conflicts, and manual-attention diagnostics, and can be filtered by
`project_id`. Ledger snapshots must not include token values, API keys, credentials, cookies, full
prompts, full Codex transcripts, or raw secret-bearing provider config.

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
`build_plan/2` prevents restart from immediately polling every registered project without regard to
the previous safe due time. If an orchestrator or Hub runtime snapshot includes
`hub_poll_coordination`, the observability presenter exposes the sanitized plan summary in
`/api/v1/state`; legacy snapshots without that field keep the existing API shape.

`SymphonyElixir.Hub.DispatchBoundary` adds the Hub atomic dispatch / run context baseline for #74.
It is also a pure model API. `build_context/3` turns a candidate issue into a stable dispatch
context with project id, configuration fingerprint or snapshot version, provider-neutral
`IssueRef`, workflow/tracker summary, trigger source (`poll_plan`, `manual_refresh`, `webhook`,
`running_reconciliation`, or `recovery`), governance/correlation metadata, attempt number/id input,
workspace path/lease id, start intent id, worker/runtime summary, runner summary, and preflight
diagnostics. Preflight reports whether the candidate can start or is blocked by an existing active
attempt, unresolved start intent, workspace conflict, retry/backoff, project pause, config error,
provider backpressure, or explicit block.

`dispatch/3` applies the context to a runtime ledger snapshot as one model-level transition:
claiming the issue, creating the attempt, acquiring the workspace lease, recording a start intent,
and attaching a safe run context. A repeated candidate for the same `project_id + IssueRef` returns
an idempotent `:ignored` result instead of adding a second active attempt. A workspace already held
by another active attempt returns a workspace-conflict preflight error. `acknowledge_start/3`
connects a start intent to a running attempt and compact agent session summary. `record_start_failure/4`
can move a half-started attempt to retry queued, blocked, released, or manual attention; unknown
worker-start results keep an unresolved start intent so recovery can explain the state and avoid a
blind double start. `release_attempt/3` closes the attempt and releases the workspace lease.

Run context snapshots include project/workflow/tracker snapshot references, issue identity, stage,
attempt/correlation ids, workspace lease/path, worker host/runtime identity summary, runner/start
command summary, session/activity timestamps, and exit summary. They intentionally do not include
provider tokens, API keys, secret env values, cookies, full prompts, complete Codex transcripts, or
raw secret-bearing config. If a runtime snapshot includes `hub_dispatch_boundary`, the observability
presenter exposes the sanitized replay summary in `/api/v1/state`; legacy snapshots without that
field keep the existing API shape.

This remains a #74 Hub model baseline only. It does not start a Hub poll loop, persistent provider
queue, database-backed store, cross-process distributed lock, real provider I/O, provider writeback
executor, full scheduler, or legacy worker lifecycle replacement. The existing
`./bin/symphony --tracker-config ./TRACKER.yaml ./WORKFLOW.md` startup path remains the legacy
single-project runtime, and the legacy `Orchestrator` keeps its current in-memory `running`,
`claimed`, `retry_attempts`, `blocked`, tracker fetch, stage writeback, workpad/PR operation, and
dynamic-tool behavior until a later explicit Hub integration.

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

The single-instance dashboard at `/` is the execution dashboard for the current Symphony process:
it shows the local orchestrator snapshot, running/retrying/blocked issues, token totals, and issue
detail links.

The workflow dashboard at `/workflow` is a read-only configuration understanding surface. It loads
the current `WORKFLOW.md` directly, renders stage nodes and outcome-labelled transitions, marks
`workflow.start_stage`, `workflow.terminal_stages`, blocked/protocol-blocked paths, and shows
`workflow.missing_outcome.max_retries` plus `on_exhausted` separately from ordinary transitions.
It also previews each stage prompt, lists outcome targets, reports semantic warnings such as
unreachable stages or non-terminal stages without transitions, and summarizes `TRACKER.yaml`
stage-state coverage. Tracker provider details are limited to non-secret hints such as kind,
owner/repo/project number or label prefix; token, `api_key`, env secret, and credential fields are
not rendered. When an orchestrator snapshot is available, the page overlays running/retrying/blocked
issue counts by `current_stage`; if the snapshot is unavailable, the static workflow graph and
configuration diagnostics still render.

The multi-instance dashboard at `/admin/instances` is a thin operator management plane. It reads
registered instances from `~/.config/symphony/projects` by default, checks each
`symphony@<project>.service` via `systemctl --user`, and queries each reachable instance's
`/api/v1/state`. Stopped, failed, or unreachable instances are rendered as per-instance health
states and do not block the rest of the overview. The page can create GitHub-backed instances by
delegating to `scripts/install-systemd-template.sh`, auto-allocates ports after checking existing
env files and listening sockets, and exposes `start`, `stop`, `restart`, `enable`, `disable`, and
recent-log actions for each service. Issue dispatch, retry semantics, workspace isolation, and
Codex app-server behavior remain owned by each individual instance's orchestrator.

Admin instance creation accepts either a one-time token entry or an environment variable reference;
tokens are passed only to the install script environment and are not returned by the JSON API or
rendered back into the page. Project names are restricted to safe systemd instance/path characters.
Admin JSON endpoints and LiveView actions are restricted to loopback clients because they can run
local `systemctl`, `journalctl`, and install-script commands.

The same management page shows `symphony-update.timer` state, including enabled/active status and
the next run time, and can enable, disable, or manually trigger `symphony-update.service`.

The same page includes a GitHub `main` auto-update control panel. `SymphonyElixir.AutoUpdate`
polls `jhihjian/symphony` with GitHub REST ETag/`If-None-Match` requests, records the current
deployed SHA, remote SHA, next check time, rate-limit metadata, and any last error, and exposes
manual check/update triggers through `/api/v1/admin/auto-update`. Update execution is serialized
with a host-local lock, refuses to proceed when the source checkout has local changes, fetches and
fast-forwards `origin/main`, builds only after code changed, and restarts instances only after a
successful build.

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
