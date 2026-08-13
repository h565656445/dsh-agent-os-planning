$ErrorActionPreference = 'Stop'

# Pester 5 兼容化：初始化与辅助函数移入 BeforeAll（Discovery/Run 作用域隔离），
# 候选验证经 HERMES_HARNESS_ROOT 注入真实项目根；晋级后 $PSScriptRoot 兜底，行为等价。
BeforeAll {

    $script:HarnessRoot = $env:HERMES_HARNESS_ROOT
    if (-not $script:HarnessRoot) {
        $script:HarnessRoot = Split-Path -Parent $PSScriptRoot
    }
    $projectRoot = $script:HarnessRoot
$script:runnerScriptPath = Join-Path $projectRoot 'runner\agent_os_planner.ps1'
$script:schemaPath = Join-Path $projectRoot 'schemas\agent_os_plan.schema.json'
$script:runner = {
    [CmdletBinding()]
    param(
        [string]$Action,
        [string]$Objective,
        [string]$RuntimeRoot,
        [string]$RunPath,
        [switch]$AsJson
    )

    $arguments = @{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        $arguments[$entry.Key] = $entry.Value
    }
    if ($RunPath -and -not $RuntimeRoot) {
        $arguments.RuntimeRoot = Split-Path -Parent $RunPath
    }
    & $script:runnerScriptPath @arguments
}

function New-TestAgentOSPlan {
    param([string]$RuntimeRoot)

    $json = & $runner `
        -Action Initialize `
        -Objective '把 Hermes Harness 逐步建设为受控 Agent OS' `
        -RuntimeRoot $RuntimeRoot `
        -AsJson
    return $json | ConvertFrom-Json -Depth 50
}

}

Describe 'Agent OS planning loop public interface' {
    It 'creates a bounded, non-executing Agent OS task graph' {
        $result = New-TestAgentOSPlan -RuntimeRoot (Join-Path $TestDrive 'runtime')

        $result.state | Should -Be 'draft'
        $result.target | Should -Be 'agent_os'
        $result.task_count | Should -Be 8
        $result.execution_authorized | Should -Be $false
        Test-Path -LiteralPath $result.plan_path | Should -Be $true
        Test-Path -LiteralPath (Join-Path $result.run_path 'ledger.jsonl') | Should -Be $true

        $planJson = Get-Content -LiteralPath $result.plan_path -Raw
        ($planJson | Test-Json -SchemaFile $script:schemaPath) | Should -Be $true
        $plan = $planJson | ConvertFrom-Json -Depth 50
        $plan.loop_policy.max_attempts | Should -Be 2
        $plan.loop_policy.max_repairs | Should -Be 1
        @($plan.constraints.business_projects).Count | Should -Be 4
        (@($plan.constraints.business_projects) -join ',') | Should -Be '小说,AI内容创作,内容审计,数据收集'
        @($plan.tasks | Where-Object { $_.task_id -eq 'AOS-008' }).Count | Should -Be 1
    }

    It 'validates the task graph before requesting human approval' {
        $result = New-TestAgentOSPlan -RuntimeRoot (Join-Path $TestDrive 'runtime')

        $advanced = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50

        $advanced.state | Should -Be 'waiting_for_approval'
        $advanced.valid | Should -Be $true
        $advanced.loop_attempts | Should -Be 1
        $advanced.pending_gate | Should -Be 'agent_os_plan'
        $advanced.execution_authorized | Should -Be $false
        (Get-Content -LiteralPath (Join-Path $result.run_path 'ledger.jsonl')).Count | Should -Be 2
    }

    It 'allows one repair cycle and then fails closed on a still-invalid graph' {
        $result = New-TestAgentOSPlan -RuntimeRoot (Join-Path $TestDrive 'runtime')
        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.tasks[0].depends_on = @('AOS-MISSING')
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8

        $first = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $first.state | Should -Be 'repairing'
        $first.valid | Should -Be $false
        $first.loop_attempts | Should -Be 1
        $first.repairs_requested | Should -Be 1
        Test-Path -LiteralPath (Join-Path $result.run_path 'repair_request.json') | Should -Be $true

        $second = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $second.state | Should -Be 'failed'
        $second.loop_attempts | Should -Be 2
        $second.repairs_requested | Should -Be 1
    }

    It 'enforces code-owned loop limits when the persisted budget is inflated' {
        $result = New-TestAgentOSPlan -RuntimeRoot (Join-Path $TestDrive 'budget-runtime')
        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.loop_policy.max_attempts = 99
        $plan.loop_policy.max_repairs = 99
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8

        $first = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $first.state | Should -Be 'repairing'
        $first.loop_attempts | Should -Be 1
        $first.repairs_requested | Should -Be 1

        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.loop_policy.attempts = -99
        $plan.loop_policy.repairs_requested = -99
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8
        $second = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $second.state | Should -Be 'failed'
        $second.loop_attempts | Should -Be 2
        $second.repairs_requested | Should -Be 1

        $third = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $third.state | Should -Be 'failed'
        $third.loop_attempts | Should -Be 2
        $third.repairs_requested | Should -Be 1
    }

    It 'routes a structurally incomplete contract through repair and failure with ledger evidence' {
        $result = New-TestAgentOSPlan -RuntimeRoot (Join-Path $TestDrive 'schema-runtime')
        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.PSObject.Properties.Remove('constraints')
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8

        $first = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $first.state | Should -Be 'repairing'
        $first.loop_attempts | Should -Be 1
        Test-Path -LiteralPath (Join-Path $result.run_path 'repair_request.json') | Should -Be $true

        $second = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $second.state | Should -Be 'failed'
        $second.loop_attempts | Should -Be 2
        (Get-Content -LiteralPath (Join-Path $result.run_path 'ledger.jsonl')).Count | Should -Be 3
    }

    It 'repairs missing control-envelope fields inside the bounded loop' {
        foreach ($field in @('plan_id', 'state', 'loop_policy', 'approval', 'last_validation')) {
            $runtimeRoot = Join-Path $TestDrive ("envelope-$field")
            $result = New-TestAgentOSPlan -RuntimeRoot $runtimeRoot
            $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
            $plan.PSObject.Properties.Remove($field)
            $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8

            $first = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
            $first.state | Should -Be 'repairing'
            $first.valid | Should -Be $false
            $first.loop_attempts | Should -Be 1
            $first.repairs_requested | Should -Be 1
            Test-Path -LiteralPath (Join-Path $result.run_path 'repair_request.json') | Should -Be $true

            $second = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
            $second.state | Should -Be 'waiting_for_approval'
            $second.valid | Should -Be $true
            $second.loop_attempts | Should -Be 2
            (Get-Content -LiteralPath (Join-Path $result.run_path 'ledger.jsonl')).Count | Should -Be 4
        }
    }

    It 'accepts a repaired graph within the single repair allowance' {
        $result = New-TestAgentOSPlan -RuntimeRoot (Join-Path $TestDrive 'runtime')
        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $originalDependencies = @($plan.tasks[0].depends_on)
        $plan.tasks[0].depends_on = @('AOS-MISSING')
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8
        $null = & $script:runner -Action Advance -RunPath $result.run_path -AsJson

        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.tasks[0].depends_on = $originalDependencies
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8
        $advanced = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50

        $advanced.state | Should -Be 'waiting_for_approval'
        $advanced.valid | Should -Be $true
        $advanced.loop_attempts | Should -Be 2
    }

    It 'binds approval to the reviewed graph and invalidates it after drift' {
        $result = New-TestAgentOSPlan -RuntimeRoot (Join-Path $TestDrive 'runtime')
        $null = & $script:runner -Action Advance -RunPath $result.run_path -AsJson
        $approved = & $script:runner -Action Approve -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50

        $approved.state | Should -Be 'approved'
        $approved.approval_status | Should -Be 'approved'
        $approved.execution_authorized | Should -Be $false

        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.tasks[0].title = '被修改的任务标题'
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8
        $inspected = & $script:runner -Action Inspect -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50

        $inspected.state | Should -Be 'draft'
        $inspected.approval_status | Should -Be 'pending'

        $drifted = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50

        $drifted.state | Should -Be 'waiting_for_approval'
        $drifted.approval_status | Should -Be 'pending'
        $drifted.pending_gate | Should -Be 'agent_os_plan'
    }

    It 'revalidates the full contract instead of trusting persisted validation fields' {
        $result = New-TestAgentOSPlan -RuntimeRoot (Join-Path $TestDrive 'approval-runtime')
        $null = & $script:runner -Action Advance -RunPath $result.run_path -AsJson
        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.PSObject.Properties.Remove('created_at')
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8

        $threw = $false
        try {
            $null = & $script:runner -Action Approve -RunPath $result.run_path -AsJson
        }
        catch {
            $threw = $true
        }

        $threw | Should -Be $true
        $persisted = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $persisted.approval.status | Should -Be 'pending'
    }

    It 'persists safe recovery and restarts the bounded loop when an approved envelope is corrupted' {
        $result = New-TestAgentOSPlan -RuntimeRoot (Join-Path $TestDrive 'approved-envelope-runtime')
        $null = & $script:runner -Action Advance -RunPath $result.run_path -AsJson
        $null = & $script:runner -Action Approve -RunPath $result.run_path -AsJson
        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.execution_authorized = $true
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8

        $inspected = & $script:runner -Action Inspect -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $inspected.state | Should -Be 'draft'
        $inspected.approval_status | Should -Be 'pending'
        $inspected.execution_authorized | Should -Be $false
        $persisted = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $persisted.execution_authorized | Should -Be $false
        $persisted.approval.status | Should -Be 'pending'

        $first = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $first.state | Should -Be 'repairing'
        $first.loop_attempts | Should -Be 1
        $first.repairs_requested | Should -Be 1

        $second = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $second.state | Should -Be 'waiting_for_approval'
        $second.valid | Should -Be $true
        $second.loop_attempts | Should -Be 2
    }

    It 'does not reset the repair budget for envelope damage inside an unapproved revision' {
        $result = New-TestAgentOSPlan -RuntimeRoot (Join-Path $TestDrive 'unapproved-envelope-runtime')
        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.tasks[0].depends_on = @('AOS-MISSING')
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8
        $first = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $first.state | Should -Be 'repairing'
        $first.loop_attempts | Should -Be 1
        $first.repairs_requested | Should -Be 1

        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.PSObject.Properties.Remove('loop_policy')
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8
        $second = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50

        $second.state | Should -Be 'failed'
        $second.loop_attempts | Should -Be 2
        $second.repairs_requested | Should -Be 1
        @(
            Get-Content -LiteralPath (Join-Path $result.run_path 'ledger.jsonl') |
                ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } |
                Where-Object { $_.event -eq 'plan_repair_requested' }
        ).Count | Should -Be 1
    }

    It 'uses Ledger approval authority when an approved plan loses its approval field' {
        $result = New-TestAgentOSPlan -RuntimeRoot (Join-Path $TestDrive 'missing-approved-field-runtime')
        $null = & $script:runner -Action Advance -RunPath $result.run_path -AsJson
        $null = & $script:runner -Action Approve -RunPath $result.run_path -AsJson
        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.PSObject.Properties.Remove('approval')
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8

        $inspected = & $script:runner -Action Inspect -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $inspected.state | Should -Be 'draft'
        $inspected.approval_status | Should -Be 'pending'
        $inspected.loop_attempts | Should -Be 0

        $first = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $first.state | Should -Be 'repairing'
        $first.loop_attempts | Should -Be 1
        $first.repairs_requested | Should -Be 1
        $second = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $second.state | Should -Be 'waiting_for_approval'
        $second.valid | Should -Be $true
    }

    It 'does not let a draft forge approval to reset the current repair budget' {
        $result = New-TestAgentOSPlan -RuntimeRoot (Join-Path $TestDrive 'forged-approval-runtime')
        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.tasks[0].depends_on = @('AOS-MISSING')
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8
        $first = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50
        $first.state | Should -Be 'repairing'

        $plan = Get-Content -LiteralPath $result.plan_path -Raw | ConvertFrom-Json -Depth 50
        $plan.state = 'approved'
        $plan.approval.status = 'approved'
        $plan.approval.approved_at = [DateTimeOffset]::Now.ToString('o')
        $plan.approval.approved_sha256 = ('A' * 64)
        $plan | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $result.plan_path -Encoding utf8
        $second = & $script:runner -Action Advance -RunPath $result.run_path -AsJson | ConvertFrom-Json -Depth 50

        $second.state | Should -Be 'failed'
        $second.loop_attempts | Should -Be 2
        $second.repairs_requested | Should -Be 1
        @(
            Get-Content -LiteralPath (Join-Path $result.run_path 'ledger.jsonl') |
                ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } |
                Where-Object { $_.event -eq 'plan_repair_requested' }
        ).Count | Should -Be 1
    }

    It 'rejects credential-like objectives before creating runtime state' {
        $runtimeRoot = Join-Path $TestDrive 'credential-runtime'
        $threw = $false
        try {
            $null = & $script:runner `
                -Action Initialize `
                -Objective '构建 Agent OS，token=abc123secret' `
                -RuntimeRoot $runtimeRoot `
                -AsJson
        }
        catch {
            $threw = $true
        }

        $threw | Should -Be $true
        (Test-Path -LiteralPath $runtimeRoot) | Should -Be $false
    }
}
