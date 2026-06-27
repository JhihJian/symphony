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
observability snapshots. `SymphonyElixir.Hub.DispatchBoundary` adds the next #74 baseline from
candidate issue to active run intent: it model-checks `project_id + IssueRef` claims, attempt ids,
workspace leases, start intents, worker start acknowledgements, failure states, and safe run context
snapshots. It is still not a provider executor or full Hub scheduler: without explicit Hub usage,
the existing single-project startup, polling, workspace, provider calls, and agent dispatch behavior
remains unchanged.
The latest Hub provider tool/writeback routing baseline adds an opt-in boundary for structured
dynamic tool provider calls: GitHub issue, GitHub PR, and provider-neutral tracker issue tools can
construct safe `ProviderGovernance` requests, execute through an injectable boundary, and return
sanitized request/result/writeback summaries. This is still a migration seam only; legacy
single-project provider calls remain direct unless a caller explicitly opts into the Hub routing
boundary.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
