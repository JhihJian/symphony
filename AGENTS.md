# Symphony Repository Guide

本文件是仓库源码根目录的代理工作说明。若你是在 `/data/dev/symphony`
管理根下工作，还必须同时遵守管理根自己的 `/data/dev/symphony/AGENTS.md`。

## 仓库结构

```text
.
├── README.md        # 项目概览
├── SPEC.md          # 行为和配置规范
├── DEPLOY.md        # systemd template 部署说明
├── scripts/         # 部署和运维脚本
├── elixir/          # Symphony Elixir 实现
└── _se/             # 项目架构和工程记录
```

## 工作规则

- 根目录主要存放项目级文档、部署脚本和规范；核心实现位于 `elixir/`。
- 修改 `elixir/` 下的代码、测试或实现文档前，先阅读 `elixir/AGENTS.md`。
- 行为、配置或部署语义变化需要同步评估 `SPEC.md`、`README.md`、`DEPLOY.md`
  和 `elixir/README.md` 是否需要更新。
- 保持变更范围收敛；不要把日常巡检报告、运行日志或本机私有配置提交到仓库。

## 验证

- Elixir 实现的完整质量门禁见 `elixir/AGENTS.md`。
- 仅修改根目录文档时，至少检查 Markdown 链接、路径和命令示例是否仍然准确。
