---
name: dsh-agent-os-planning
description: 面向 Agent OS 规划 Loop 的专家技能：任务依赖图编译、校验与人工批准 / Expert skill for the Agent OS Planning Loop: task dependency graph compilation, validation, and human approval
---

# Agent OS 规划 Loop / Agent OS Planning Loop

本技能指导在 Agent OS 规划 Loop 中工作：把“走向 Agent OS”编译为可校验的任务依赖图，运行严格校验，并把人工批准绑定到已验证图哈希。始终记住：规划批准不等于执行授权。

This skill guides work in the Agent OS Planning Loop: compiling "moving toward Agent OS" into a verifiable task dependency graph, running strict validation, and binding human approval to the verified graph hash. Always remember: plan approval is not execution authorization.

## When to use / 何时使用

需要初始化、检查、推进或批准 Agent OS 规划图，或校验任务依赖、能力覆盖与无环性时。

Use when initializing, inspecting, advancing, or approving an Agent OS planning graph, or validating dependencies, capability coverage, and acyclicity.

## Workflow / 工作流

1. 阅读 `specs/Agent-OS-Planning-Loop-v0.1.md`，确认不变量与任务图。
2. 用 `runner/agent_os_planner.ps1` 执行 `Initialize` 生成规划实例。
3. 用 `Inspect` / `Advance` 校验 Schema、边界、依赖、无环与就绪门。
4. 人工检查 `plan.json` 后执行 `Approve`；之后如需开始建设，单独创建实施 TaskContract。
5. 用 `tests/AgentOSPlanningLoop.Tests.ps1` 回归验证。

1. Read `specs/Agent-OS-Planning-Loop-v0.1.md` to confirm invariants and the task graph.
2. Run `Initialize` via `runner/agent_os_planner.ps1` to create the plan instance.
3. Validate schema, boundaries, dependencies, acyclicity, and readiness with `Inspect` / `Advance`.
4. After a human reviews `plan.json`, run `Approve`; to start building, create a separate implementation TaskContract.
5. Regress with `tests/AgentOSPlanningLoop.Tests.ps1`.

## References / 参考

- 项目 README: 见仓库根目录
- 作者: h565656445 (GitHub)