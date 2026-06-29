# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

The Elixir implementation now supports the workflow-stage configuration shape used for the #45
migration: `WORKFLOW.md` defines provider-neutral stages, outcomes, transitions, and stage work
prompts, while `TRACKER.yaml` defines provider access plus workflow-stage to provider-state mapping.
Symphony owns the stable stage prompt wrapper and structured stage outcome channel; project files
provide variables and workflow policy, not tool implementation details. In workflow-stage mode the
runner advances stages inside one workspace and app-server session from structured outcomes, writing
provider-visible stages for observability instead of rereading provider state between stages.
Scheduler dispatch is also stage-aware: new work is discovered only from `workflow.start_stage`, and
dispatch is revalidated against the provider-visible stage before a worker is spawned. Running
worker recovery is scoped by issue id instead of the start-stage scan: an abnormal or stalled
middle-stage run can be retried at its current provider-visible workflow stage, while unreadable or
conflicting recovery state is exposed as blocked instead of silently releasing the claim. The stage
contract is implemented for Memory, Linear workflow states, GitHub Project v2 Status, and GitLab
scoped labels. Terminal stages are not all completion states: `blocked` and `protocol_blocked`
remain observable blocked records, do not close issues, and preserve workspace recovery evidence
instead of being cleaned up as delivered work. GitHub issues-only mode fails fast for multi-stage
provider-visible workflow state.
Legacy `WORKFLOW.md` tracker front matter is rejected at runtime; migrate to the split
`WORKFLOW.md` plus `TRACKER.yaml` layout before starting the service.

When the Elixir observability server is enabled, `/workflow` provides a read-only workflow-stage
visualization. It renders the current `WORKFLOW.md` stages and transitions, summarizes
`TRACKER.yaml` stage-state coverage without exposing credentials, and overlays available runtime
stage counts from the local orchestrator snapshot.

The Elixir implementation also includes the first Hub mode model baseline for the #74 direction.
`HUB.yaml` can register multiple projects, each pointing at its own `WORKFLOW.md` and optional
`TRACKER.yaml`; the Hub loader builds stable project identities, safe configuration snapshots, and
provider-neutral issue references. The Hub runtime ledger model builds on those identities with
recoverable claim, attempt, workspace lease, retry/backoff, session summary, and writeback
intent/result facts keyed by `project_id + IssueRef`. A model-only provider governance API defines
the future Hub provider exit: provider requests carry safe project/scope/issue correlation,
priority, fairness key, replay policy, cancellation boundary, quota/backoff/circuit observations,
and result classifications. `SymphonyElixir.Hub.PollCoordinator` adds the first Hub poll
coordination baseline on top of those models: it builds safe poll plans, candidate-scan governance
requests, eligibility/backoff decisions, recoverable poll facts, and optional sanitized
observability snapshots. `SymphonyElixir.Hub.CandidateIntake` adds the poll-to-dispatch intake
baseline: governed candidate-scan result summaries are normalized into provider-neutral candidate
records, tied back to the poll source project/provider scope/IssueRef and poll request/result ids,
and prechecked against paused/config-error projects, provider backoff/manual attention, active
attempts, workspace leases, and capacity without starting agents. Candidate/input_ref
project/scope fields are treated as provider input to validate against that poll source, not as
authority to rewrite the Hub project or provider scope. Safe Hub summaries redact full body fields
such as `body`, `comment_body`, `pull_request_body`, `pr_body`, `raw_provider_body`, and
`full_prompt` to hash/byte metadata before they reach provider queues, poll coordination, or
`/api/v1/state`. `SymphonyElixir.Hub.DispatchPlanning` adds the next Hub runtime baseline:
eligible intake candidates are converted into safe pending dispatch/start-intent summaries with
stable project/provider-scope/IssueRef identity and poll/intake source correlation. Planning
reserves only model-level intent slots, explains already-planned, capacity, active-attempt,
workspace, manual-attention, paused/config-error, and provider-backoff skips, and recovers previous
pending plans on refresh instead of duplicating them. It still does not start an agent, create a
real worker workspace, write providers, or replace legacy single-project scheduling.
`SymphonyElixir.Hub.DispatchPlanApplication` connects planning to the runtime ledger skeleton:
eligible planned intents are applied through `DispatchBoundary.dispatch/3` into recoverable claim,
attempt, workspace lease, start-intent, and safe run-context facts. Refresh/replay remains
idempotent: an existing unresolved start intent or active attempt is reported as already applied or
already planned instead of creating a second active attempt. The summary exposes applied, skipped,
blocked, manual-attention, and already-applied counts plus safe pending start-intent correlation.
This still does not launch Codex, create a real worker workspace, run workspace hooks, write
providers, or migrate legacy services.
`SymphonyElixir.Hub.WorkerStartHandoff` adds the Hub handoff boundary: refresh can now read pending
start intents from runtime-ledger replay, build a safe start request summary, ask an injectable
starter for `ack`, `failed`, `unknown`, or `manual_attention`, and apply the result back to the
ledger. Acknowledgements link the start intent to a running attempt; failures can enter
retry/backoff, blocked, released, or manual attention; unknown results remain unresolved so refresh
does not blindly start a second worker. The summary exposes selected, acked, failed, unknown,
manual-attention, already-acked, skipped, reason, pending/unresolved intent, worker lifecycle, and
replay counts. The default starter is still the safe skeleton and records unknown instead of starting
a worker. The opt-in real starter is the first controlled integration slice: it hands the safe
request to the existing AgentRunner/Workspace/Codex app-server path and records an acknowledgement
only after the worker reports a session start. This is not a complete Hub scheduler, provider
writeback executor, durable supervisor, or migration of `symphony@project.service`.
`SymphonyElixir.Hub.WorkerLifecycleReconciliation` adds the first post-ack lifecycle reconciliation
baseline. After a start intent has been acknowledged and an attempt is running, Hub can consume safe
worker/session result summaries from an injectable source and write completed/succeeded, failed,
cancelled, timeout/stopped, heartbeat lost, unknown, or manual-attention facts back into the runtime
ledger. Terminal results release workspace capacity or enter retry/backoff, blocked, or released
states; unresolved lost/unknown/manual-attention results retain the attempt/workspace as observable
evidence and do not trigger blind redispatch. Hub snapshot and `/api/v1/state` now expose safe
lifecycle counts, reason counts, workspace release/retention counts, and per-project summaries
without raw prompts, transcripts, provider bodies, hook/app-server output, tokens, cookies, or raw
config. This remains a reconciliation baseline, not a Hub-owned scheduler, worker supervisor,
provider writeback executor, durable store, or legacy service migration.
`SymphonyElixir.Hub.DispatchBoundary` adds the next
#74 baseline from candidate issue to active run intent: it model-checks `project_id + IssueRef`
claims, attempt ids, workspace leases, start intents, worker start acknowledgements, failure states,
and safe run context snapshots. It is still not a provider executor or full Hub scheduler: without
explicit Hub usage, the existing single-project startup, polling, workspace, provider calls, and
agent dispatch behavior remains unchanged.
The latest Hub provider tool/writeback routing baseline adds an opt-in boundary for structured
dynamic tool provider calls: GitHub issue, GitHub PR, and provider-neutral tracker issue tools can
construct safe `ProviderGovernance` requests, execute through an injectable boundary, and return
sanitized request/result/writeback summaries. This is still a migration seam only; legacy
single-project provider calls remain direct unless a caller explicitly opts into the Hub routing
boundary.
The Hub writeback intent/result processing baseline connects those routing summaries back to the
runtime ledger model: routed writeback intents can now be normalized into safe recoverable facts,
deduplicated by stable intent key, and replayed into decisions such as completed, retryable, provider
lookup required, manual attention, or conflict. It is still model-only and does not implement the
final Hub scheduler, provider writeback executor, persistent database, or Dashboard page; future
Dashboard/API surfaces can consume the safe writeback observability summary without seeing tokens,
prompts, transcripts, raw config, or full comment/PR bodies.
`SymphonyElixir.Hub.DeviceObservability` adds the device-level Hub observability and legacy
migration boundary baseline: it folds safe project registry, provider governance, poll
coordination, runtime ledger, dispatch, and writeback summaries into one Dashboard/API-safe
projection with device counts, per-project status, provider queue/backpressure, workspace/attempt
state, writeback/manual-attention state, and migration state such as `legacy_only`, `hub_ready`, or
`hub_managed`. This remains a projection only. It is not a new Dashboard page, does not replace
`symphony@project.service`, and does not mean Hub has taken over every provider poll loop.
The Elixir runtime now also has an explicit Hub entrypoint,
`./bin/symphony --hub-config /path/to/HUB.yaml --port <port>`, which loads the registry, builds a
poll plan, can execute one governed candidate-scan poll tick through the Hub provider request
boundary, records poll attempt/result facts, builds a safe `hub_candidate_intake` summary, and
exposes safe Hub fields through `/api/v1/state`, including `hub_dispatch_plan_application` and
`hub_worker_start_handoff` and `hub_worker_lifecycle_reconciliation` runtime-ledger replay summaries
after a plan is applied. The default skeleton executor does not migrate GitHub/GitLab/Linear legacy
adapters, create real workspaces, or start agents; the default start handoff records an unknown
skeleton result instead of launching a worker. Passing `--hub-worker-starter real` explicitly opts
into the first real worker handoff adapter, which starts through the existing worker boundary and
writes the safe ack/failure back to the ledger. Lifecycle reconciliation is likewise driven by a
controlled result source and remains safe-summary based. This entrypoint is opt-in only; the legacy
`--tracker-config TRACKER.yaml WORKFLOW.md` startup path and per-project services stay unchanged.
Passing `--hub-scheduler` adds the first opt-in Hub-owned tick loop baseline: startup and completed
ticks schedule the next safe refresh from the Hub poll plan, provider backoff, and unresolved
runtime-ledger lifecycle state, and `/refresh` coalesces with a running or queued tick instead of
starting a concurrent one. This scheduler summary is exposed as `hub_scheduler` and
`hub_runtime.scheduler`; it is still not the final durable Hub scheduler, provider writeback
executor, distributed lock, or migration of existing `symphony@project.service` instances.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
