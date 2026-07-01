# Symphony systemd template 部署

本文档说明如何用用户级 systemd template 部署多个 Symphony 项目实例。

当前 systemd template 仍是 legacy 多实例模型：每个 `symphony@<project>.service` 是独立
进程，读取自己的 `WORKFLOW.md`、`TRACKER.yaml`、workspace、tracker scope 和 Dashboard/API
端口。Elixir 代码中新增的 Hub mode `HUB.yaml` 项目注册表只提供进程内 Hub 方向的模型加载、
身份快照和校验能力；Hub provider request governance 也只是定义未来统一 provider 出口的请求、
队列、quota/backoff/circuit 和结果分类模型。它不会让本部署方式变成单进程 Hub 调度，也不会接管
现有 poll loop、tracker fetch、写回或 dynamic tools provider 调用。
Hub device observability 投影同样只是把这些 safe summary 汇总成 Dashboard/API 可消费的设备视图：
它可以标记 `legacy_only`、`hub_ready`、`hub_managed` 等迁移状态，但不会替换
`symphony@project.service`，也不会把 legacy 多实例自动迁移成 Hub mode。
当手动以 `--hub-config ... --port <port>` 启动 Hub runtime 时，`/api/v1/state` 会暴露
`hub_device_observability.overview` 和每个 project 的 `detail`。Overview 汇总 scheduler/tick
等待或合并原因、project 状态计数、provider queue/backoff/circuit/recent failure、capacity/workspace、
writeback/manual attention、activation preflight 和 lifecycle 状态；项目明细解释 identity/provider
scope、migration/ownership、config fingerprint/snapshot version、preflight 阻断或 unknown、poll
eligibility、candidate/dispatch/start/lifecycle/writeback 当前状态。Live Dashboard 也只在存在该 Hub
summary 时显示“Hub 设备总览”和“Hub 项目明细”；legacy non-Hub 实例不会被误标为 Hub-managed。
同一个 Hub device observability 投影还会暴露
`hub_device_observability.migration_readiness`：它只基于上述 safe summary 派生设备级迁移准备报告，
包括 Hub runtime/scheduler 是否启用、provider/writeback executor、worker starter、activation probe
模式、各 migration state 和 readiness decision 的项目数量、全局 blocking/advisory 风险，以及每个
project 的 `legacy_only`、`ready_for_dry_run`、`ready_for_hub_management`、`blocked`、
`unknown_manual_attention`、`already_hub_managed` 决策、阻断原因、建议动作和脱敏证据。单个项目
summary 缺字段、版本不兼容或构建失败时，只会让该项目进入 `unknown_manual_attention` /
`summary_error`，不会拖垮整个 Dashboard/API。
同一个投影还会暴露 `hub_device_observability.activation_plan`：它把 readiness 证据整理成每个
project 的只读 activation plan，包括稳定 `plan_id`、建议下一状态、需要 operator 确认的 action
code、阻断/建议原因、脱敏 evidence，以及 acknowledgement 状态。acknowledgement 只通过显式输入
进入，例如 Hub 启动参数 `--hub-activation-ack /path/to/ack.yaml`；它必须绑定 `project_id` 和
`plan_id`，并列出已确认的 action/risk code。readiness evidence、provider scope、migration state、
executor/probe mode、ownership facts 或 reason/action code 变化后，旧 ack 会显示为 `stale`、
`conflict` 或 manual attention，不能静默复用。`accepted` 只表示 operator 已确认这份证据，不会
自动 stop/disable legacy service、编辑配置、写回 provider 或交接 worker。
activation plan / ack 之后，Hub 还会暴露 `hub_cutover_gate` 和
`hub_device_observability.cutover_gate`。这个 cutover gate 是真实 Hub-owned 动作前的逐项目门禁：
它把 plan id/fingerprint、ack 状态、readiness、activation preflight、host/service probe、
provider/writeback executor、worker starter、scheduler 和项目快照合成 `not_applicable`、`blocked`、
`manual_attention`、`staged_ready` 或 `allowed` 决策，并列出 `poll`、`dispatch`、`worker_start`、
`writeback` 哪些允许、哪些被阻断、原因和需要 operator 处理的 action code。只有项目已显式
`hub_managed`、ack 匹配当前 plan、preflight 安全、没有 legacy owner 冲突且对应 executor/starter
模式匹配时，真实 candidate scan、dispatch pending start intent、real worker starter 和 real writeback
才会继续。允许时生成的 staged ownership record 只是本轮输入的只读审计摘要；证据或模式变化后不能静默复用，
也不会自动修改 `HUB.yaml`、`WORKFLOW.md`、`TRACKER.yaml`、systemd unit、provider 状态或 legacy service。
cutover gate 之后，Hub 还会暴露只读的 cutover operation request / dry-run audit 摘要：
`hub_cutover_operation_audit` 和 `hub_device_observability.cutover_operation_audit`。operator 可以通过
显式 Hub 启动参数 `--hub-cutover-operation-request /path/to/request.yaml` 提交“请评估这个 project
的这些 Hub-owned operation”的序列化请求。request 必须绑定 project、安全 provider scope、operation
set、activation plan id/fingerprint、cutover gate/staged record 证据、source、requested_at、request
fingerprint 和安全 project snapshot；operator intent 只保留 action/risk code 或 note digest。audit
只返回每个 operation 的 `would_allow`、`would_block`、`manual_attention` 或 `unsupported`、原因/action
code、脱敏证据和 `dry_run_only`。它不会访问 provider、启动 worker、写 runtime ledger pending/attempt/
writeback fact、写 provider、操作 systemd 或修改 `HUB.yaml` / `WORKFLOW.md` / `TRACKER.yaml` / 项目配置。
没有显式 request 时，Dashboard/API 只显示 `no_request` 计数，不会把 gate allowed 误表示为迁移已排队
或正在执行。
在 dry-run audit 之后，Hub 还会暴露只读的 cutover audit history / manual attention closeout 摘要：
`hub_cutover_audit_history` 和 `hub_device_observability.cutover_audit_history`。它把当前 dry-run audit
和可选的历史输入整理成有大小边界的项目级历史，并用显式 closeout 记录说明某个 operation 的
reason/action 是否已被 operator 接受、外部解决、驳回、延期，或因为 request / plan / gate /
evidence fingerprint 变化而 stale/conflict。closeout 可以通过显式启动参数
`--hub-manual-attention-closeout /path/to/closeout.yaml` 输入；历史基线可通过
`--hub-cutover-audit-history /path/to/history.yaml` 输入。它们都只影响 Dashboard/API 审计摘要，不会绕过
cutover gate，不会访问 provider、启动 worker、写 runtime ledger、写 provider、操作 systemd 或修改
`HUB.yaml` / `WORKFLOW.md` / `TRACKER.yaml` / 项目配置。无历史时显示 `no_history`，不会表示迁移已经排队。
在 audit history / closeout 之后，Hub 还会暴露只读的 cutover execution readiness permit：
`hub_cutover_readiness_permit` 和 `hub_device_observability.cutover_readiness_permit`。permit 把当前
request fingerprint、activation plan / ack fingerprint、cutover gate / staged ownership evidence、
dry-run audit decision、audit history/closeout 当前性、executor/starter mode 和 evidence fingerprint
汇总成每个 requested operation 的 `ready_for_execution_consideration`、`blocked`、`stale`、
`manual_attention`、`unsupported` 或 `malformed` 决策。只有 gate 当前允许、dry-run 当前 would allow、
manual attention 已安全处理、ack 与 plan 仍匹配、模式兼容且证据未漂移时才显示 ready。它仍然只是
Dashboard/API 可审计的执行前只读门禁摘要，不会绕过 cutover gate，不会访问 provider、dispatch、
启动 worker、写 runtime ledger / provider、操作 systemd、修改配置或接管 legacy service。无 request
时显示 `no_request` / permit count 0，不表示迁移已经排队或执行中。
在 readiness permit 之后，Hub 还会暴露只读的 cutover execution authorization ledger：
`hub_cutover_execution_authorization_ledger` 和
`hub_device_observability.cutover_execution_authorization_ledger`。operator 可以通过显式启动参数
`--hub-cutover-execution-authorization-request /path/to/request.yaml` 提交“我现在明确授权考虑执行哪个
operation”的请求；ledger 会把该请求绑定到当前 readiness permit fingerprint/decision、cutover
operation request fingerprint、activation plan / ack fingerprint、cutover gate / staged ownership
evidence、dry-run audit、audit history / closeout 当前性、executor/starter mode 与 evidence
fingerprint。只有 permit 当前仍是 `ready_for_execution_consideration` 且所有绑定证据仍匹配时，记录才会显示
`authorized_for_explicit_execution`；否则显示 `blocked`、`stale`、`manual_attention`、`unsupported`、
`malformed` 或 `no_ready_permit`。这个 ledger 是后续显式执行阶段可消费的只读授权证据，不是执行器、
队列、一键迁移或 legacy service 接管；它不会绕过 cutover gate / readiness permit，不会访问 provider、
dispatch、启动 worker、写 runtime ledger / provider、操作 systemd 或修改配置。无 authorization request
时显示 request / record count 0，不表示迁移已经排队或执行中。
当显式 Hub cutover execution path 进入真实 side-effect 入口时，Hub 还会暴露 authorization
consumption guard 摘要：`hub_cutover_authorization_consumption_guard` 和
`hub_device_observability.cutover_authorization_consumption_guard`。real candidate scan、dispatch plan
application、real worker start handoff 和 real provider writeback 会在 provider I/O、runtime ledger
mutation、worker start 或 provider writeback 前进入同一个 guard，即使 authorization ledger 为空也会先得到
`no_authorization`，不会继续做真实副作用。摘要会按 operation / 入口统计 `allowed`、`blocked`、`no_authorization`、`stale`、`manual_attention`、`unsupported`、
`malformed`，并记录最近的脱敏 reason/action code、safe evidence fingerprint 和被缺失/不匹配授权阻断的
入口。这个 guard 只是显式执行前的共同授权消费边界，不是一键迁移、执行队列或 legacy service 接管，也不替代
cutover gate、readiness permit、authorization ledger、activation preflight、provider governance、
runtime ledger、worker starter 或 writeback executor。没有发生真实消费事件时显示 `no_consumption`，
不表示迁移或执行待处理。
Hub activation preflight 是这个迁移边界上的保护层：当某个项目被显式标为 `hub_managed` 并准备走
Hub 的 poll、dispatch、real worker starter 或 real writeback 路径时，Hub 会先读取安全的项目快照
和注入的 host/service probe 摘要，检查是否仍有同名 legacy service、legacy-owned provider scope、
workspace/runtime/log/state 路径、Dashboard/API 端口或 instance registry owner。发现冲突或探测未知时，
Hub 默认只阻断该项目的 Hub poll、dispatch、worker_start 和 writeback，并在 `/api/v1/state` /
device observability 中给出脱敏 reason/source；其他无冲突项目继续运行。这个 guardrail 不会自动
`stop`、`disable`、迁移或删除 `symphony@<project>.service`，需要人工处理 legacy owner 或做明确的风险确认。
显式传入 `--hub-activation-probe host-service` 时，Hub 会启用第一版真实本机只读探测：读取
用户级 `symphony@<project>.service` active/enabled/failed/unknown 状态、legacy config 目录
`~/.config/symphony/projects/<project>/` 下的 `env`、`WORKFLOW.md`、`TRACKER.yaml` 安全摘要、
systemd-template runtime/log/state 约定和本机 Dashboard/API 端口监听情况。systemd 不可用、
配置不可读、端口探测不可用或单项目探测失败会让对应项目进入 unknown/manual attention，不会让
Hub tick 崩溃，也不会影响其他项目。
如果需要试运行 Hub runtime poll tick 骨架，可以手动执行
`./bin/symphony --hub-config /path/to/HUB.yaml --port <port>`；该入口会加载注册表、生成 poll plan、
通过 Hub provider request 边界执行一轮可控的 candidate-scan tick、记录 poll attempt/result fact，
并通过 `/api/v1/state` 暴露安全字段。若额外传入 `--hub-scheduler`，Hub runtime 会启用第一版
显式 opt-in 的 Hub-owned tick loop baseline：启动后自动 tick，完成后根据 Hub poll plan、
provider backoff 和 runtime-ledger 未解决状态安排下一轮，并让手动 `/refresh` 与运行中/已排队 tick
合并而不是并发执行。默认骨架 executor 不迁移 GitHub/GitLab/Linear legacy adapter、
不派发 agent、不停止各项目自己的 poll loop。本文档的 systemd template 仍使用
`--tracker-config <TRACKER.yaml> <WORKFLOW.md>`，不会自动改成 Hub mode。
如果只是想在迁移前查看本机接管风险，可以使用：

```bash
./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --hub-config /path/to/HUB.yaml \
  --hub-activation-probe host-service \
  --port 21000

curl -sS http://127.0.0.1:21000/api/v1/state | jq '{
  preflight: .hub_activation_preflight,
  readiness: .hub_device_observability.migration_readiness,
  activation_plan: .hub_device_observability.activation_plan,
  cutover_gate: .hub_cutover_gate,
  device_cutover_gate: .hub_device_observability.cutover_gate,
  cutover_operation_audit: .hub_cutover_operation_audit,
  device_cutover_operation_audit: .hub_device_observability.cutover_operation_audit,
  cutover_audit_history: .hub_cutover_audit_history,
  device_cutover_audit_history: .hub_device_observability.cutover_audit_history,
  cutover_readiness_permit: .hub_cutover_readiness_permit,
  device_cutover_readiness_permit: .hub_device_observability.cutover_readiness_permit,
  cutover_execution_authorization_ledger: .hub_cutover_execution_authorization_ledger,
  device_cutover_execution_authorization_ledger: .hub_device_observability.cutover_execution_authorization_ledger,
  cutover_authorization_consumption_guard: .hub_cutover_authorization_consumption_guard,
  device_cutover_authorization_consumption_guard: .hub_device_observability.cutover_authorization_consumption_guard
}'
```

这个命令只生成脱敏证据摘要，不会停止、disable、restart、delete 或迁移任何
`symphony@<project>.service`。迁移前 dry-run 的建议基线是：先准备 `HUB.yaml`，把仍由 legacy
多实例拥有的项目标为 `legacy_only`，把准备评估的项目标为 `hub_ready`，只有在人工确认 legacy
service、provider scope、workspace/runtime/log/state/port owner、writeback、lifecycle 和 executor
模式都可接受后，才把项目改为 `hub_managed`。`ready_for_dry_run` 表示可以继续只读或低风险试运行；
`ready_for_hub_management` 表示证据上已接近可由人工切换为 `hub_managed`；`blocked` 表示存在明确
冲突；`unknown_manual_attention` 表示证据不足或需要人工复核。停止/disable legacy
`symphony@<project>.service`、处理 unresolved writeback/manual attention、确认 real provider
executor/writeback executor/worker starter 模式，并确认 cutover gate 对目标 operation 显示 allowed
或 staged_ready，必须由 operator 手工执行。本片不提供一键迁移，
也不会自动修改 `HUB.yaml`、项目配置、systemd unit 或 provider 状态。
如果手动试运行 Hub 并传入
`--hub-provider-executor real-candidate-scan`，Hub candidate scan 会在 `ProviderGovernance`
边界后按每个 registry project 的 `WORKFLOW.md` / `TRACKER.yaml` 读取候选，并在
`/api/v1/state` 中暴露 executor 模式、候选计数、错误分类、backoff/manual attention 等安全摘要。
该 opt-in 只覆盖候选读取，不实现 provider 写回、dynamic tools 路由迁移、真实 agent 派发，也不会改变
`symphony@project.service` 多实例部署的默认行为。
如果手动试运行 Hub 并传入 `--hub-provider-executor real-writeback`，Hub 只会启用第一版受控写回
executor：在 `WritebackProcessor` 判定可执行后，处理 status/stage 写回、GitHub workpad marker
upsert 和 GitHub label add；PR 创建、普通追加评论、冲突 intent、未知非幂等结果和 unsupported
operation 会进入 governed manual-attention / lookup-required / permanent-failure 摘要。该 opt-in
同样按 registry project 重新加载对应 `WORKFLOW.md` / `TRACKER.yaml`，不会使用其他项目的 repo、
token、项目号或 stage/label 映射；单项目写回失败只影响对应 project/scope。本文档的 systemd
template 不会默认启用该模式，也不会把 legacy 多实例写回迁移到 Hub。

Hub 设备/项目明细仍只展示脱敏摘要：不会显示 token、Authorization/cookie、secret env、raw env/raw
config、完整 prompt/transcript、完整 issue/comment/PR/provider body、raw provider response、raw systemd
output、hook/app-server raw output 或异常堆栈。单个 project 的 summary 缺字段、版本不兼容或构建失败
只会让该 project 显示 summary error/manual attention，不会让整个 Dashboard/API 失败。

## 快速安装

推荐直接使用远程安装脚本创建或更新项目实例。脚本会先把 Symphony `main` 分支 clone 或更新到 `~/.codex/symphony`，再从这份 clone 安装 systemd 服务：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jhihjian/symphony/main/scripts/install-systemd-template.sh)" -- \
  --project symphony \
  --owner jhihjian \
  --repo symphony \
  --project-number 3 \
  --port 20000 \
  --token "$GITHUB_TOKEN" \
  --auto-update
```

如果已经 clone 了仓库，也可以在仓库内运行：

```bash
scripts/install-systemd-template.sh \
  --project symphony \
  --owner jhihjian \
  --repo symphony \
  --project-number 3 \
  --port 20000 \
  --token "$GITHUB_TOKEN" \
  --auto-update
```

脚本会完成：

- 安装或更新 `~/.config/systemd/user/symphony@.service`
- 创建 `~/.config/symphony/projects/<project>/env`
- 创建 `~/.config/symphony/projects/<project>/WORKFLOW.md`
- 创建 `~/.config/symphony/projects/<project>/TRACKER.yaml`
- 创建 `~/.codex/symphony/projects/<project>/logs`
- 创建 `~/.codex/symphony/projects/<project>/workspaces`
- clone 或更新 `https://github.com/jhihjian/symphony` 的 `main` 分支到 `~/.codex/symphony`
- 使用 `~/.codex/symphony/elixir` 作为 Symphony 程序目录
- 如果 `~/.codex/symphony/elixir/bin/symphony` 不存在，自动在 `~/.codex/symphony/elixir` 下执行 `mix setup` 和 `mix build`
- 执行 `systemctl --user daemon-reload`
- 默认启用并启动 `symphony@<project>.service`
- 如果传了 `--auto-update`，安装并启用 `symphony-update.timer`

如果没有传 `--port`，新项目会从 `20000` 开始查找下一个未被现有项目配置使用的端口；更新已有项目时会保留该项目原来的端口。
如果更新已有项目时没有传 `--token`，脚本会保留该项目现有 `env` 文件里的 `GITHUB_TOKEN`。
如果不希望脚本自动构建二进制，可以传 `--skip-build`。
如果不希望自动更新，去掉 `--auto-update`；如果之前启用过，可以传 `--no-auto-update` 关闭。
如果只想生成文件、不执行 `systemctl --user`，可以传 `--no-systemd`。

## 目录约定

安装脚本不假设用户已经手动 clone 仓库。默认情况下，它会使用下面的源码目录：

```text
~/.codex/symphony/
  elixir/
  scripts/
  projects/
```

其中 `projects/` 是运行目录，更新脚本会忽略它，不会因为日志或 workspace 文件导致自动更新失败。

如果需要让 systemd 使用另一份源码，可以显式传入：

```bash
scripts/install-systemd-template.sh ... --source-root /path/to/symphony
```

如果需要使用 fork 或非 `main` 分支：

```bash
scripts/install-systemd-template.sh ... \
  --source-repo-url https://github.com/<owner>/symphony \
  --source-branch main
```

每个受管项目使用独立配置目录：

```text
~/.config/symphony/projects/<project>/
  WORKFLOW.md   # provider-neutral workflow stages, outcomes, transitions, stage prompts
  TRACKER.yaml  # provider access, stage-state mapping, runtime/workspace/hooks/codex settings
  env           # 项目密钥、端口、日志目录
```

每个受管项目使用独立运行目录：

```text
~/.codex/symphony/projects/<project>/
  logs/
  workspaces/
```

## systemd template

用户级 template unit 位于：

```text
~/.config/systemd/user/symphony@.service
```

实例名就是项目名。例如 `symphony@symphony.service` 会读取：

```text
~/.config/symphony/projects/symphony/env
~/.config/symphony/projects/symphony/WORKFLOW.md
~/.config/symphony/projects/symphony/TRACKER.yaml
```

服务 `ExecStart` 会显式传入 tracker 配置：

```text
./bin/symphony ... --tracker-config ~/.config/symphony/projects/%i/TRACKER.yaml ~/.config/symphony/projects/%i/WORKFLOW.md
```

服务命令形态：

```bash
systemctl --user start symphony@<project>.service
systemctl --user status symphony@<project>.service --no-pager
journalctl --user -u symphony@<project>.service -f
```

## 端口规划

Dashboard/API 端口从 `20000` 开始递增：

```text
symphony   20000
project-a  20001
project-b  20002
```

每个项目的端口写在该项目的 `env` 文件中：

```bash
SYMPHONY_PORT=20000
SYMPHONY_LOGS_ROOT=$HOME/.codex/symphony/projects/symphony/logs
```

如果需要局域网访问，在对应 `TRACKER.yaml` 中设置：

```yaml
server:
  host: 0.0.0.0
```

然后访问：

```text
http://<host-ip>:<SYMPHONY_PORT>/
http://<host-ip>:<SYMPHONY_PORT>/workflow
```

## 新增项目示例

下面示例新增 `project-a`。如果 `20000` 已被当前项目使用，脚本会自动选择 `20001`：

```bash
scripts/install-systemd-template.sh \
  --project project-a \
  --owner <owner> \
  --repo <repo> \
  --project-number <github-project-v2-number> \
  --token "$GITHUB_TOKEN"
```

如果只想生成配置、不立即启动：

```bash
scripts/install-systemd-template.sh \
  --project project-a \
  --owner <owner> \
  --repo <repo> \
  --project-number <github-project-v2-number> \
  --no-start
```

## 自动更新

推荐在多实例部署中使用 Dashboard 控制自动更新：打开任一运行中实例的
`http://<host>:<SYMPHONY_PORT>/admin/instances`，页面会展示当前部署 commit、GitHub
`main` 最新 commit、下一次 API 轮询时间、最近一次检查结果、速率限制信息和最近一次更新/构建/重启结果。

Dashboard 后端通过 GitHub REST API 轮询 `jhihjian/symphony` 的 `main` 分支，并使用
ETag/`If-None-Match` 条件请求降低速率限制压力。也可以通过 API 手动触发：

```bash
curl http://127.0.0.1:20000/api/v1/admin/auto-update
curl -X POST http://127.0.0.1:20000/api/v1/admin/auto-update/check
curl -X POST http://127.0.0.1:20000/api/v1/admin/auto-update/update
```

更新执行会先检查源码目录是否有本地未提交改动；有改动时会阻止更新并在 Dashboard/API
显示错误。只有 `git fetch`/fast-forward 和 `mix build` 成功后，才记录
`elixir/_build/symphony.build-revision` 并进入实例重启决策。这个标记用于区分“源码已经拉到
最新”与“当前 `bin/symphony` 已经由该 commit 成功构建”，避免上一次构建失败后下次更新被误判为
up to date。默认策略不会重启有活跃 Symphony 会话的实例，而是标记为等待空闲；失败实例不会被自动覆盖。

每个实例可在 `~/.config/symphony/projects/<project>/env` 中配置更新策略：

```bash
SYMPHONY_UPDATE_STRATEGY=idle_restart
```

安装或更新实例时也可以直接指定，未指定时会保留已有 `env` 中的值：

```bash
scripts/install-systemd-template.sh ... --update-strategy manual_restart
```

可选值：

- `idle_restart`：空闲 active 实例自动重启；运行中实例等待空闲。
- `defer_until_idle`：与 `idle_restart` 等价，强调运行中延后。
- `download_only`：只更新和构建程序，不自动重启实例。
- `manual_restart`：构建后等待人工确认重启。
- `force_restart`：显式危险操作，允许强制重启。

下面的 systemd timer 仍保留为兼容的无人值守入口；如果希望完全由 Dashboard 控制，可以不传
`--auto-update`，或对已有部署执行 `--no-auto-update` 关闭 timer。注意：Dashboard auto-update
会读取每个实例的 `SYMPHONY_UPDATE_STRATEGY`，而 legacy timer 脚本是独立入口，不会检查实例是否有
活跃 Symphony 会话。

安装时加上 `--auto-update` 会创建并启用用户级 timer：

```text
~/.config/systemd/user/symphony-update.service
~/.config/systemd/user/symphony-update.timer
```

默认每天运行一次，并带 `RandomizedDelaySec=30m`。更新动作由 `~/.codex/symphony` 中的脚本执行：

```bash
~/.codex/symphony/scripts/update-systemd-template.sh
```

它会执行：

1. 检查 Symphony 源码仓库是否有本地未提交改动；运行目录 `projects/` 会被忽略。
2. 在源码仓库执行 `git pull --ff-only`；如果不能 fast-forward，停止更新。
3. 如果源码 commit 变化，或 `elixir/_build/symphony.build-revision` 不等于当前 commit，在 `elixir/`
   下执行 `mise exec -- mix setup` 和 `mise exec -- mix build`。
4. 构建成功后写入 `elixir/_build/symphony.build-revision`。
5. 重启所有已启用或正在运行的 `symphony@*.service` 实例；该 legacy 路径不执行 Dashboard 的
   `idle_restart`/`manual_restart`/`download_only` 等 per-instance 策略判断。

查看自动更新计划：

```bash
systemctl --user list-timers symphony-update.timer --no-pager
```

查看自动更新日志：

```bash
journalctl --user -u symphony-update.service --no-pager
```

立刻触发一次自动更新：

```bash
systemctl --user start symphony-update.service
```

修改自动更新频率，例如每天 04:30：

```bash
scripts/install-systemd-template.sh \
  --project symphony \
  --owner jhihjian \
  --repo symphony \
  --project-number 3 \
  --auto-update \
  --update-calendar '*-*-* 04:30:00'
```

关闭自动更新：

```bash
scripts/install-systemd-template.sh \
  --project symphony \
  --owner jhihjian \
  --repo symphony \
  --project-number 3 \
  --no-auto-update
```

## 卸载项目

默认卸载只停止并禁用服务，保留配置、token、日志和 workspaces：

```bash
scripts/uninstall-systemd-template.sh --project project-a
```

如果确认要删除项目配置：

```bash
scripts/uninstall-systemd-template.sh --project project-a --purge-config
```

如果确认要删除日志和 workspaces：

```bash
scripts/uninstall-systemd-template.sh --project project-a --purge-runtime
```

完全删除该项目实例：

```bash
scripts/uninstall-systemd-template.sh --project project-a --purge-all
```

如果最后一个实例已经删除，并且也想删除 template unit：

```bash
scripts/uninstall-systemd-template.sh --project project-a --purge-all --remove-template
```

如果最后一个实例已经删除，并且也想删除自动更新 timer：

```bash
scripts/uninstall-systemd-template.sh --project project-a --purge-all --remove-auto-update
```

## 当前项目实例

当前 `symphony` 项目实例：

```text
service: symphony@symphony.service
port: 20000
workflow: ~/.config/symphony/projects/symphony/WORKFLOW.md
tracker: ~/.config/symphony/projects/symphony/TRACKER.yaml
env: ~/.config/symphony/projects/symphony/env
logs: ~/.codex/symphony/projects/symphony/logs
workspaces: ~/.codex/symphony/projects/symphony/workspaces
```

管理命令：

```bash
systemctl --user status symphony@symphony.service --no-pager
journalctl --user -u symphony@symphony.service -f
systemctl --user restart symphony@symphony.service
systemctl --user stop symphony@symphony.service
```

## 旧配置迁移到两文件布局

如果已有实例仍使用旧单文件 `WORKFLOW.md` front matter 存放 provider、tracker 和 runtime 字段，先使用迁移 task 拆分，再重载 systemd template。以下步骤以当前 `symphony@symphony.service` 为例，命令会备份原文件并保留现有 `env` token：

```bash
project=symphony
config_dir="$HOME/.config/symphony/projects/$project"
backup_dir="$config_dir/backup-$(date +%Y%m%d%H%M%S)"

systemctl --user stop "symphony@$project.service"
mkdir -p "$backup_dir"
cp "$config_dir/WORKFLOW.md" "$backup_dir/WORKFLOW.md"
[ -f "$config_dir/TRACKER.yaml" ] && cp "$config_dir/TRACKER.yaml" "$backup_dir/TRACKER.yaml"

cd ~/.codex/symphony/elixir
mise exec -- mix workflow.split_tracker_config \
  --workflow "$config_dir/WORKFLOW.md" \
  --workflow-out "$config_dir/WORKFLOW.md.next" \
  --tracker-out "$config_dir/TRACKER.yaml.next" \
  --force

mv "$config_dir/WORKFLOW.md.next" "$config_dir/WORKFLOW.md"
mv "$config_dir/TRACKER.yaml.next" "$config_dir/TRACKER.yaml"

systemctl --user daemon-reload
systemctl --user start "symphony@$project.service"
journalctl --user -u "symphony@$project.service" --since "5 minutes ago" --no-pager
curl -sS "http://127.0.0.1:20000/api/v1/state"
```

迁移后检查点：

- `WORKFLOW.md` 只保留 provider-neutral `workflow` stages，不包含 `tracker:`。
- `TRACKER.yaml` 包含 `tracker.kind`、owner/repo/project number、`workflow_state.strategy: project_v2_status`、`field_name: Status`、`state_options`、`required_labels`，并保留 `server`、`workspace`、`hooks`、`agent`、`codex`、`polling`、`observability`、`worker` 等 runtime 字段。
- `systemctl --user status symphony@symphony.service --no-pager` 显示 active/running。
- `journalctl` 没有 `Invalid WORKFLOW.md`、`Invalid TRACKER.yaml`、`missing_tracker_config_file`。
- `/api/v1/state` 返回 JSON，且包含 `counts`。

如果启动失败，可以回滚备份：

```bash
systemctl --user stop "symphony@$project.service"
cp "$backup_dir/WORKFLOW.md" "$config_dir/WORKFLOW.md"
[ -f "$backup_dir/TRACKER.yaml" ] && cp "$backup_dir/TRACKER.yaml" "$config_dir/TRACKER.yaml"
systemctl --user daemon-reload
systemctl --user start "symphony@$project.service"
```

## 更新 Symphony 程序

推荐直接使用 clone 到 `~/.codex/symphony` 的更新脚本：

```bash
~/.codex/symphony/scripts/update-systemd-template.sh
```

只更新和构建，不重启实例：

```bash
~/.codex/symphony/scripts/update-systemd-template.sh --no-restart
```

更新后只重启某个项目实例：

```bash
~/.codex/symphony/scripts/update-systemd-template.sh --project symphony
```

等价的手动步骤是到 `~/.codex/symphony` 更新程序代码并重建：

```bash
cd ~/.codex/symphony
git pull
cd elixir
mise exec -- mix setup
mise exec -- mix build
```

然后重启需要使用新程序的 template 实例：

```bash
systemctl --user restart symphony@symphony.service
```

## 检查状态

列出所有 Symphony 实例：

```bash
systemctl --user list-units 'symphony@*.service' --no-pager
```

检查端口监听：

```bash
ss -ltnp | rg ':20000|:20001|:20002'
```

检查 API：

```bash
curl http://127.0.0.1:20000/api/v1/state
```

如果启用了局域网访问：

```bash
curl http://<host-ip>:20000/api/v1/state
```

## 多实例管理 Dashboard

任意启用了 `server.port` 或通过 `--port` 启动的 Symphony 实例，都会在同一个 Phoenix
服务里提供多实例管理入口：

```text
http://127.0.0.1:<port>/admin/instances
http://127.0.0.1:<port>/api/v1/admin/instances
```

这个页面是 operator 管理面，不是多租户 orchestrator：

- `/` 是当前进程的单实例执行 Dashboard，展示该实例内部 orchestrator 的运行、重试、阻塞和 token 状态。
- `/workflow` 是当前实例的只读 workflow-stage 配置可视化页面，读取该实例的 `WORKFLOW.md`
  和 `TRACKER.yaml`，展示阶段图、transition、missing outcome fallback、tracker 映射覆盖和可用的
  `current_stage` 运行态分布；页面不展示 token、`api_key` 或 env secret 原始值。
- `/admin/instances` 从 `~/.config/symphony/projects` 发现已登记实例，聚合 systemd user service 状态和各实例 `/api/v1/state`。
- 每个 `symphony@<project>.service` 仍然独立拥有自己的 `WORKFLOW.md`、`TRACKER.yaml`、环境变量、日志目录、workspace root、端口和内存调度账本。
- 停止、失败或 API 不可达的实例会显示为该实例自己的健康状态，不会影响其他实例展示。
- 管理面可以请求 `start`、`stop`、`restart`，失败时 API 返回可读错误；issue 派发、重试、reconciliation 和 workspace 隔离仍由对应实例内部 `Orchestrator` 负责。

管理 API 示例：

```bash
curl http://127.0.0.1:20000/api/v1/admin/instances
curl -X POST http://127.0.0.1:20000/api/v1/admin/instances/project-a/restart
```
