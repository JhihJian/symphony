#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/install-systemd-template.sh --project <name> --owner <github-owner> --repo <github-repo> --project-number <n> [options]

Options:
  --project <name>          Local Symphony instance name, e.g. symphony or project-a.
  --owner <owner>           GitHub owner or organization.
  --repo <repo>             GitHub repository name.
  --project-number <n>      GitHub Project v2 number.
  --token <token>           GitHub token. If omitted, GITHUB_TOKEN from env is used; otherwise an existing env token is kept.
  --port <port>             Dashboard/API port. If omitted, the next free configured port from 20000 is used.
  --repo-url <url>          Repository URL used by hooks.after_create. Default: https://github.com/<owner>/<repo>
  --config-root <path>      Config root. Default: $HOME/.config/symphony/projects
  --runtime-root <path>     Runtime root. Default: $HOME/.codex/symphony/projects
  --source-root <path>      Symphony source root. Default: $HOME/.codex/symphony.
  --source-repo-url <url>   Symphony source repository. Default: https://github.com/jhihjian/symphony.
  --source-branch <name>    Symphony source branch. Default: main.
  --host <host>             Dashboard bind host. Default: 0.0.0.0.
  --label <label>           Required issue label. May be repeated. Default: symphony.
  --active-state <state>    Active Project v2 status. May be repeated. Default: Ready, In progress.
  --terminal-state <state>  Terminal Project v2 status. May be repeated. Default: Done.
  --max-agents <n>          Maximum concurrent agents for this instance. Default: 2.
  --skip-build              Do not run mix setup/build when bin/symphony is missing.
  --auto-update             Install and enable symphony-update.timer.
  --update-calendar <spec>  systemd OnCalendar value for auto update. Default: daily.
  --no-auto-update          Disable symphony-update.timer if it exists.
  --update-strategy <name>  Dashboard auto-update strategy. Default: idle_restart.
  --no-systemd              Write files only; skip systemctl commands.
  --no-start                Do not enable/start the instance.
  -h, --help                Show this help.

Example:
  scripts/install-systemd-template.sh \
    --project project-a \
    --owner acme \
    --repo webapp \
    --project-number 3 \
    --port 20001 \
    --token "$GITHUB_TOKEN"
USAGE
}

project=""
owner=""
repo=""
project_number=""
github_token="${GITHUB_TOKEN:-}"
port=""
repo_url=""
source_repo_url="${SYMPHONY_SOURCE_REPO_URL:-https://github.com/jhihjian/symphony}"
source_branch="${SYMPHONY_SOURCE_BRANCH:-main}"
default_source_root="$HOME/.codex/symphony"
config_root="$HOME/.config/symphony/projects"
runtime_root="$HOME/.codex/symphony/projects"
source_root="$default_source_root"
host="0.0.0.0"
max_agents="2"
start_service=1
skip_build=0
auto_update=""
update_calendar="daily"
update_strategy=""
run_systemd=1
labels=()
active_states=()
terminal_states=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      project="${2:?missing value for --project}"
      shift 2
      ;;
    --owner)
      owner="${2:?missing value for --owner}"
      shift 2
      ;;
    --repo)
      repo="${2:?missing value for --repo}"
      shift 2
      ;;
    --project-number)
      project_number="${2:?missing value for --project-number}"
      shift 2
      ;;
    --token)
      github_token="${2:?missing value for --token}"
      shift 2
      ;;
    --port)
      port="${2:?missing value for --port}"
      shift 2
      ;;
    --repo-url)
      repo_url="${2:?missing value for --repo-url}"
      shift 2
      ;;
    --config-root)
      config_root="${2:?missing value for --config-root}"
      shift 2
      ;;
    --runtime-root)
      runtime_root="${2:?missing value for --runtime-root}"
      shift 2
      ;;
    --source-root)
      source_root="${2:?missing value for --source-root}"
      shift 2
      ;;
    --source-repo-url)
      source_repo_url="${2:?missing value for --source-repo-url}"
      shift 2
      ;;
    --source-branch)
      source_branch="${2:?missing value for --source-branch}"
      shift 2
      ;;
    --host)
      host="${2:?missing value for --host}"
      shift 2
      ;;
    --label)
      labels+=("${2:?missing value for --label}")
      shift 2
      ;;
    --active-state)
      active_states+=("${2:?missing value for --active-state}")
      shift 2
      ;;
    --terminal-state)
      terminal_states+=("${2:?missing value for --terminal-state}")
      shift 2
      ;;
    --max-agents)
      max_agents="${2:?missing value for --max-agents}"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --auto-update)
      auto_update=1
      shift
      ;;
    --update-calendar)
      update_calendar="${2:?missing value for --update-calendar}"
      shift 2
      ;;
    --no-auto-update)
      auto_update=0
      shift
      ;;
    --update-strategy)
      update_strategy="${2:?missing value for --update-strategy}"
      shift 2
      ;;
    --no-systemd)
      run_systemd=0
      start_service=0
      shift
      ;;
    --no-start)
      start_service=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_value() {
  local name="$1"
  local value="$2"

  if [ -z "$value" ]; then
    echo "Missing required option: --$name" >&2
    usage >&2
    exit 2
  fi
}

require_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "--$name must be a positive integer: $value" >&2
    exit 2
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required." >&2
    exit 1
  fi
}

ensure_projects_excluded() {
  local git_dir
  local exclude_file

  git_dir="$(git -C "$source_root" rev-parse --git-dir)"
  if [[ "$git_dir" != /* ]]; then
    git_dir="${source_root%/}/${git_dir}"
  fi

  exclude_file="${git_dir%/}/info/exclude"
  mkdir -p "$(dirname "$exclude_file")"

  if ! grep -qxF "/projects/" "$exclude_file" 2>/dev/null; then
    printf "\n# Symphony runtime directories\n/projects/\n" >> "$exclude_file"
  fi
}

clone_into_existing_root() {
  local clone_parent
  local clone_tmp
  local path

  clone_parent="$(dirname "$source_root")"
  clone_tmp="$(mktemp -d "${clone_parent%/}/.symphony-clone.XXXXXX")"

  git clone --branch "$source_branch" --single-branch "$source_repo_url" "$clone_tmp"

  for path in "$clone_tmp"/.[!.]* "$clone_tmp"/..?* "$clone_tmp"/*; do
    [ -e "$path" ] || continue
    mv "$path" "$source_root"/
  done

  rmdir "$clone_tmp"
}

ensure_source_root() {
  require_command git

  if [ ! -e "$source_root" ]; then
    mkdir -p "$(dirname "$source_root")"
    git clone --branch "$source_branch" --single-branch "$source_repo_url" "$source_root"
  elif git -C "$source_root" rev-parse --git-dir >/dev/null 2>&1; then
    :
  elif [ -d "$source_root" ] && [ -z "$(find "$source_root" -mindepth 1 -maxdepth 1 ! -name projects -print -quit)" ]; then
    mkdir -p "$source_root"
    clone_into_existing_root
  else
    echo "Symphony source root exists but is not a Git repository: ${source_root}" >&2
    echo "Move it away, or pass --source-root <path>." >&2
    exit 1
  fi

  source_root="$(cd "$source_root" && pwd -P)"
  ensure_projects_excluded

  if [ -n "$(git -C "$source_root" status --porcelain -- . ':(exclude)projects')" ]; then
    echo "Refusing to update Symphony source because it has local changes: ${source_root}" >&2
    git -C "$source_root" status --short -- . ':(exclude)projects' >&2
    exit 1
  fi

  git -C "$source_root" fetch origin "$source_branch"
  git -C "$source_root" checkout "$source_branch"
  git -C "$source_root" pull --ff-only origin "$source_branch"
}

require_value project "$project"
require_value owner "$owner"
require_value repo "$repo"
require_value project-number "$project_number"
require_integer project-number "$project_number"
require_integer max-agents "$max_agents"

if ! [[ "$project" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "--project may only contain letters, numbers, '.', '_' and '-': $project" >&2
  exit 2
fi

if [ "${#labels[@]}" -eq 0 ]; then
  labels=("symphony")
fi

if [ "${#active_states[@]}" -eq 0 ]; then
  active_states=("Ready" "In progress")
fi

if [ "${#terminal_states[@]}" -eq 0 ]; then
  terminal_states=("Done")
fi

if [ -z "$repo_url" ]; then
  repo_url="https://github.com/${owner}/${repo}"
fi

ensure_source_root

mkdir -p "$config_root" "$runtime_root"
config_root="$(cd "$config_root" && pwd)"
runtime_root="$(cd "$runtime_root" && pwd)"

app_dir="${source_root%/}/elixir"
project_config_dir="${config_root%/}/${project}"
project_runtime_dir="${runtime_root%/}/${project}"
logs_root="${project_runtime_dir}/logs"
workspace_root="${project_runtime_dir}/workspaces"
systemd_user_dir="$HOME/.config/systemd/user"
unit_file="${systemd_user_dir}/symphony@.service"
update_service_file="${systemd_user_dir}/symphony-update.service"
update_timer_file="${systemd_user_dir}/symphony-update.timer"
update_script="${source_root%/}/scripts/update-systemd-template.sh"

if [ -z "$port" ] && [ -f "${project_config_dir}/env" ]; then
  existing_port="$(sed -n 's/^SYMPHONY_PORT=//p' "${project_config_dir}/env" | head -n 1)"
  if [ -n "$existing_port" ]; then
    port="$existing_port"
  fi
fi

if [ -z "$port" ]; then
  port="20000"

  if [ -d "$config_root" ]; then
    while grep -Rqs "^SYMPHONY_PORT=${port}$" "$config_root"; do
      port=$((port + 1))
    done
  fi
fi

require_integer port "$port"

if [ ! -d "$app_dir" ]; then
  echo "Symphony app directory not found: ${app_dir}" >&2
  echo "Check --source-root, --source-repo-url, and --source-branch." >&2
  exit 1
fi

if [ ! -x "$update_script" ]; then
  echo "Symphony update script not found or not executable: ${update_script}" >&2
  exit 1
fi

if [ -z "$github_token" ] && [ -f "${project_config_dir}/env" ]; then
  existing_github_token="$(sed -n 's/^GITHUB_TOKEN=//p' "${project_config_dir}/env" | head -n 1)"
  if [ -n "$existing_github_token" ]; then
    github_token="$existing_github_token"
  fi
fi

if [ -z "$update_strategy" ] && [ -f "${project_config_dir}/env" ]; then
  existing_update_strategy="$(sed -n 's/^SYMPHONY_UPDATE_STRATEGY=//p' "${project_config_dir}/env" | head -n 1)"
  if [ -n "$existing_update_strategy" ]; then
    update_strategy="$existing_update_strategy"
  fi
fi

if [ -z "$update_strategy" ]; then
  update_strategy="idle_restart"
fi

case "$update_strategy" in
  idle_restart|defer_until_idle|download_only|manual_restart|force_restart)
    ;;
  *)
    echo "Unsupported --update-strategy: ${update_strategy}" >&2
    echo "Use one of: idle_restart, defer_until_idle, download_only, manual_restart, force_restart" >&2
    exit 2
    ;;
esac

if [ ! -x "${app_dir}/bin/symphony" ]; then
  if [ "$skip_build" -eq 1 ]; then
    echo "Symphony binary not found or not executable: ${app_dir}/bin/symphony" >&2
    echo "Run this first: cd ${app_dir} && mise exec -- mix setup && mise exec -- mix build" >&2
    exit 1
  fi

  if ! command -v mise >/dev/null 2>&1; then
    echo "mise is required to build missing Symphony binary: ${app_dir}/bin/symphony" >&2
    exit 1
  fi

  (
    cd "$app_dir"
    mise trust
    mise exec -- mix setup
    mise exec -- mix build
  )
fi

mkdir -p "$project_config_dir" "$logs_root" "$workspace_root" "$systemd_user_dir"

cat > "$unit_file" <<UNIT
[Unit]
Description=Symphony orchestration service (%i)
Documentation=file:${app_dir}/README.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${app_dir}
Environment=SYMPHONY_PROJECT=%i
EnvironmentFile=${config_root}/%i/env
ExecStart=%h/.local/bin/mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --logs-root \${SYMPHONY_LOGS_ROOT} --port \${SYMPHONY_PORT} ${config_root}/%i/WORKFLOW.md
Restart=on-failure
RestartSec=10
KillSignal=SIGINT
TimeoutStopSec=30

[Install]
WantedBy=default.target
UNIT

cat > "${project_config_dir}/env" <<ENV
# Required scopes: repo plus read:project/write:project for GitHub Project v2.
GITHUB_TOKEN=${github_token}

SYMPHONY_PORT=${port}
SYMPHONY_LOGS_ROOT=${logs_root}
SYMPHONY_UPDATE_STRATEGY=${update_strategy}
ENV
chmod 600 "${project_config_dir}/env"

write_yaml_list() {
  local indent="$1"
  shift
  local item

  for item in "$@"; do
    printf "%*s- %s\n" "$indent" "" "$item"
  done
}

{
  cat <<EOF
---
tracker:
  kind: github
  owner: ${owner}
  repo: ${repo}
  project_number: ${project_number}
  project_status_field_name: Status
  required_labels:
EOF
  write_yaml_list 4 "${labels[@]}"
  cat <<EOF
  active_states:
EOF
  write_yaml_list 4 "${active_states[@]}"
  cat <<EOF
  terminal_states:
EOF
  write_yaml_list 4 "${terminal_states[@]}"
  cat <<EOF
polling:
  interval_ms: 30000
server:
  host: ${host}
workspace:
  root: ${workspace_root}
hooks:
  after_create: |
    git clone --depth 1 ${repo_url} .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: ${max_agents}
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

你正在处理 GitHub Project v2 中的 Issue \`{{ issue.identifier }}\`。

Issue 信息：

- ID: \`{{ issue.id }}\`
- Tracker: \`{{ issue.tracker_kind }}\`
- 标题: \`{{ issue.title }}\`
- 当前状态: \`{{ issue.state }}\`
- 标签: \`{{ issue.labels }}\`
- URL: \`{{ issue.url }}\`
- PR Issue Reference: \`{{ issue.closing_reference }}\`

{{ issue.closing_instruction }}

Issue 描述：
{% if issue.description %}
{{ issue.description }}
{% else %}
无描述。
{% endif %}

工作要求：

1. 这是无人值守的 Symphony 编排任务，不要要求人工执行后续动作。
2. 只在缺少必要权限、密钥或外部服务不可用时停止。
3. 只在当前 workspace 内工作，不要修改 workspace 外的路径。
4. 开始后先用 \`github_issue\` 工具读取 issue 和评论，维护一个标题为 \`## Codex Workpad\` 的持久评论。
5. 执行前在 workpad 里记录计划、验收标准和验证方式。
6. 变更完成后运行与改动范围匹配的验证命令。
7. 如需提交代码，创建清晰的 commit，并使用 \`github_pr\` 工具创建 PR。PR 描述必须包含 \`Issue: {{ issue.closing_reference }}\`，以便 GitHub 关联 PR 并在合并后自动关闭 Issue。
8. 需要变更任务状态时，使用 \`github_issue\` 的 \`set_status\` 操作更新 GitHub Project v2 的 \`Status\` 字段。
9. 最终在 workpad 中记录完成摘要、验证结果、commit 和 PR 链接。
EOF
} > "${project_config_dir}/WORKFLOW.md"
chmod 644 "${project_config_dir}/WORKFLOW.md"

if [ "$auto_update" = "1" ]; then
  cat > "$update_service_file" <<UNIT
[Unit]
Description=Update Symphony program and restart template instances
Documentation=file:${source_root}/DEPLOY.md
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${source_root}
ExecStart=${update_script} --source-root ${source_root} --branch ${source_branch} --all
UNIT

  cat > "$update_timer_file" <<UNIT
[Unit]
Description=Run Symphony automatic update

[Timer]
OnCalendar=${update_calendar}
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
UNIT
elif [ "$auto_update" = "0" ]; then
  if [ "$run_systemd" -eq 1 ]; then
    systemctl --user disable --now symphony-update.timer 2>/dev/null || true
  fi
fi

if [ "$run_systemd" -eq 1 ]; then
  systemctl --user daemon-reload
fi

if [ "$run_systemd" -eq 1 ] && [ "$start_service" -eq 1 ]; then
  systemctl --user enable --now "symphony@${project}.service"
fi

if [ "$run_systemd" -eq 1 ] && [ "$auto_update" = "1" ]; then
  systemctl --user enable --now symphony-update.timer
fi

cat <<EOF
Installed Symphony project instance: ${project}

Service:
  symphony@${project}.service

Files:
  ${project_config_dir}/env
  ${project_config_dir}/WORKFLOW.md

Runtime:
  ${logs_root}
  ${workspace_root}

Dashboard:
  http://${host}:${port}/

Commands:
  systemctl --user status symphony@${project}.service --no-pager
  journalctl --user -u symphony@${project}.service -f
EOF

if [ "$auto_update" = "1" ]; then
  cat <<EOF

Auto update:
  symphony-update.timer (${update_calendar})
  systemctl --user list-timers symphony-update.timer --no-pager
  journalctl --user -u symphony-update.service --no-pager
EOF
elif [ "$auto_update" = "0" ]; then
  cat <<EOF

Auto update:
  symphony-update.timer disabled
EOF
fi

if [ -z "$github_token" ]; then
  cat <<EOF

GITHUB_TOKEN is empty. Fill it before starting:
  \$EDITOR ${project_config_dir}/env
  systemctl --user restart symphony@${project}.service
EOF
fi
