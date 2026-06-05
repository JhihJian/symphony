# 0002 In-Memory Orchestrator State

## 状态

目标状态；当前项目已有实现代码（主要在 `elixir/`），但本次架构基线尚未逐项完成代码一致性审计可验证。

## 背景

Symphony 需要协调轮询、占用、运行中 worker、重试和 reconciliation。SPEC 同时明确不要求持久化调度数据库，重启恢复主要依赖 tracker 当前状态和保留的 workspace。

这意味着系统要把“运行时调度账本”和“可重建的外部事实”分开看待。前者只在进程内有效，后者来自 tracker 和文件系统。

## 决策

Orchestrator 在内存中维护唯一调度账本，并且只有 orchestrator 可以修改它。worker outcome、retry timer、tracker refresh 和 agent event 都必须回到 orchestrator，再由它转换为状态变化。

进程重启后不恢复 live worker、retry timer 或 agent session。服务通过启动清理、重新轮询 active issues 和重新派发 eligible work 恢复有用运行。

## 影响

- 实现可以避免 durable scheduler database。
- duplicate dispatch 防护依赖单进程内 serialized mutation 和 claim/running 检查。
- workspace 持久化和 tracker 状态成为 restart recovery 的关键。
- 如果未来需要跨进程恢复 retry queue 或 session metadata，应作为明确扩展，而不是当前核心假设。

## 来源

- `SPEC.md` §4.1.8
- `SPEC.md` §7
- `SPEC.md` §14.3
- `SPEC.md` §18.2
