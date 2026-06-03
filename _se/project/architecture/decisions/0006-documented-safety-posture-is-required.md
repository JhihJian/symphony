# 0006 Documented Safety Posture Is Required

## 状态

目标状态，具体实现策略待确认。

## 背景

Symphony 会把来自 repository、issue tracker 和 workflow prompt 的输入交给 coding agent。agent 可能执行命令、改文件、调用工具或接触敏感凭据。SPEC 明确不强制单一 approval、sandbox 或 operator-confirmation 策略，因为不同部署环境的信任边界不同。

仅有 per-issue workspace 隔离不足以覆盖所有风险。宽松审批、过宽的 tracker 权限、未隔离的网络访问或强权限主机环境，都可能导致数据泄露、破坏性修改或越权操作。

## 决策

每个实现必须记录自己的安全姿态，包括：

- 面向受信环境还是限制更严格的环境。
- approval、sandbox 和 user-input-required 信号如何处理。
- agent 可用工具、凭据、网络目标和文件系统范围如何限制。
- workflow hooks 被视为受信脚本时，如何控制超时、日志和失败。
- 可选 tracker tool 如果实现，如何限制认证来源和可访问范围。

这些策略不由当前 SPEC 统一规定，但它们不是可忽略的运维附录，而是 Symphony 安全模型的一部分。

## 影响

- 架构文档只能确认“必须记录安全姿态”，不能把某一种 approval/sandbox 配置写成已实现事实。
- 部署前需要补充 implementation/deployment 级安全说明。
- workspace path validation 是必要基础，但不能替代审批、沙箱、凭据范围和外部隔离。
- 可选工具扩展需要最小权限原则，否则会扩大 agent 对 tracker 或主机环境的影响面。

## 来源

- `SPEC.md` §10.5
- `SPEC.md` §15.1
- `SPEC.md` §15.2
- `SPEC.md` §15.3
- `SPEC.md` §15.4
- `SPEC.md` §15.5
