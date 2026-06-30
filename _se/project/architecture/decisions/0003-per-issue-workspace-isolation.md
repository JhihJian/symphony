# 0003 Per-Issue Workspace Isolation

## 状态

目标状态；当前项目已有实现代码（主要在 `elixir/`），但本次架构基线尚未逐项完成代码一致性审计可验证。

## 背景

Symphony 会启动 coding agent。agent 可能执行 shell 命令、读取文件和修改仓库内容，因此系统至少需要保证一个 issue 的运行不会随意落到其他 issue 或主机任意目录中。

workspace 还承担恢复和排查作用：重试、continuation 和人工检查都需要能回到同一个 issue 的工作目录。

## 决策

每个 issue identifier 映射到确定性的 per-issue workspace。workspace directory name 必须先安全转换，workspace path 必须在规范化后仍位于 workspace root 内。

agent 启动前必须验证当前进程工作目录就是该 issue 的 workspace。workspace 跨 run 保留；成功运行不自动删除。终止状态 issue 在启动清理和运行中状态转换时触发 cleanup。

## 影响

- agent side effects 被限制在 per-issue workspace 边界内。
- retry 和 continuation 可以复用已有上下文。
- 路径规范化和 root containment 是 mandatory invariant。
- workspace isolation 不是完整 sandbox，不能替代 approval、sandbox、网络限制或部署隔离。
- workspace 内容准备策略仍待具体实现记录。

## 来源

- `SPEC.md` §4.2
- `SPEC.md` §8.6
- `SPEC.md` §9
- `SPEC.md` §15.2
