#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/uninstall-systemd-template.sh --project <name> [options]

Options:
  --project <name>       Local Symphony instance name to uninstall.
  --config-root <path>   Config root. Default: $HOME/.config/symphony/projects.
  --runtime-root <path>  Runtime root. Default: $HOME/.codex/symphony/projects.
  --purge-config         Delete ~/.config/symphony/projects/<project>.
  --purge-runtime        Delete $HOME/.codex/symphony/projects/<project>.
  --purge-all            Delete both config and runtime directories.
  --remove-template      Remove ~/.config/systemd/user/symphony@.service if no instances remain.
  --remove-auto-update   Remove symphony-update.service/timer if no instances remain.
  --no-systemd           Delete files only; skip systemctl commands.
  -h, --help             Show this help.

Default behavior:
  Stop and disable symphony@<project>.service, then keep config, logs, and workspaces.

Example:
  scripts/uninstall-systemd-template.sh --project project-a
  scripts/uninstall-systemd-template.sh --project project-a --purge-all
USAGE
}

project=""
config_root="$HOME/.config/symphony/projects"
runtime_root="$HOME/.codex/symphony/projects"
purge_config=0
purge_runtime=0
remove_template=0
remove_auto_update=0
run_systemd=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      project="${2:?missing value for --project}"
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
    --purge-config)
      purge_config=1
      shift
      ;;
    --purge-runtime)
      purge_runtime=1
      shift
      ;;
    --purge-all)
      purge_config=1
      purge_runtime=1
      shift
      ;;
    --remove-template)
      remove_template=1
      shift
      ;;
    --remove-auto-update)
      remove_auto_update=1
      shift
      ;;
    --no-systemd)
      run_systemd=0
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

if [ -z "$project" ]; then
  echo "Missing required option: --project" >&2
  usage >&2
  exit 2
fi

if ! [[ "$project" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "--project may only contain letters, numbers, '.', '_' and '-': $project" >&2
  exit 2
fi

service="symphony@${project}.service"
project_config_dir="${config_root%/}/${project}"
project_runtime_dir="${runtime_root%/}/${project}"
unit_file="$HOME/.config/systemd/user/symphony@.service"
update_service_file="$HOME/.config/systemd/user/symphony-update.service"
update_timer_file="$HOME/.config/systemd/user/symphony-update.timer"

if [ "$run_systemd" -eq 1 ]; then
  systemctl --user stop "$service" 2>/dev/null || true
  systemctl --user disable "$service" 2>/dev/null || true
  systemctl --user reset-failed "$service" 2>/dev/null || true
fi

if [ "$purge_config" -eq 1 ]; then
  rm -rf "$project_config_dir"
fi

if [ "$purge_runtime" -eq 1 ]; then
  rm -rf "$project_runtime_dir"
fi

if [ "$remove_template" -eq 1 ]; then
  running_units="$(
    if [ "$run_systemd" -eq 1 ]; then
      systemctl --user list-units 'symphony@*.service' --no-legend --no-pager |
        awk '{ print $1 }'
    fi
  )"

  remaining_projects=""
  if [ -d "$config_root" ]; then
    remaining_projects="$(find "$config_root" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  fi

  if [ -z "$remaining_projects" ] && [ -z "$running_units" ]; then
    rm -f "$unit_file"
  else
    echo "Template kept because other symphony@ instances still exist." >&2
  fi
fi

if [ "$remove_auto_update" -eq 1 ]; then
  running_units="$(
    if [ "$run_systemd" -eq 1 ]; then
      systemctl --user list-units 'symphony@*.service' --no-legend --no-pager |
        awk '{ print $1 }'
    fi
  )"

  remaining_projects=""
  if [ -d "$config_root" ]; then
    remaining_projects="$(find "$config_root" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  fi

  if [ -z "$remaining_projects" ] && [ -z "$running_units" ]; then
    if [ "$run_systemd" -eq 1 ]; then
      systemctl --user disable --now symphony-update.timer 2>/dev/null || true
    fi
    rm -f "$update_service_file" "$update_timer_file"
  else
    echo "Auto-update timer kept because other symphony@ instances still exist." >&2
  fi
fi

if [ "$run_systemd" -eq 1 ]; then
  systemctl --user daemon-reload
fi

cat <<EOF
Uninstalled Symphony project instance: ${project}

Stopped/disabled:
  ${service}

Config:
  ${project_config_dir} $(if [ "$purge_config" -eq 1 ]; then echo "(deleted)"; else echo "(kept)"; fi)

Runtime:
  ${project_runtime_dir} $(if [ "$purge_runtime" -eq 1 ]; then echo "(deleted)"; else echo "(kept)"; fi)
EOF
