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

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

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
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - For Linear, `tracker.project_slug` is the Linear project slug from the project URL.
   - For GitLab, `tracker.project_slug` is the GitLab project path such as `group/project`, or a
     numeric project ID.
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
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
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
---

You are working on an issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` supports `linear`, `github`, `gitlab`, and `memory`.
- Linear uses `tracker.project_slug` and defaults to `https://api.linear.app/graphql`.
- GitHub uses `tracker.owner` and `tracker.repo`; `tracker.project_number` is optional. When it is
  present, GitHub Project v2 status is used for issue state. When it is omitted, GitHub `OPEN` maps
  to the first configured active state and `CLOSED` maps to the first configured terminal state.
- GitLab uses `tracker.project_slug` as the project path or ID and defaults to
  `https://gitlab.com/api/v4`. GitLab `opened` maps to the first configured active state and
  `closed` maps to the first configured terminal state.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
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
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
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
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.
- The same Phoenix service also exposes an operator-only multi-instance management surface at
  `/admin/instances`, `/api/v1/admin/instances*`, and `/api/v1/admin/auto-update*`. It discovers
  independently deployed `symphony@<project>.service` instances from the systemd-template config
  directory plus user-level systemd units, and does not change the single-instance orchestrator
  scheduling model.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

The single-instance dashboard at `/` is the execution dashboard for the current Symphony process:
it shows the local orchestrator snapshot, running/retrying/blocked issues, token totals, and issue
detail links.

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

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

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
