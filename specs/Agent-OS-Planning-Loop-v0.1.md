---
type: specification
status: active
created: 2026-07-17
updated: 2026-07-17
---

# Agent OS 规划 Loop v0.1

## 结论

Hermes Harness 先用独立的规划 Loop 把“走向 Agent OS”编译成可校验的任务依赖图，再由人批准路线。规划批准不等于任务执行授权；每个实施任务仍需另行生成 TaskContract、经过权限门并留下证据。

## 公开接口

唯一入口：`runner/agent_os_planner.ps1`。

```text
Initialize -> Advance -> waiting_for_approval -> Approve
                    \
                     -> repairing -> Advance -> waiting_for_approval / failed
```

- `Initialize`：生成八个 Agent OS 建设任务，只写本地规划实例。
- `Inspect`：读取当前规划、验证结果、循环预算与审批状态。
- `Advance`：校验 Schema、项目边界、能力覆盖、依赖存在性、无环性和最终就绪门。
- `Approve`：把人工批准绑定到已验证任务图的 SHA-256。

## 不变量

- 对外业务项目仍只有小说、剪辑、视频、内容审计、数据收集。
- 规划实例属于 Harness 基础设施，不创建第六个业务项目。
- `execution_authorized` 永远为 `false`；批准路线不能自动启动实施任务。
- Loop 最多校验两次，只允许一次修复请求；第二次仍失败即停止。
- 改动已批准任务图会使批准失效，必须重新校验和批准。
- 核心规则、自我进化、发布、账号、付款和不可逆动作始终保留人工门。

## Agent OS 任务图

| ID | 任务 | 依赖 | 直达能力 |
|---|---|---|---|
| AOS-001 | 固化运行内核 | - | 任务生命周期、账本、恢复 |
| AOS-002 | 统一 Worker 协议 | AOS-001 | Agent/Skill/工具适配 |
| AOS-003 | 任务图调度与恢复 | AOS-001、002 | DAG、并发、幂等、重试 |
| AOS-004 | 可观测性、成本与质量 | AOS-001 | 事件、预算、质量门 |
| AOS-005 | 受控记忆与治理 | AOS-001、004 | 记忆分层、权限、审计 |
| AOS-006 | 五项目适配与垂直切片 | AOS-002、003、004 | 跨项目执行 |
| AOS-007 | 受控自我进化候选闭环 | AOS-003、004、005 | 提案、离线验证、人工晋级 |
| AOS-008 | Agent OS 就绪门 | AOS-005、006、007 | 证据化最终验收 |

AOS-008 必须传递依赖其余全部任务，因此“自我进化”不会越过运行、调度、可观测和治理基础。

## 使用方式

初始化一张真实规划图：

```powershell
pwsh -File .\10-项目\Hermes-Harness\runner\agent_os_planner.ps1 `
  -Action Initialize `
  -Objective "把 Hermes Harness 逐步建设为受控 Agent OS" `
  -AsJson
```

记下返回的 `run_path`，运行校验：

```powershell
pwsh -File .\10-项目\Hermes-Harness\runner\agent_os_planner.ps1 `
  -Action Advance `
  -RunPath "<run_path>" `
  -AsJson
```

状态为 `waiting_for_approval` 后，检查该目录的 `plan.json`，再批准路线：

```powershell
pwsh -File .\10-项目\Hermes-Harness\runner\agent_os_planner.ps1 `
  -Action Approve `
  -RunPath "<run_path>" `
  -AsJson
```

批准后若要开始建设，应从 AOS-001 单独创建实施 TaskContract；本规划器不会自行执行。

返回：[[10-项目/Hermes-Harness/README|Hermes Harness]]。
