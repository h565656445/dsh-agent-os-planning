Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$schemaPath = Join-Path $projectRoot 'schemas\agent_os_plan.schema.json'
Import-Module (Join-Path $PSScriptRoot 'HermesHarness.psm1') -Force

$businessProjects = @('小说', 'AI剪辑', '内容审计', '数据收集')
$requiredCapabilities = @(
    'runtime_kernel',
    'worker_protocol',
    'scheduling_recovery',
    'observability_cost_quality',
    'memory_governance',
    'project_adapters',
    'controlled_evolution',
    'readiness_gate'
)
$maxPlanningAttempts = 2
$maxPlanningRepairs = 1

function Get-NowText {
    return [DateTimeOffset]::Now.ToString('o')
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($InputObject.PSObject.Properties[$Name]) {
        $InputObject.$Name = $Value
    }
    else {
        $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$LiteralPath
    )

    $directory = Split-Path -Parent $LiteralPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $json = $InputObject | ConvertTo-Json -Depth 50
    [IO.File]::WriteAllText($LiteralPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Agent OS plan file not found: $LiteralPath"
    }
    return Get-Content -LiteralPath $LiteralPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function Get-PlanCandidateHash {
    param([Parameter(Mandatory)]$Plan)

    $candidate = [ordered]@{
        schema_version = [string]$Plan.schema_version
        objective = [string]$Plan.objective
        target = [string]$Plan.target
        execution_authorized = [bool]$Plan.execution_authorized
        constraints = $Plan.constraints
        capability_targets = @($Plan.capability_targets)
        tasks = @($Plan.tasks)
        loop_policy = [ordered]@{
            max_attempts = [int]$Plan.loop_policy.max_attempts
            max_repairs = [int]$Plan.loop_policy.max_repairs
        }
    }
    return Get-TextSha256 -Text ($candidate | ConvertTo-Json -Depth 50 -Compress)
}

function Add-LedgerEvent {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Event,
        [hashtable]$Details = @{}
    )

    $entry = [ordered]@{
        timestamp = Get-NowText
        plan_id = [string]$Plan.plan_id
        event = $Event
        state = [string]$Plan.state
        details = $Details
    }
    $line = $entry | ConvertTo-Json -Depth 20 -Compress
    Add-Content -LiteralPath (Join-Path $BasePath 'ledger.jsonl') -Value $line -Encoding utf8
}

function Get-PlanLoopUsage {
    param([Parameter(Mandatory)][string]$BasePath)

    $attemptEvents = @('plan_validated', 'plan_repair_requested', 'plan_validation_failed')
    $attempts = 0
    $repairs = 0
    $approvalActive = $false
    $ledgerPath = Join-Path $BasePath 'ledger.jsonl'
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $ledgerPath) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $entry = $line | ConvertFrom-Json -Depth 20
            }
            catch {
                throw 'Agent OS planning ledger contains an unreadable event.'
            }
            if ([string]$entry.event -in $attemptEvents) {
                $attempts++
            }
            if ([string]$entry.event -eq 'plan_repair_requested') {
                $repairs++
            }
            if ([string]$entry.event -eq 'plan_approved') {
                $approvalActive = $true
            }
            $approvedEnvelopeRevision = [string]$entry.event -eq 'plan_control_envelope_recovered' -and [bool]$entry.details.approval_invalidated
            if ($approvalActive -and ([string]$entry.event -eq 'plan_approval_invalidated' -or $approvedEnvelopeRevision)) {
                $attempts = 0
                $repairs = 0
                $approvalActive = $false
            }
        }
    }
    return [pscustomobject]@{
        attempts = $attempts
        repairs = $repairs
        approval_active = $approvalActive
    }
}

function Save-Plan {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)]$Plan
    )

    Set-ObjectProperty -InputObject $Plan -Name 'updated_at' -Value (Get-NowText)
    Write-JsonFile -InputObject $Plan -LiteralPath (Join-Path $BasePath 'plan.json')
}

function Repair-PlanControlEnvelope {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)]$Plan
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    $usage = Get-PlanLoopUsage -BasePath $BasePath
    $directoryPlanId = Split-Path -Leaf $BasePath

    if (-not $Plan.PSObject.Properties['plan_id'] -or [string]::IsNullOrWhiteSpace([string]$Plan.plan_id)) {
        Set-ObjectProperty -InputObject $Plan -Name 'plan_id' -Value $directoryPlanId
        $issues.Add('控制信封缺少 plan_id，已从受控运行目录恢复。')
    }
    elseif ([string]$Plan.plan_id -ne $directoryPlanId) {
        throw 'Agent OS plan directory does not match plan_id.'
    }

    if (-not $Plan.PSObject.Properties['updated_at']) {
        Set-ObjectProperty -InputObject $Plan -Name 'updated_at' -Value (Get-NowText)
        $issues.Add('控制信封缺少 updated_at，已恢复安全时间戳。')
    }
    if (-not $Plan.PSObject.Properties['state'] -or [string]$Plan.state -notin @('draft', 'evaluating', 'repairing', 'waiting_for_approval', 'approved', 'failed')) {
        Set-ObjectProperty -InputObject $Plan -Name 'state' -Value 'draft'
        $issues.Add('控制信封缺少或包含无效 state，已恢复为 draft。')
    }
    if (-not $Plan.PSObject.Properties['execution_authorized'] -or [bool]$Plan.execution_authorized) {
        Set-ObjectProperty -InputObject $Plan -Name 'execution_authorized' -Value $false
        $issues.Add('控制信封缺少或篡改 execution_authorized，已强制恢复为 false。')
    }

    $loopPolicy = if ($Plan.PSObject.Properties['loop_policy'] -and $null -ne $Plan.loop_policy -and $Plan.loop_policy.PSObject.Properties['max_attempts']) {
        $Plan.loop_policy
    }
    else {
        $replacement = [pscustomobject][ordered]@{
            max_attempts = $maxPlanningAttempts
            max_repairs = $maxPlanningRepairs
            attempts = [int]$usage.attempts
            repairs_requested = [int]$usage.repairs
        }
        Set-ObjectProperty -InputObject $Plan -Name 'loop_policy' -Value $replacement
        $issues.Add('控制信封缺少 loop_policy，已按代码硬上限和 Ledger 用量恢复。')
        $replacement
    }
    foreach ($property in @(
        @{ name = 'max_attempts'; value = $maxPlanningAttempts },
        @{ name = 'max_repairs'; value = $maxPlanningRepairs },
        @{ name = 'attempts'; value = [int]$usage.attempts },
        @{ name = 'repairs_requested'; value = [int]$usage.repairs }
    )) {
        if (-not $loopPolicy.PSObject.Properties[$property.name]) {
            Set-ObjectProperty -InputObject $loopPolicy -Name $property.name -Value $property.value
            $issues.Add("控制信封的 loop_policy 缺少 $($property.name)，已安全恢复。")
        }
    }

    $approval = if ($Plan.PSObject.Properties['approval'] -and $null -ne $Plan.approval -and $Plan.approval.PSObject.Properties['status']) {
        $Plan.approval
    }
    else {
        $replacement = [pscustomobject][ordered]@{ status = 'pending'; approved_at = $null; approved_sha256 = $null }
        Set-ObjectProperty -InputObject $Plan -Name 'approval' -Value $replacement
        $issues.Add('控制信封缺少 approval，已恢复为 pending。')
        $replacement
    }
    if ([string]$approval.status -notin @('pending', 'approved')) {
        Set-ObjectProperty -InputObject $approval -Name 'status' -Value 'pending'
        $issues.Add('控制信封包含无效 approval.status，已恢复为 pending。')
    }
    foreach ($name in @('approved_at', 'approved_sha256')) {
        if (-not $approval.PSObject.Properties[$name]) {
            Set-ObjectProperty -InputObject $approval -Name $name -Value $null
            $issues.Add("控制信封的 approval 缺少 $name，已安全恢复。")
        }
    }

    $lastValidation = if ($Plan.PSObject.Properties['last_validation'] -and $null -ne $Plan.last_validation -and $Plan.last_validation.PSObject.Properties['valid']) {
        $Plan.last_validation
    }
    else {
        $replacement = [pscustomobject][ordered]@{ valid = $null; errors = @(); evaluated_at = $null; candidate_sha256 = $null }
        Set-ObjectProperty -InputObject $Plan -Name 'last_validation' -Value $replacement
        $issues.Add('控制信封缺少 last_validation，已恢复为空验证状态。')
        $replacement
    }
    foreach ($property in @(
        @{ name = 'errors'; value = @() },
        @{ name = 'evaluated_at'; value = $null },
        @{ name = 'candidate_sha256'; value = $null }
    )) {
        if (-not $lastValidation.PSObject.Properties[$property.name]) {
            Set-ObjectProperty -InputObject $lastValidation -Name $property.name -Value $property.value
            $issues.Add("控制信封的 last_validation 缺少 $($property.name)，已安全恢复。")
        }
    }

    return @($issues)
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$CandidatePath
    )

    $root = [IO.Path]::GetFullPath($RootPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath($CandidatePath)
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-PlanContext {
    param(
        [Parameter(Mandatory)][string]$RequestedRunPath,
        [Parameter(Mandatory)][string]$RuntimeRoot
    )

    $basePath = [IO.Path]::GetFullPath($RequestedRunPath)
    $rootPath = [IO.Path]::GetFullPath($RuntimeRoot)
    if (-not (Test-PathWithinRoot -RootPath $rootPath -CandidatePath $basePath)) {
        throw 'Agent OS plan path must remain inside the configured runtime root.'
    }
    if (-not (Test-Path -LiteralPath $basePath -PathType Container)) {
        throw "Agent OS plan directory not found: $basePath"
    }

    $planPath = Join-Path $basePath 'plan.json'
    $plan = Read-JsonFile -LiteralPath $planPath
    $envelopeErrors = @(Repair-PlanControlEnvelope -BasePath $basePath -Plan $plan)

    return [pscustomobject]@{
        base_path = $basePath
        plan_path = $planPath
        plan = $plan
        envelope_errors = $envelopeErrors
    }
}

function Test-PlanSchema {
    param([Parameter(Mandatory)]$Plan)

    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        throw "Agent OS plan schema not found: $schemaPath"
    }
    $json = $Plan | ConvertTo-Json -Depth 50
    return $json | Test-Json -SchemaFile $schemaPath -ErrorAction Stop
}

function Get-TaskDependencyClosure {
    param(
        [Parameter(Mandatory)][hashtable]$TaskMap,
        [Parameter(Mandatory)][string]$TaskId,
        [hashtable]$Visited = @{}
    )

    foreach ($dependency in @($TaskMap[$TaskId].depends_on)) {
        $dependencyId = [string]$dependency
        if (-not $TaskMap.ContainsKey($dependencyId)) {
            continue
        }
        if (-not $Visited.ContainsKey($dependencyId)) {
            $Visited[$dependencyId] = $true
            Get-TaskDependencyClosure -TaskMap $TaskMap -TaskId $dependencyId -Visited $Visited
        }
    }
}

function Test-TaskGraphCycle {
    param(
        [Parameter(Mandatory)][hashtable]$TaskMap,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][hashtable]$Colors
    )

    $Colors[$TaskId] = 'gray'
    foreach ($dependency in @($TaskMap[$TaskId].depends_on)) {
        $dependencyId = [string]$dependency
        if (-not $TaskMap.ContainsKey($dependencyId)) {
            continue
        }
        if ($Colors[$dependencyId] -eq 'gray') {
            return $true
        }
        if ($Colors[$dependencyId] -ne 'black' -and (Test-TaskGraphCycle -TaskMap $TaskMap -TaskId $dependencyId -Colors $Colors)) {
            return $true
        }
    }
    $Colors[$TaskId] = 'black'
    return $false
}

function Test-AgentOSPlan {
    param(
        [Parameter(Mandatory)]$Plan,
        [string[]]$PreflightErrors = @()
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($preflightError in @($PreflightErrors)) {
        if (-not [string]::IsNullOrWhiteSpace($preflightError)) {
            $errors.Add($preflightError)
        }
    }
    try {
        if (-not (Test-PlanSchema -Plan $Plan)) {
            $errors.Add('计划未通过 JSON Schema。')
        }
    }
    catch {
        $errors.Add("Schema 校验失败：$($_.Exception.Message)")
    }

    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            valid = $false
            errors = @($errors)
        }
    }

    if ([string]$Plan.target -ne 'agent_os') {
        $errors.Add('规划目标必须是 agent_os。')
    }
    if ([bool]$Plan.execution_authorized) {
        $errors.Add('规划合同不得授权自动执行。')
    }

    $actualProjects = @($Plan.constraints.business_projects | Sort-Object)
    $expectedProjects = @($businessProjects | Sort-Object)
    if ($actualProjects.Count -ne $expectedProjects.Count -or (Compare-Object $actualProjects $expectedProjects)) {
        $errors.Add('业务项目边界必须严格保持为四个项目。')
    }

    $tasks = @($Plan.tasks)
    $taskMap = @{}
    foreach ($task in $tasks) {
        $taskId = [string]$task.task_id
        if ($taskMap.ContainsKey($taskId)) {
            $errors.Add("任务 ID 重复：$taskId")
            continue
        }
        $taskMap[$taskId] = $task
    }

    foreach ($task in $tasks) {
        $taskId = [string]$task.task_id
        foreach ($dependency in @($task.depends_on)) {
            $dependencyId = [string]$dependency
            if ($dependencyId -eq $taskId) {
                $errors.Add("任务 $taskId 不能依赖自身。")
            }
            elseif (-not $taskMap.ContainsKey($dependencyId)) {
                $errors.Add("任务 $taskId 引用了不存在的依赖 $dependencyId。")
            }
        }
    }

    $colors = @{}
    foreach ($taskId in $taskMap.Keys) {
        $colors[$taskId] = 'white'
    }
    foreach ($taskId in $taskMap.Keys) {
        if ($colors[$taskId] -eq 'white' -and (Test-TaskGraphCycle -TaskMap $taskMap -TaskId $taskId -Colors $colors)) {
            $errors.Add('任务图存在循环依赖。')
            break
        }
    }

    $coveredCapabilities = @($tasks.capabilities | ForEach-Object { $_ } | Sort-Object -Unique)
    foreach ($capability in $requiredCapabilities) {
        if ($coveredCapabilities -notcontains $capability) {
            $errors.Add("缺少 Agent OS 能力：$capability")
        }
    }

    $readinessTasks = @($tasks | Where-Object { @($_.capabilities) -contains 'readiness_gate' })
    if ($readinessTasks.Count -ne 1) {
        $errors.Add('必须且只能有一个 Agent OS 就绪门任务。')
    }
    elseif ($taskMap.ContainsKey([string]$readinessTasks[0].task_id)) {
        $closure = @{}
        Get-TaskDependencyClosure -TaskMap $taskMap -TaskId ([string]$readinessTasks[0].task_id) -Visited $closure
        if ($closure.Count -ne ($tasks.Count - 1)) {
            $errors.Add('Agent OS 就绪门必须传递依赖其余所有任务。')
        }
    }

    return [pscustomobject]@{
        valid = ($errors.Count -eq 0)
        errors = @($errors)
    }
}

function New-AgentOSTasks {
    return @(
        [ordered]@{
            task_id = 'AOS-001'; phase = 1; title = '固化 Agent OS 运行内核'
            objective = '统一任务实例、状态生命周期、账本和恢复锚点。'
            depends_on = @(); capabilities = @('runtime_kernel')
            deliverables = @('Agent OS 运行合同', '统一任务生命周期与状态账本')
            acceptance = @('任一任务可从账本恢复最后可信状态', '终态不会被自动重派')
            status = 'proposed'; authority = 'human_approval_required'; project_scope = 'harness_infrastructure'
        },
        [ordered]@{
            task_id = 'AOS-002'; phase = 2; title = '统一 Worker 协议与适配器'
            objective = '让不同 Agent、Skill 和本机工具通过同一受控接口接单与回传证据。'
            depends_on = @('AOS-001'); capabilities = @('worker_protocol')
            deliverables = @('Worker 输入输出协议', '能力声明与权限适配器')
            acceptance = @('Worker 只接收最小必要上下文', '结果包含结构化状态和证据哈希')
            status = 'proposed'; authority = 'human_approval_required'; project_scope = 'harness_infrastructure'
        },
        [ordered]@{
            task_id = 'AOS-003'; phase = 3; title = '实现任务图调度与恢复'
            objective = '支持依赖图、并发限制、重试预算、暂停和崩溃恢复。'
            depends_on = @('AOS-001', 'AOS-002'); capabilities = @('scheduling_recovery')
            deliverables = @('DAG 调度器', '恢复与幂等策略')
            acceptance = @('循环依赖被拒绝', '中断后不会重复不可逆动作')
            status = 'proposed'; authority = 'human_approval_required'; project_scope = 'harness_infrastructure'
        },
        [ordered]@{
            task_id = 'AOS-004'; phase = 3; title = '建立可观测性、成本与质量门禁'
            objective = '让每次调用的耗时、成本、质量和失败原因可以追踪。'
            depends_on = @('AOS-001'); capabilities = @('observability_cost_quality')
            deliverables = @('统一事件与指标模型', '预算和质量门禁')
            acceptance = @('每个阶段都有可核验事件', '超预算或质量不合格时 fail closed')
            status = 'proposed'; authority = 'human_approval_required'; project_scope = 'harness_infrastructure'
        },
        [ordered]@{
            task_id = 'AOS-005'; phase = 4; title = '建立受控记忆与治理'
            objective = '区分任务状态、经验候选、项目规则和跨项目长期记忆。'
            depends_on = @('AOS-001', 'AOS-004'); capabilities = @('memory_governance')
            deliverables = @('记忆分层与晋级合同', '权限、审计和回滚规则')
            acceptance = @('单次经验不能自动晋级', '核心规则变更必须人工批准并可追溯')
            status = 'proposed'; authority = 'human_approval_required'; project_scope = 'harness_infrastructure'
        },
        [ordered]@{
            task_id = 'AOS-006'; phase = 4; title = '接通四项目适配与垂直切片'
            objective = '让小说、AI剪辑、内容审计、数据收集通过统一协议被调度。'
            depends_on = @('AOS-002', 'AOS-003', 'AOS-004'); capabilities = @('project_adapters')
            deliverables = @('四项目适配矩阵', '至少一条跨项目端到端任务')
            acceptance = @('不新增第六个业务项目', '项目上下文按需加载且边界可验证')
            status = 'proposed'; authority = 'human_approval_required'; project_scope = 'harness_infrastructure'
        },
        [ordered]@{
            task_id = 'AOS-007'; phase = 5; title = '建立受控自我进化候选闭环'
            objective = '从失败和效果中提出可验证改进，但禁止系统自批自改。'
            depends_on = @('AOS-003', 'AOS-004', 'AOS-005'); capabilities = @('controlled_evolution')
            deliverables = @('经验候选生成器', '离线评估与人工晋级门')
            acceptance = @('改进先在隔离环境验证', '提案者不能批准自己的核心规则修改')
            status = 'proposed'; authority = 'human_approval_required'; project_scope = 'harness_infrastructure'
        },
        [ordered]@{
            task_id = 'AOS-008'; phase = 6; title = '通过 Agent OS 就绪门'
            objective = '用统一验收矩阵判断系统是否从 Harness 进入 Agent OS。'
            depends_on = @('AOS-005', 'AOS-006', 'AOS-007'); capabilities = @('readiness_gate')
            deliverables = @('Agent OS 就绪报告', '未达标项和回退路径')
            acceptance = @('运行、调度、治理、项目适配全部有证据', '人工确认后才声明 Agent OS 就绪')
            status = 'proposed'; authority = 'human_approval_required'; project_scope = 'harness_infrastructure'
        }
    )
}

function New-AgentOSPlan {
    param(
        [Parameter(Mandatory)][string]$Objective,
        [Parameter(Mandatory)][string]$RuntimeRoot
    )

    Assert-HarnessTextSafe -Text $Objective
    $planId = 'agent-os-plan-{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd'), (Get-Date -Format 'HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $basePath = Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) $planId
    if (Test-Path -LiteralPath $basePath) {
        throw "Agent OS plan directory already exists: $basePath"
    }
    $null = New-Item -ItemType Directory -Path $basePath -Force

    $now = Get-NowText
    $plan = [pscustomobject][ordered]@{
        schema_version = '0.1'
        plan_id = $planId
        created_at = $now
        updated_at = $now
        objective = $Objective
        target = 'agent_os'
        state = 'draft'
        execution_authorized = $false
        constraints = [ordered]@{
            business_projects = @($businessProjects)
            preserve_project_boundary = $true
            automatic_execution = $false
            core_mutations_require_approval = $true
        }
        capability_targets = @($requiredCapabilities)
        tasks = @(New-AgentOSTasks)
        loop_policy = [ordered]@{
            max_attempts = $maxPlanningAttempts
            max_repairs = $maxPlanningRepairs
            attempts = 0
            repairs_requested = 0
        }
        approval = [ordered]@{
            status = 'pending'
            approved_at = $null
            approved_sha256 = $null
        }
        last_validation = [ordered]@{
            valid = $null
            errors = @()
            evaluated_at = $null
            candidate_sha256 = $null
        }
    }

    Save-Plan -BasePath $basePath -Plan $plan
    Add-LedgerEvent -BasePath $basePath -Plan $plan -Event 'plan_initialized' -Details @{ objective = $Objective }
    return Get-PlanInspection -Context (Get-PlanContext -RequestedRunPath $basePath -RuntimeRoot $RuntimeRoot)
}

function Get-PlanInspection {
    param([Parameter(Mandatory)]$Context)

    $plan = $Context.plan
    $usage = Get-PlanLoopUsage -BasePath $Context.base_path
    $taskCount = if ($plan.PSObject.Properties['tasks']) { @($plan.tasks).Count } else { 0 }
    $target = if ($plan.PSObject.Properties['target']) { [string]$plan.target } else { $null }
    $executionAuthorized = if ($plan.PSObject.Properties['execution_authorized']) { [bool]$plan.execution_authorized } else { $false }
    return [pscustomobject]@{
        plan_id = [string]$plan.plan_id
        run_path = $Context.base_path
        plan_path = $Context.plan_path
        state = [string]$plan.state
        target = $target
        task_count = $taskCount
        valid = $plan.last_validation.valid
        validation_errors = @($plan.last_validation.errors)
        loop_attempts = [int]$usage.attempts
        repairs_requested = [int]$usage.repairs
        pending_gate = if ([string]$plan.state -eq 'waiting_for_approval' -and [string]$plan.approval.status -eq 'pending') { 'agent_os_plan' } else { $null }
        approval_status = [string]$plan.approval.status
        approved_sha256 = $plan.approval.approved_sha256
        execution_authorized = $executionAuthorized
    }
}

function Get-PlanPreflightErrors {
    param([Parameter(Mandatory)]$Context)

    if (@($Context.envelope_errors).Count -gt 0) {
        return @($Context.envelope_errors)
    }
    $plan = $Context.plan
    if ([string]$plan.state -eq 'draft' -and
        $null -eq $plan.last_validation.valid -and
        @($plan.last_validation.errors | Where-Object { ([string]$_).StartsWith('[control-envelope]', [StringComparison]::Ordinal) }).Count -gt 0) {
        return @($plan.last_validation.errors)
    }
    return @()
}

function Save-ControlEnvelopeRecovery {
    param([Parameter(Mandatory)]$Context)

    if (@($Context.envelope_errors).Count -eq 0) {
        return $false
    }

    $plan = $Context.plan
    $ledgerState = Get-PlanLoopUsage -BasePath $Context.base_path
    $approvalWasActive = [bool]$ledgerState.approval_active
    $plan.approval.status = 'pending'
    $plan.approval.approved_at = $null
    $plan.approval.approved_sha256 = $null
    $plan.state = if ([string]$plan.state -eq 'failed') { 'failed' } else { 'draft' }
    $plan.last_validation.valid = $null
    $plan.last_validation.errors = @($Context.envelope_errors | ForEach-Object { "[control-envelope] $_" })
    $plan.last_validation.evaluated_at = Get-NowText
    $plan.last_validation.candidate_sha256 = $null
    Save-Plan -BasePath $Context.base_path -Plan $plan
    Add-LedgerEvent -BasePath $Context.base_path -Plan $plan -Event 'plan_control_envelope_recovered' -Details @{
        approval_invalidated = $approvalWasActive
        errors = @($Context.envelope_errors)
    }
    return $true
}

function Invalidate-PlanApprovalIfDrifted {
    param([Parameter(Mandatory)]$Context)

    $plan = $Context.plan
    if ([string]$plan.approval.status -ne 'approved') {
        return $false
    }
    $candidateHash = $null
    try {
        $candidateHash = Get-PlanCandidateHash -Plan $plan
    }
    catch {
        $candidateHash = $null
    }
    if ($candidateHash -and $candidateHash -eq [string]$plan.approval.approved_sha256) {
        return $false
    }

    $plan.approval.status = 'pending'
    $plan.approval.approved_at = $null
    $plan.approval.approved_sha256 = $null
    $plan.state = 'draft'
    $plan.last_validation.valid = $null
    $plan.last_validation.errors = @('已批准的任务图发生漂移，必须重新运行 Advance。')
    $plan.last_validation.evaluated_at = Get-NowText
    $plan.last_validation.candidate_sha256 = $null
    Save-Plan -BasePath $Context.base_path -Plan $plan
    Add-LedgerEvent -BasePath $Context.base_path -Plan $plan -Event 'plan_approval_invalidated'
    return $true
}

function New-RepairRequest {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string[]]$Errors
    )

    $request = [ordered]@{
        plan_id = [string]$Plan.plan_id
        attempt = [int]$Plan.loop_policy.attempts
        max_attempts = $maxPlanningAttempts
        repair_number = [int]$Plan.loop_policy.repairs_requested
        max_repairs = $maxPlanningRepairs
        errors = @($Errors)
        instruction = '只修复列出的规划合同或依赖图问题；不得执行任务、扩大四项目边界或解除人工门禁。修复后重新运行 Advance。'
        created_at = Get-NowText
    }
    Write-JsonFile -InputObject $request -LiteralPath (Join-Path $BasePath 'repair_request.json')
}

function Advance-AgentOSPlan {
    param([Parameter(Mandatory)]$Context)

    $plan = $Context.plan
    $preflightErrors = @(Get-PlanPreflightErrors -Context $Context)
    $null = Save-ControlEnvelopeRecovery -Context $Context
    if ([string]$plan.state -eq 'failed') {
        return Get-PlanInspection -Context $Context
    }

    $candidateHash = $null
    try {
        $candidateHash = Get-PlanCandidateHash -Plan $plan
    }
    catch {
        $candidateHash = $null
    }
    if ([string]$plan.approval.status -eq 'approved') {
        if (-not (Invalidate-PlanApprovalIfDrifted -Context $Context)) {
            return Get-PlanInspection -Context $Context
        }
        $candidateHash = Get-PlanCandidateHash -Plan $plan
    }
    elseif ([string]$plan.state -eq 'waiting_for_approval' -and
        [bool]$plan.last_validation.valid -and
        $candidateHash -eq [string]$plan.last_validation.candidate_sha256) {
        return Get-PlanInspection -Context $Context
    }

    $usage = Get-PlanLoopUsage -BasePath $Context.base_path
    $plan.loop_policy.attempts = [int]$usage.attempts
    $plan.loop_policy.repairs_requested = [int]$usage.repairs
    if ([int]$usage.attempts -ge $maxPlanningAttempts) {
        $plan.state = 'failed'
        Save-Plan -BasePath $Context.base_path -Plan $plan
        Add-LedgerEvent -BasePath $Context.base_path -Plan $plan -Event 'plan_attempt_budget_exhausted'
        return Get-PlanInspection -Context (Get-PlanContext -RequestedRunPath $Context.base_path -RuntimeRoot (Split-Path -Parent $Context.base_path))
    }

    $plan.state = 'evaluating'
    $plan.loop_policy.attempts = [int]$usage.attempts + 1
    $validation = Test-AgentOSPlan -Plan $plan -PreflightErrors $preflightErrors
    if ($validation.valid -and -not $candidateHash) {
        $candidateHash = Get-PlanCandidateHash -Plan $plan
    }
    $plan.last_validation.valid = [bool]$validation.valid
    $plan.last_validation.errors = @($validation.errors)
    $plan.last_validation.evaluated_at = Get-NowText
    $plan.last_validation.candidate_sha256 = $candidateHash

    if ($validation.valid) {
        $plan.state = 'waiting_for_approval'
        Save-Plan -BasePath $Context.base_path -Plan $plan
        Add-LedgerEvent -BasePath $Context.base_path -Plan $plan -Event 'plan_validated' -Details @{ candidate_sha256 = $candidateHash }
    }
    elseif ([int]$usage.repairs -lt $maxPlanningRepairs -and
        [int]$plan.loop_policy.attempts -lt $maxPlanningAttempts) {
        $plan.loop_policy.repairs_requested = [int]$usage.repairs + 1
        $plan.state = 'repairing'
        New-RepairRequest -BasePath $Context.base_path -Plan $plan -Errors @($validation.errors)
        Save-Plan -BasePath $Context.base_path -Plan $plan
        Add-LedgerEvent -BasePath $Context.base_path -Plan $plan -Event 'plan_repair_requested' -Details @{ errors = @($validation.errors) }
    }
    else {
        $plan.state = 'failed'
        Save-Plan -BasePath $Context.base_path -Plan $plan
        Add-LedgerEvent -BasePath $Context.base_path -Plan $plan -Event 'plan_validation_failed' -Details @{ errors = @($validation.errors) }
    }

    return Get-PlanInspection -Context (Get-PlanContext -RequestedRunPath $Context.base_path -RuntimeRoot (Split-Path -Parent $Context.base_path))
}

function Approve-AgentOSPlan {
    param([Parameter(Mandatory)]$Context)

    $plan = $Context.plan
    $preflightErrors = @(Get-PlanPreflightErrors -Context $Context)
    if (Save-ControlEnvelopeRecovery -Context $Context) {
        throw 'Agent OS plan control envelope was recovered safely. Run Advance before approving it.'
    }
    if ([string]$plan.state -ne 'waiting_for_approval' -or -not [bool]$plan.last_validation.valid) {
        throw "Agent OS plan is not ready for approval; current state is '$($plan.state)'."
    }
    if ([string]$plan.approval.status -eq 'approved') {
        throw 'Agent OS plan is already approved.'
    }

    $validation = Test-AgentOSPlan -Plan $plan -PreflightErrors $preflightErrors
    if (-not $validation.valid) {
        throw "Agent OS plan failed approval-time validation: $(@($validation.errors) -join ' | ')"
    }

    $candidateHash = Get-PlanCandidateHash -Plan $plan
    if ($candidateHash -ne [string]$plan.last_validation.candidate_sha256) {
        throw 'Agent OS plan changed after validation. Run Advance before approving it.'
    }

    $plan.approval.status = 'approved'
    $plan.approval.approved_at = Get-NowText
    $plan.approval.approved_sha256 = $candidateHash
    $plan.state = 'approved'
    Save-Plan -BasePath $Context.base_path -Plan $plan
    Add-LedgerEvent -BasePath $Context.base_path -Plan $plan -Event 'plan_approved' -Details @{ approved_sha256 = $candidateHash }
    return Get-PlanInspection -Context (Get-PlanContext -RequestedRunPath $Context.base_path -RuntimeRoot (Split-Path -Parent $Context.base_path))
}

function Invoke-AgentOSPlanningLoop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Initialize', 'Inspect', 'Advance', 'Approve')]
        [string]$Action,

        [string]$Objective,

        [Parameter(Mandatory)]
        [string]$RuntimeRoot,

        [string]$RunPath
    )

    if ($Action -eq 'Initialize') {
        if ([string]::IsNullOrWhiteSpace($Objective)) {
            throw '-Objective is required for Initialize.'
        }
        return New-AgentOSPlan -Objective $Objective -RuntimeRoot $RuntimeRoot
    }
    if ([string]::IsNullOrWhiteSpace($RunPath)) {
        throw "-RunPath is required for $Action."
    }

    $context = Get-PlanContext -RequestedRunPath $RunPath -RuntimeRoot $RuntimeRoot
    switch ($Action) {
        'Inspect' {
            if (-not (Save-ControlEnvelopeRecovery -Context $context)) {
                $null = Invalidate-PlanApprovalIfDrifted -Context $context
            }
            return Get-PlanInspection -Context $context
        }
        'Advance' { return Advance-AgentOSPlan -Context $context }
        'Approve' { return Approve-AgentOSPlan -Context $context }
    }
}

Export-ModuleMember -Function 'Invoke-AgentOSPlanningLoop'
