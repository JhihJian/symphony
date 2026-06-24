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
contract is implemented for the Memory tracker in this step; real Linear/GitHub/GitLab provider
stage mappings remain follow-up provider work. The legacy single-file tracker state model remains
only as a temporary compatibility path and will be removed by follow-up #45 cleanup work.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
