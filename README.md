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
Hub provider execution now has explicit opt-in modes. The default remains the skeleton executor,
which records governed candidate-scan results without calling real provider APIs. Passing
`--hub-provider-executor real-candidate-scan` to Hub mode opts into the first real read executor:
only `candidate_scan` operations are handled, each request reloads the matching registry project's
own `WORKFLOW.md` and `TRACKER.yaml`, calls the existing tracker read adapter for that project
behind `ProviderGovernance`, and returns only safe candidate summaries for `CandidateIntake`.
Unsupported provider kinds, non-candidate operations, project config/auth failures, rate limits, and
retryable provider errors are mapped back to governed result classes and per-scope backoff/manual
attention summaries. This does not migrate provider writeback, dynamic tools, legacy
`symphony@project.service`, or non-Hub runtime behavior.
Passing `--hub-provider-executor real-writeback` opts into the first controlled real writeback
executor. It is deliberately narrow: status/stage writes, GitHub workpad marker upserts, and GitHub
label additions can execute after `WritebackProcessor` confirms the intent is safe to execute or
retry. Already-succeeded intents, conflicting intent keys, non-idempotent unknown results, PR
creation, plain append comments, unsupported providers, and unsupported operations return governed
manual-attention, lookup-required, or permanent-failure results without blind provider side effects.
Every execution resolves the request's `project_id` and provider scope back to the matching Hub
registry project before loading that project's own `WORKFLOW.md` and `TRACKER.yaml`; one project's
config/auth/provider failure is recorded for that project/scope only. Hub snapshot and
`/api/v1/state` include safe writeback executor mode, supported/rejected operations, counts, project
pressure, and recent error categories without tokens, raw provider payloads, or full comment/PR
bodies.
Hub activation preflight adds the #74 legacy ownership guardrail before those Hub-owned paths run.
For projects explicitly marked `hub_managed`, Hub evaluates a safe project snapshot plus injected
host/service probe evidence for active/enabled legacy services, legacy-owned provider scopes,
workspace/runtime/log/state ownership, Dashboard/API port ownership, instance registry ownership,
and unknown probe results. A blocked or unknown preflight prevents that project from candidate
scan, dispatch application, real worker start, and real writeback provider I/O by default, while
other projects whose preflight is safe continue to run. The summary is exposed as
`hub_activation_preflight` and inside device observability with blocked operations, reason/source,
last check time, and conflict/manual-attention counts. This guardrail is not an automatic migration
tool and does not stop, disable, or replace existing `symphony@project.service` instances; operators
must resolve or explicitly account for ownership conflicts before marking a project safe for Hub
management.
Passing `--hub-activation-probe host-service` to the explicit Hub entrypoint enables the first
read-only local probe baseline. It checks the user-level `symphony@<project>.service` status,
legacy project config under `~/.config/symphony/projects/<project>/`, systemd-template env hints,
safe `WORKFLOW.md` / `TRACKER.yaml` summaries, runtime/log/state path ownership, and local listening
Dashboard/API ports, then feeds the sanitized result into the same preflight summary shown in
`/api/v1/state`. Probe failures, unreadable config, unavailable systemd, or unavailable port checks
become per-project `unknown_manual_attention`; they do not crash the Hub tick and do not auto-migrate
or mutate legacy services.
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
`hub_managed`. When the explicit Hub entrypoint also starts the Dashboard/API, `/api/v1/state`
includes `hub_device_observability.overview` for scheduler/tick, project status counts, provider
pressure, capacity/workspace, writeback/manual-attention, activation preflight, lifecycle, and
summary-error counts, plus per-project `detail` blocks for identity, ownership, config snapshot,
poll eligibility, candidate intake, dispatch application, worker start, lifecycle, and writeback
state. The live Dashboard renders the same safe device overview and project detail table only when
that Hub summary is present. This remains an observability surface: it does not replace
`symphony@project.service`, stop/disable/migrate legacy services, or mean Hub has taken over every
provider poll loop.
The same projection now includes `hub_device_observability.migration_readiness`, a migration
readiness report derived only from those safe summaries. The report records Hub runtime mode,
scheduler status, provider/writeback executor mode, worker starter mode, activation probe mode,
project migration-state counts, readiness decisions such as `legacy_only`, `ready_for_dry_run`,
`ready_for_hub_management`, `blocked`, `unknown_manual_attention`, and `already_hub_managed`,
global blocking/advisory risks, per-project blocking/advisory reasons, required operator action
codes, and safe evidence references such as checked times, request/result counts, config
fingerprints, and summary ids. Missing or incompatible project summaries degrade only that project
to `unknown_manual_attention`; the device API and Dashboard continue to render other projects.
It also includes `hub_device_observability.activation_plan`, a read-only activation plan /
acknowledgement summary derived from the same safe readiness evidence. Each project gets a stable
`plan_id`, proposed next state, required acknowledgement action codes, reasons, evidence, and
operator acknowledgement status (`missing`, `accepted`, `stale`, `conflict`, `malformed`,
`unsupported`, or `manual_attention`). Acknowledgements bind to `project_id` plus `plan_id`; when
scope, migration state, executor/probe mode, reason/action codes, or evidence facts change, the old
ack is shown as stale/conflicting instead of being silently reused. Accepted acknowledgement is only
an audit boundary: Hub-owned poll, dispatch, worker start, and real writeback remain guarded by
activation preflight, legacy ownership checks, provider governance, runtime ledger, executor mode,
workspace leases, and lifecycle reconciliation.
The next explicit boundary is `hub_cutover_gate` / `hub_device_observability.cutover_gate`, a
per-project cutover decision consumed before Hub-owned real actions enter their side-effect paths.
It combines the activation plan, operator acknowledgement, readiness decision, activation preflight,
host/service probe, executor/starter modes, scheduler state, provider scope, and project snapshot
into a sanitized decision such as `not_applicable`, `blocked`, `manual_attention`, `staged_ready`,
or `allowed`. The gate reports allowed and blocked operations for `poll`, `dispatch`,
`worker_start`, and `writeback`, plus blocking/advisory reasons, required operator action codes,
safe evidence, and read-only staged ownership records when operations are allowed. Missing, stale,
conflicting, malformed, or unsupported acknowledgement input, unsafe or unknown preflight evidence,
legacy ownership conflicts, executor/starter mode mismatches, and non-`hub_managed` migration state
block only the affected project's Hub-owned real actions. A staged ownership record is audit
evidence for the current inputs only; it is not a database migration transaction and does not modify
legacy services, project config, systemd units, provider state, or `HUB.yaml`.
`hub_cutover_operation_audit` / `hub_device_observability.cutover_operation_audit` adds the
operator-facing dry-run request boundary after the activation plan and cutover gate. A request can be
loaded with `--hub-cutover-operation-request /path/to/request.yaml` or injected by tests/internal
callers. It binds `project_id`, safe provider scope, requested operations (`poll`, `dispatch`,
`worker_start`, `writeback`), current activation plan id/fingerprint, cutover gate decision/staged
record evidence, source, requested time, request fingerprint, safe project snapshot, and only
action/risk codes or a note digest for operator intent. The evaluator returns `would_allow`,
`would_block`, `manual_attention`, or `unsupported` per requested operation, plus reason/action
codes and safe evidence. It is always `dry_run_only`: it does not call providers, start workers,
write runtime ledger pending/attempt/writeback facts, operate systemd, write provider state, or edit
`HUB.yaml`, `WORKFLOW.md`, `TRACKER.yaml`, or project config. Malformed requests, unknown projects,
unknown operations, unsupported sources, and stale plan/gate/staged-record/project evidence are
blocked or require manual attention instead of being treated as current intent. Projects without an
explicit request report `no_request`, so Dashboard/API output does not imply a migration is queued or
running.
`hub_cutover_audit_history` / `hub_device_observability.cutover_audit_history` adds the read-only
history and manual attention closeout baseline on top of that dry-run audit. It folds the current
dry-run audit plus optional recovered history into bounded per-project entries, then evaluates
operator closeouts bound to project, request fingerprint, activation plan/gate fingerprint,
operation, reason/action code, and safe evidence fingerprint. Matching closeouts can mark a blocked
or manual-attention item as closed, deferred, stale, conflicting, malformed, or unsupported for
observability only; they do not override the cutover gate and cannot allow provider I/O, dispatch,
worker start, writeback, systemd changes, or config edits. If request, plan, gate, project, or
evidence fingerprints change, old closeouts show stale/conflict instead of being silently reused.
The API/Dashboard expose counts for history entries, unresolved manual attention, closed, stale,
conflict, malformed, unsupported, and summary errors without full prompts, provider bodies, raw
systemd output, secret env, or local private paths.
`hub_cutover_replay_decision` / `hub_device_observability.cutover_replay_decision` adds the
closeout-aware pre-side-effect replay decision baseline after the execution outcome ledger and
outcome closeout read model. For unresolved `unknown` or `manual_attention` outcomes it binds the
project/provider scope, operation/source, replay key, outcome fingerprint/status, side-effect
entered/may-have-happened semantics, matching closeout fingerprint/resolution/operator request,
current cutover request, readiness permit, execution authorization record, authorization
consumption guard, and safe evidence fingerprints into a serializable decision such as
`no_unresolved_outcome`, `blocked_unresolved_outcome`, `retry_consideration_allowed`,
`retry_consideration_denied`, `stale_closeout`, `conflict`, `manual_attention`, `malformed`, or
`unsupported`. A closeout with `allow_explicit_retry_consideration` only lets the next explicit
execution continue past the old unresolved-outcome replay block after the current consumption guard
is already allowed and all bound evidence still matches. It does not create authorization, consume
authorization, call providers, mutate dispatch/runtime ledgers, start workers, write back, operate
systemd, edit configuration, or take over legacy services; existing provider/runtime/writeback
guardrails still decide whether the explicit action may proceed.
`hub_cutover_readiness_permit` /
`hub_device_observability.cutover_readiness_permit` adds the read-only execution readiness permit
baseline after the gate, dry-run audit, and audit history/closeout summaries. For each explicitly
requested operation it binds the project/provider scope, request fingerprint, activation
plan/acknowledgement fingerprint, cutover gate/staged ownership evidence, dry-run audit decision,
audit history/closeout currentness, executor/starter mode, safe timestamps, and evidence
fingerprints into a stable permit fingerprint and decision such as
`ready_for_execution_consideration`, `blocked`, `stale`, `manual_attention`, `unsupported`, or
`malformed`. A permit becomes ready only when all current evidence still matches and the relevant
mode supports the operation. It is still an audit summary: it does not bypass the cutover gate,
perform provider I/O, dispatch, start workers, write runtime-ledger or provider state, operate
systemd, edit config, or take over legacy services. Projects without an explicit request keep
`no_request`, so Dashboard/API output does not imply migration or execution is queued.
`hub_cutover_execution_authorization_ledger` /
`hub_device_observability.cutover_execution_authorization_ledger` adds the next read-only boundary:
an operator-controlled execution authorization request can be loaded with
`--hub-cutover-execution-authorization-request /path/to/request.yaml`, then the ledger binds that
explicit operation intent to the current readiness permit, cutover request fingerprint, activation
plan/ack fingerprint, cutover gate/staged evidence, dry-run audit, audit-history/closeout
currentness, executor/starter mode, safe timestamps, and evidence fingerprints. Records report
`authorized_for_explicit_execution`, `blocked`, `stale`, `manual_attention`, `unsupported`,
`malformed`, or `no_ready_permit`. Authorization is shown only when the referenced permit is still
`ready_for_execution_consideration` and all bound evidence still matches. The ledger is not an
executor, queue, one-click migration, or legacy service takeover; it does not bypass the gate or
permit and does not call providers, dispatch, start workers, write runtime-ledger/provider state,
operate systemd, or edit config. Without an explicit authorization request it reports request/record
count 0 and does not imply execution is pending.
`hub_cutover_authorization_consumption_guard` /
`hub_device_observability.cutover_authorization_consumption_guard` adds the shared consumption
boundary for explicit Hub cutover execution paths. Real candidate scan, dispatch plan application,
real worker start handoff, and real provider writeback always receive the guard before provider
I/O, runtime-ledger mutation, worker start, or provider writeback, even when the authorization
ledger is empty. Decisions are safe summaries such as
`allowed`, `blocked`, `no_authorization`, `stale`, `manual_attention`, `unsupported`, and
`malformed`, with reason/action codes, source/operation counts, blocked sources, and sanitized
evidence fingerprints. The guard is not an executor, queue, one-click migration, or legacy service
takeover; it does not replace the cutover gate, readiness permit, authorization ledger, activation
preflight, provider governance, runtime ledger, worker starter, or writeback executor. Empty or
non-matching authorization records block as `no_authorization`; snapshots with no real consumption
event report `no_consumption` and do not imply pending migration or execution.
`hub_cutover_execution_outcome_ledger` /
`hub_device_observability.cutover_execution_outcome_ledger` records the next safe audit boundary:
what happened after the authorization consumption guard either blocked the entrypoint or allowed a
real side-effect boundary to run. Outcome facts bind project/provider scope, operation,
side-effect source, cutover request, authorization request/record, readiness permit, gate, dry-run
audit, audit history, consumption guard decision, executor/starter/writeback mode, safe timestamps,
reason/action codes, and sanitized evidence fingerprints. Statuses include `not_executed`,
`blocked`, `succeeded`, `failed`, `retryable`, `unknown`, `manual_attention`, `unsupported`, and
`malformed`, plus safe `side_effect_entered`, `no_side_effects`, and
`side_effect_may_have_happened` semantics. Unresolved `unknown` or `manual_attention` outcomes
block replay of the same explicit operation/request/authorization/source evidence instead of being
silently overwritten as success. The ledger is not a durable execution queue, migration executor,
one-click migration, or legacy service takeover, and it does not replace the gate, permit,
authorization ledger, consumption guard, provider governance, runtime ledger, worker starter, or
writeback executor. Snapshots with no outcome report `no_outcome`, not pending execution.
`hub_cutover_execution_outcome_closeout` /
`hub_device_observability.cutover_execution_outcome_closeout` adds the operator closeout baseline
for unresolved `unknown` or `manual_attention` outcomes. A closeout binds the current project,
provider scope, operation/source, replay key, outcome fingerprint/status, side-effect safety,
cutover request, authorization record, readiness permit, gate/audit/history evidence, consumption
guard fingerprint, safe resolution code, operator request fingerprint, timestamps, and safe
reason/action codes. Matching closeouts can report `resolved` or
`allow_explicit_retry_consideration`, while drift, cross-project/source mismatch, malformed input,
unsupported resolution, or side-effect safety conflict stays visible as `stale`, `conflict`,
`malformed`, or `manual_attention`. Retry consideration is only an audit input for a later explicit run through
permit, authorization, consumption guard, and provider/runtime/writeback guardrails; it never
automatically replays an external side effect or takes over the legacy service. No closeout reports
`no_closeout`, not pending retry.
The Elixir runtime now also has an explicit Hub entrypoint,
`./bin/symphony --hub-config /path/to/HUB.yaml --port <port>`, which loads the registry, builds a
poll plan, can execute one governed candidate-scan poll tick through the Hub provider request
boundary, records poll attempt/result facts, builds a safe `hub_candidate_intake` summary, and
exposes safe Hub fields through `/api/v1/state`, including `hub_dispatch_plan_application` and
`hub_worker_start_handoff` and `hub_worker_lifecycle_reconciliation` runtime-ledger replay summaries
after a plan is applied. When the real writeback executor is explicitly selected, the same payload
also exposes safe writeback mode, operation support, counts, project pressure, and error-category
summaries. The default skeleton executor does not migrate GitHub/GitLab/Linear legacy
adapters, create real workspaces, or start agents; the default start handoff records an unknown
skeleton result instead of launching a worker. Passing `--hub-worker-starter real` explicitly opts
into the first real worker handoff adapter, which starts through the existing worker boundary and
writes the safe ack/failure back to the ledger. Lifecycle reconciliation is likewise driven by a
controlled result source and remains safe-summary based. This entrypoint is opt-in only; the legacy
`--tracker-config TRACKER.yaml WORKFLOW.md` startup path and per-project services stay unchanged.
For a local activation dry run, use
`./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --hub-config /path/to/HUB.yaml --hub-activation-probe host-service --port <port>`
and inspect `hub_activation_preflight`,
`hub_device_observability.migration_readiness`,
`hub_device_observability.activation_plan`, `hub_cutover_gate`,
`hub_device_observability.cutover_gate`, `hub_cutover_operation_audit`,
`hub_device_observability.cutover_operation_audit`, `hub_cutover_audit_history`,
`hub_device_observability.cutover_audit_history`, `hub_cutover_readiness_permit`,
`hub_device_observability.cutover_readiness_permit`, `hub_cutover_execution_authorization_ledger`,
`hub_device_observability.cutover_execution_authorization_ledger`,
`hub_cutover_authorization_consumption_guard`,
`hub_device_observability.cutover_authorization_consumption_guard`,
`hub_cutover_execution_outcome_ledger`, and
`hub_device_observability.cutover_execution_outcome_ledger`, and the Dashboard Hub sections in
`/api/v1/state`.
If an operator wants to record a non-executing acknowledgement, pass
`--hub-activation-ack /path/to/ack.yaml`; the file is parsed into the safe summary and does not
trigger migration or config edits.
For a read-only dry-run baseline, keep provider/writeback executors and worker starter in skeleton
mode, set projects to `legacy_only` or `hub_ready` in `HUB.yaml`, enable the host-service probe, and
resolve readiness actions before changing any project to `hub_managed`. `legacy_only` means Hub is
only observing a legacy-owned project; `hub_ready` means the project can be evaluated for dry-run or
future management; `hub_managed` means Hub-owned actions are allowed only after activation
preflight is safe, acknowledgement still matches the activation plan, and the cutover gate allows
the specific operation. Stopping/disabling legacy `symphony@<project>.service`, resolving unknown
writeback/manual-attention items, confirming real provider/writeback/worker modes, and changing
project ownership remain manual operator decisions. This command gathers evidence only and does not
stop, disable, restart, delete, modify `HUB.yaml`, modify project config, or migrate
`symphony@<project>.service`.
Passing `--hub-scheduler` adds the first opt-in Hub-owned tick loop baseline: startup and completed
ticks schedule the next safe refresh from the Hub poll plan, provider backoff, and unresolved
runtime-ledger lifecycle state, and `/refresh` coalesces with a running or queued tick instead of
starting a concurrent one. This scheduler summary is exposed as `hub_scheduler` and
`hub_runtime.scheduler`; it is still not the final durable Hub scheduler, provider writeback
executor, distributed lock, or migration of existing `symphony@project.service` instances.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
