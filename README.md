# dsh-agent-os-planning

<!-- DeepSeek Harness 衍生声明 -->
> **DeepSeek Harness 个人适配声明（Personal Adaptation Notice）**
>
> 本项目是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的**个人适配产物（personal adaptation）**，**并非 DeepSeek Harness 官方文件（not an official DeepSeek Harness file）**，随附功能、使用说明与个人产物（bundled with features, documentation, and personal artifacts），可与 DeepSeek Harness 搭配使用，也可独立使用。
>
> This project is a **personal adaptation** for DeepSeek Harness, and is **NOT an official DeepSeek Harness file**, bundled with features, documentation, and personal artifacts. It can be used alongside DeepSeek Harness or standalone.

**作者 / Author**: [h565656445](https://github.com/h565656445)

**合作 / Collaboration**: 如有项目可以一起合作，欢迎联系。微信：`wohaishihenshuaide`。If you have projects, let's collaborate. WeChat: `wohaishihenshuaide`.


---

## 用途 / What this is for

Agent OS 规划 Loop：把长期目标编译为有依赖的建设任务图，校验失败最多返修一次，人工批准绑定任务图哈希。

Agent OS planning loop: compiles long-term goals into a dependency-ordered task graph, repairs at most once, and binds human approval to the graph hash.

---
## Agent OS Planning Loop v0.1 / Agent OS 规划 Loop v0.1

Agent OS 规划 Loop 先把“走向 Agent OS”编译成可校验的任务依赖图（AOS-001..AOS-008），再由人批准路线。规划批准不等于任务执行授权；每个实施任务仍需另行生成 TaskContract、经过权限门并留下证据。`execution_authorized` 永远为 false。

The Agent OS Planning Loop first compiles "moving toward Agent OS" into a verifiable task dependency graph (AOS-001..AOS-008), then a human approves the route. Plan approval is not task execution authorization; every implementation task still needs its own TaskContract, permission gates, and evidence. `execution_authorized` is always false.

## Features / 功能

- **八任务依赖图**：`Initialize` 生成 AOS-001..AOS-008 建设任务，覆盖依赖与直达能力。
- **严格校验**：`Advance` 校验 Schema、项目边界、能力覆盖、依赖存在性、无环性与最终就绪门。
- **人工批准绑定哈希**：`Approve` 把人工批准绑定到已验证任务图的 SHA-256，改动即失效。
- **有界循环**：最多校验两次、只允许一次修复请求，第二次仍失败即停止。
- **授权分离**：`execution_authorized` 永远为 false，批准路线不能自动启动实施任务。
- **人工门保留**：核心规则、自我进化、发布、账号、付款和不可逆动作始终保留人工门。

- **Eight-task dependency graph**: `Initialize` generates the AOS-001..AOS-008 build tasks with dependencies and direct capabilities.
- **Strict validation**: `Advance` checks schema, project boundaries, capability coverage, dependency existence, acyclicity, and the final readiness gate.
- **Human approval bound to hash**: `Approve` binds approval to the verified graph SHA-256; any change invalidates it.
- **Bounded loop**: at most two validations and one repair request; a second failure stops.
- **Authorization separation**: `execution_authorized` stays false; approved routes never auto-start implementation tasks.
- **Human gates preserved**: core rules, self-evolution, publishing, accounts, payments, and irreversible actions always keep a human gate.

## What's inside / 目录结构

```text
dsh-agent-os-planning/
├── README.md                      # 双语说明（本文件）
├── LICENSE                        # MIT
├── src/AgentOSPlanning.psm1       # 规划 Loop 模块（依赖图编译、校验、批准）
├── runner/agent_os_planner.ps1    # 唯一公开入口（Initialize/Inspect/Advance/Approve）
├── schemas/agent_os_plan.schema.json          # 规划实例 Schema
├── specs/Agent-OS-Planning-Loop-v0.1.md       # 规划 Loop 规格
├── tests/AgentOSPlanningLoop.Tests.ps1        # Pester 5 测试
└── .dsh/                          # DeepSeek Harness 衍生包
```

## Quick start / 快速开始

```powershell
# Initialize：生成 AOS-001..AOS-008 规划图
pwsh -File .\runner\agent_os_planner.ps1 -Action Initialize `
  -Objective "把 Hermes Harness 逐步建设为受控 Agent OS" -AsJson

# Inspect：读取当前规划、验证结果与审批状态
pwsh -File .\runner\agent_os_planner.ps1 -Action Inspect -RunPath "<run_path>" -AsJson

# Advance：校验规划图（Schema、边界、依赖、无环、就绪门）
pwsh -File .\runner\agent_os_planner.ps1 -Action Advance -RunPath "<run_path>" -AsJson

# Approve：把人工批准绑定到已验证图哈希
pwsh -File .\runner\agent_os_planner.ps1 -Action Approve -RunPath "<run_path>" -AsJson

# 运行测试（Pester 5）
Invoke-Pester .\tests\AgentOSPlanningLoop.Tests.ps1
```

## DeepSeek Harness 衍生 / DSH Derivative

本项目附带 DeepSeek Harness 衍生包，位于 `.dsh/` 目录：

- `preset.yml` — Agent 预设元数据
- `agent.cordis.yml` — Cordis 组装（基于 standard 预设，persona 已定制）
- `skills/dsh-agent-os-planning/SKILL.md` — 项目专属技能（skill）

安装与接入方式见 [`.dsh/README.md`](.dsh/README.md)（双语）。

## License / 许可证

[MIT](LICENSE)