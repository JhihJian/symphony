#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/install-hub-systemd-service.sh [options]

Options:
  --hub-config <path>       Hub registry config. Default: $HOME/.config/symphony/hub/HUB.yaml.
  --port <port>             Hub Dashboard/API port. Default: 21000.
  --host <host>             Hub Dashboard/API bind host. Default: 0.0.0.0.
  --logs-root <path>        Hub logs root. Default: $HOME/.codex/symphony/projects/hub/logs.
  --source-root <path>      Symphony source root. Default: $HOME/.codex/symphony.
  --service-name <name>     User systemd service name. Default: symphony-hub.service.
  --skip-build              Do not run mix setup/build when bin/symphony is missing.
  --no-systemd              Write unit/env files only; skip systemctl commands.
  --no-start                Do not enable/start the service.
  -h, --help                Show this help.

The installed service is a Hub observability sidecar. It does not enable
--hub-scheduler, real provider executors, real worker starter, writeback, or
legacy service takeover.
USAGE
}

hub_config="$HOME/.config/symphony/hub/HUB.yaml"
port="21000"
host="0.0.0.0"
logs_root="$HOME/.codex/symphony/projects/hub/logs"
source_root="${SYMPHONY_SOURCE_ROOT:-$HOME/.codex/symphony}"
service_name="symphony-hub.service"
skip_build=0
run_systemd=1
start_service=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --hub-config)
      hub_config="${2:?missing value for --hub-config}"
      shift 2
      ;;
    --port)
      port="${2:?missing value for --port}"
      shift 2
      ;;
    --host)
      host="${2:?missing value for --host}"
      shift 2
      ;;
    --logs-root)
      logs_root="${2:?missing value for --logs-root}"
      shift 2
      ;;
    --source-root)
      source_root="${2:?missing value for --source-root}"
      shift 2
      ;;
    --service-name)
      service_name="${2:?missing value for --service-name}"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --no-systemd)
      run_systemd=0
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
      exit 1
      ;;
  esac
done

case "$service_name" in
  */*)
    echo "--service-name must not contain a slash" >&2
    exit 1
    ;;
  *.service)
    ;;
  *)
    service_name="${service_name}.service"
    ;;
esac

case "$port" in
  ''|*[!0-9]*)
    echo "--port must be a non-negative integer" >&2
    exit 1
    ;;
esac

if [ -z "${host// }" ]; then
  echo "--host must not be blank" >&2
  exit 1
fi

if [ ! -f "$hub_config" ]; then
  echo "Hub config file not found: $hub_config" >&2
  exit 1
fi

source_root="${source_root%/}"
app_dir="${source_root}/elixir"
systemd_user_dir="$HOME/.config/systemd/user"
unit_file="${systemd_user_dir}/${service_name}"
hub_config_dir="$(dirname "$hub_config")"
env_file="${hub_config_dir}/env"

if [ ! -d "$app_dir" ]; then
  echo "Symphony Elixir app directory not found: $app_dir" >&2
  exit 1
fi

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

mkdir -p "$logs_root" "$hub_config_dir" "$systemd_user_dir"

{
  printf 'SYMPHONY_HUB_CONFIG=%s\n' "$hub_config"
  printf 'SYMPHONY_HUB_LOGS_ROOT=%s\n' "$logs_root"
  printf 'SYMPHONY_HUB_HOST=%s\n' "$host"
  printf 'SYMPHONY_HUB_PORT=%s\n' "$port"
  printf 'SYMPHONY_HUB_ACTIVATION_PROBE=host-service\n'
} > "$env_file"
chmod 600 "$env_file"

cat > "$unit_file" <<UNIT
[Unit]
Description=Symphony Hub observability sidecar
Documentation=file:${app_dir}/README.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${app_dir}
EnvironmentFile=${env_file}
ExecStart=%h/.local/bin/mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --logs-root \${SYMPHONY_HUB_LOGS_ROOT} --hub-config \${SYMPHONY_HUB_CONFIG} --hub-activation-probe \${SYMPHONY_HUB_ACTIVATION_PROBE} --host \${SYMPHONY_HUB_HOST} --port \${SYMPHONY_HUB_PORT}
Restart=on-failure
RestartSec=10
KillSignal=SIGINT
TimeoutStopSec=30

[Install]
WantedBy=default.target
UNIT

if [ "$run_systemd" -eq 1 ]; then
  systemctl --user daemon-reload

  if [ "$start_service" -eq 1 ]; then
    systemctl --user enable --now "$service_name"
  fi
fi

echo "Installed ${service_name}"
echo "Hub config: ${hub_config}"
echo "Dashboard/API: http://127.0.0.1:${port}/"
