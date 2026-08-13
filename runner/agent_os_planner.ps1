[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Initialize', 'Inspect', 'Advance', 'Approve')]
    [string]$Action,

    [string]$Objective,

    [string]$RuntimeRoot,

    [string]$RunPath,

    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $RuntimeRoot) {
    $RuntimeRoot = Join-Path $projectRoot 'runtime\agent_os_plans'
}

Import-Module (Join-Path $projectRoot 'src\AgentOSPlanning.psm1') -Force

$arguments = @{
    Action = $Action
    RuntimeRoot = $RuntimeRoot
}
if ($PSBoundParameters.ContainsKey('Objective')) {
    $arguments.Objective = $Objective
}
if ($PSBoundParameters.ContainsKey('RunPath')) {
    $arguments.RunPath = $RunPath
}

$result = Invoke-AgentOSPlanningLoop @arguments
if ($AsJson) {
    return $result | ConvertTo-Json -Depth 30
}
return $result
