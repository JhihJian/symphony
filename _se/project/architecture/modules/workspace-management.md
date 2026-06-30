# Workspace 管理

结论状态：SPEC 目标状态；当前项目已有实现代码（主要在 `elixir/`），但本次架构基线尚未逐项完成代码一致性审计可验证。

## 模块定位与边界

Workspace 管理模块负责 agent 的文件系统边界。它把 provider-scoped issue 标识映射为稳定、安全的目录路径，确保目录存在，运行目录生命周期 hook，并在终止状态下清理目录。

该模块不决定 issue 是否可运行，不渲染 prompt，不启动 Codex app-server，也不规定仓库如何 checkout、同步或准备依赖。除创建目录和执行 hook 之外，workspace 内容如何准备属于实现策略或 workflow 脚本。

## 核心实体

- `Workspace Root`：所有 issue workspace 必须位于其下的根目录。
- `Workspace Key`：由 provider-scoped issue identifier 安全转换得到的目录名。
- `Workspace`：某个 issue 的 agent 工作目录，跨运行尝试复用。
- `生命周期 Hook`：在创建后、运行前、运行后或删除前执行的仓库脚本。
- `路径安全检查`：启动 agent 前确认目录没有逃逸 workspace root 的验证。

## 功能清单

- 将 provider-scoped issue identifier 转换为安全 workspace key。
- 根据 workspace root 和 workspace key 计算绝对 workspace 路径。
- 验证 workspace 路径仍位于 workspace root 内。
- 创建缺失的 workspace directory，并复用已存在目录。
- 只在新建目录时执行创建后 hook。
- 每次运行尝试前执行运行前 hook。
- 每次运行尝试结束后执行运行后 hook。
- 在 workspace 删除前执行删除前 hook。
- 启动时根据终止状态 issue 清理遗留 workspace。
- reconciliation 发现运行中 issue 进入终止状态时清理对应 workspace。

## 业务规则

- agent 只能在当前 issue 对应的 workspace 中运行。
- agent 启动前必须完成路径规范化和 root containment 检查。
- workspace key 必须去除或替换不适合作为目录名的外部字符。
- GitHub/GitLab workspace key 不能只从 `#123`、`123` 或项目内 `iid` 派生；它必须包含 provider 与 owner/repo 或 project scope，避免不同仓库或项目的 issue 复用同一目录。
- 创建后 hook 失败会使 workspace 创建失败。
- 运行前 hook 失败会使当前运行尝试失败。
- 运行后 hook 和删除前 hook 失败应记录，但不应阻止后续清理或调度处理。
- hook 来自仓库 workflow，视为受信配置，但必须有超时，输出也应避免无限写入日志。
- successful run 不自动删除 workspace；保留目录用于重试、继续执行和人工排查。
- 已复用 workspace 出现准备失败时，不应默认破坏性重置，除非实现明确记录该策略。

## 用户交互流程

operator 通过 `WORKFLOW.md` 配置 workspace 位置和生命周期 hook。第一次运行某个 issue 时，服务创建 workspace 并执行创建后 hook；每次运行尝试前后分别执行运行前和运行后 hook。

当 operator 在 tracker 中把 issue 改为终止状态，下一次 reconciliation 会停止相关 worker 并触发 cleanup。服务重启时也会扫描终止状态 issue，清理它们遗留的 workspace。
