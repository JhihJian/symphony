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
dispatch is revalidated against the provider-visible stage before a worker is spawned. The stage
contract is implemented for Memory, Linear workflow states, GitHub Project v2 Status, and GitLab
scoped labels. GitHub issues-only mode fails fast for multi-stage provider-visible workflow state.
Legacy `WORKFLOW.md` tracker front matter is rejected at runtime; migrate to the split
`WORKFLOW.md` plus `TRACKER.yaml` layout before starting the service.

When the Elixir observability server is enabled, `/workflow` provides a read-only workflow-stage
visualization. It renders the current `WORKFLOW.md` stages and transitions, summarizes
`TRACKER.yaml` stage-state coverage without exposing credentials, and overlays available runtime
stage counts from the local orchestrator snapshot.

The Elixir implementation also includes the first Hub mode model baseline for the #74 direction.
`HUB.yaml` can register multiple projects, each pointing at its own `WORKFLOW.md` and optional
`TRACKER.yaml`; the Hub loader builds stable project identities, safe configuration snapshots, and
provider-neutral issue references. This is not a Hub scheduler yet: without explicit Hub usage,
the existing single-project startup, polling, workspace, and agent dispatch behavior remains
unchanged.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
