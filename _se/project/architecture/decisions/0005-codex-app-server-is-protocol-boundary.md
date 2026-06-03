# 0005 Codex App-Server Is Protocol Boundary

## 状态

目标状态；当前项目已有实现代码（主要在 `elixir/`），但本次架构基线尚未逐项完成代码一致性审计可验证。

## 背景

Symphony 需要集成 Codex app-server，但 app-server protocol 的消息结构、传输 framing、方法名和 schema 由目标 Codex 版本定义，并可能随版本变化。

如果实现把 Symphony SPEC 中的示例事件或语言无关描述当作 Codex 协议 schema，升级 Codex 或切换目标版本时会产生脆弱耦合。

## 决策

Codex app-server protocol 的权威来源是目标 Codex 版本文档或 generated schema。Symphony SPEC 只定义本系统自己的编排责任：workspace 选择、prompt 构造、continuation 处理、事件上报、超时和观测提取。

当 Symphony SPEC 与目标 Codex protocol 在协议形状上冲突时，Codex protocol 控制协议行为；Symphony 的 workspace 和调度不变量仍然适用。

## 影响

- Agent Runner 需要隔离 Codex protocol adapter。
- 升级 Codex 版本时需要重新检查目标 schema。
- Symphony 架构文档不应记录 Codex 协议字段全集。
- event forwarding、token accounting 和 timeout handling 需要根据目标协议实现，但不能改变 orchestrator 边界。

## 来源

- `SPEC.md` §10
- `SPEC.md` §17.5
