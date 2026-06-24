#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/update-systemd-template.sh [options]

Options:
  --source-root <path>  Symphony source root. Default: repository root inferred from this script.
  --branch <name>       Git branch to fast-forward. Default: main.
  --project <name>      Restart one symphony@<project>.service instance after update. May be repeated.
  --all                 Restart all enabled/running symphony@*.service instances after update. Default.
  --no-restart          Update and build only; do not restart systemd instances.
  -h, --help            Show this help.

Default behavior:
  Fast-forward the Symphony repository, rebuild elixir/bin/symphony only when code changed,
  then restart all enabled/running symphony@<project>.service instances.
USAGE
}

script_path="${BASH_SOURCE[0]}"
if [[ "$script_path" != */* ]]; then
  script_path="$(command -v -- "$script_path")"
fi
script_dir="$(cd "$(dirname "$script_path")" && pwd -P)"
source_root="$(cd "${script_dir}/.." && pwd -P)"
source_branch="${SYMPHONY_SOURCE_BRANCH:-main}"
restart_all=1
restart_services=()
restart_instances=1

configure_user_systemd_bus() {
  local runtime_dir
  runtime_dir="/run/user/$(id -u)"

  if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "$runtime_dir" ]; then
    export XDG_RUNTIME_DIR="$runtime_dir"
  fi

  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "${XDG_RUNTIME_DIR:-}/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-root)
      source_root="${2:?missing value for --source-root}"
      shift 2
      ;;
    --branch)
      source_branch="${2:?missing value for --branch}"
      shift 2
      ;;
    --project)
      project="${2:?missing value for --project}"
      if ! [[ "$project" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "--project may only contain letters, numbers, '.', '_' and '-': $project" >&2
        exit 2
      fi
      restart_services+=("symphony@${project}.service")
      restart_all=0
      shift 2
      ;;
    --all)
      restart_all=1
      restart_services=()
      shift
      ;;
    --no-restart)
      restart_instances=0
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

if [ ! -d "$source_root" ]; then
  echo "Symphony source root not found: ${source_root}" >&2
  exit 1
fi

source_root="$(cd "$source_root" && pwd -P)"
app_dir="${source_root%/}/elixir"
build_revision_file="${app_dir}/_build/symphony.build-revision"

if [ ! -d "${source_root}/.git" ] && ! git -C "$source_root" rev-parse --git-dir >/dev/null 2>&1; then
  echo "Symphony source root is not a Git repository: ${source_root}" >&2
  exit 1
fi

if [ ! -d "$app_dir" ]; then
  echo "Symphony app directory not found: ${app_dir}" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required for Symphony updates." >&2
  exit 1
fi

if ! command -v mise >/dev/null 2>&1; then
  echo "mise is required to build Symphony." >&2
  exit 1
fi

configure_user_systemd_bus

git_dir="$(git -C "$source_root" rev-parse --git-dir)"
if [[ "$git_dir" != /* ]]; then
  git_dir="${source_root%/}/${git_dir}"
fi

exclude_file="${git_dir%/}/info/exclude"
mkdir -p "$(dirname "$exclude_file")"

if ! grep -qxF "/projects/" "$exclude_file" 2>/dev/null; then
  printf "\n# Symphony runtime directories\n/projects/\n" >> "$exclude_file"
fi

if [ -n "$(git -C "$source_root" status --porcelain -- . ':(exclude)projects')" ]; then
  echo "Refusing to update because the Symphony repository has local changes: ${source_root}" >&2
  git -C "$source_root" status --short -- . ':(exclude)projects' >&2
  exit 1
fi

before_revision="$(git -C "$source_root" rev-parse HEAD)"
git -C "$source_root" fetch origin "$source_branch"
git -C "$source_root" checkout "$source_branch"
git -C "$source_root" pull --ff-only origin "$source_branch"
after_revision="$(git -C "$source_root" rev-parse HEAD)"
build_revision=""
if [ -f "$build_revision_file" ]; then
  build_revision="$(tr -d '[:space:]' < "$build_revision_file")"
fi

if [ "$before_revision" = "$after_revision" ] && [ -x "${app_dir}/bin/symphony" ] && [ "$build_revision" = "$after_revision" ]; then
  echo "Symphony is already up to date at ${after_revision}."
  exit 0
fi

(
  cd "$app_dir"
  mise trust
  mise exec -- mix setup
  mise exec -- mix build
  mkdir -p "$(dirname "$build_revision_file")"
  printf '%s\n' "$after_revision" > "$build_revision_file"
)

if [ "$restart_instances" -eq 0 ]; then
  echo "Updated Symphony from ${before_revision} to ${after_revision}; restart skipped."
  exit 0
fi

if [ "$restart_all" -eq 1 ]; then
  mapfile -t restart_services < <(
    {
      systemctl --user list-units 'symphony@*.service' --all --no-legend --no-pager 2>/dev/null | awk '{ print $1 }' || true
      if [ -d "$HOME/.config/systemd/user" ]; then
        find "$HOME/.config/systemd/user" -type l -name 'symphony@*.service' -printf '%f\n'
      fi
    } | awk '/^symphony@.+\.service$/ { print }' | sort -u
  )
fi

if [ "${#restart_services[@]}" -eq 0 ]; then
  echo "Updated Symphony from ${before_revision} to ${after_revision}; no symphony@ instances found to restart."
  exit 0
fi

systemctl --user daemon-reload

for service in "${restart_services[@]}"; do
  systemctl --user restart "$service"
done

cat <<EOF
Updated Symphony:
  from: ${before_revision}
  to:   ${after_revision}

Restarted:
$(printf '  %s\n' "${restart_services[@]}")
EOF
