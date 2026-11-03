<#
    SYNTHETIC DATA · for training only · no real customer data
    ------------------------------------------------------------------
    99-Remove-FgdWorkspace.ps1
    Deletes the demo workspace (and everything in it: SQL database, lakehouses,
    warehouse, notebooks, pipeline, semantic model, report, data agent, ontology).
    Optionally also deletes the FGD-Analyst-Sandbox workspace.
    Asks you to type the workspace name unless -Force.

    Examples:
      ./99-Remove-FgdWorkspace.ps1
      ./99-Remove-FgdWorkspace.ps1 -IncludeSandbox -Force
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$TenantId,
    [string]$WorkspaceName,
    [switch]$IncludeSandbox,
    [string]$SandboxWorkspaceName = 'FGD-Analyst-Sandbox',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$FabricApi = 'https://api.fabric.microsoft.com'
function Write-Step([string]$Message) { Write-Host "[step] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "  [ok] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "  [warn] $Message" -ForegroundColor Yellow }

$cfg = if (Test-Path $ConfigPath) { Get-Content $ConfigPath -Raw | ConvertFrom-Json } else { $null }
if (-not $WorkspaceName) { $WorkspaceName = if ($cfg -and $cfg.workspaceName) { $cfg.workspaceName } else { 'FGD-Security-Demo' } }
if (-not $TenantId -and $cfg -and $cfg.tenantId -notmatch '^0{8}-') { $TenantId = $cfg.tenantId }

Import-Module Az.Accounts -ErrorAction Stop
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    if ($TenantId) { Connect-AzAccount -Tenant $TenantId | Out-Null } else { Connect-AzAccount | Out-Null }
}
function Get-FabricHeaders {
    $t = Get-AzAccessToken -ResourceUrl $FabricApi -ErrorAction Stop -WarningAction SilentlyContinue
    $tok = if ($t.Token -is [System.Security.SecureString]) { [System.Net.NetworkCredential]::new('', $t.Token).Password } else { [string]$t.Token }
    return @{ Authorization = "Bearer $tok" }
}

function Get-AllWorkspaces {
    $all = @(); $next = "$FabricApi/v1/workspaces"
    while ($next) {
        $r = Invoke-RestMethod -Uri $next -Headers (Get-FabricHeaders)
        $all += $r.value
        $next = if ($r.PSObject.Properties['continuationUri']) { $r.continuationUri } else { $null }
    }
    return $all
}

$names = @($WorkspaceName)
if ($IncludeSandbox) { $names += $SandboxWorkspaceName }
$workspaces = Get-AllWorkspaces

foreach ($name in $names) {
    Write-Step "Workspace $name"
    $ws = $workspaces | Where-Object { $_.displayName -eq $name } | Select-Object -First 1
    if (-not $ws) { Write-Ok 'not found - nothing to do'; continue }

    $items = @((Invoke-RestMethod -Uri "$FabricApi/v1/workspaces/$($ws.id)/items" -Headers (Get-FabricHeaders)).value)
    Write-Host "  $($ws.id) contains $($items.Count) items:" -ForegroundColor Gray
    $items | Sort-Object type, displayName | ForEach-Object { Write-Host "    - $($_.type): $($_.displayName)" -ForegroundColor Gray }

    if (-not $Force -and -not $WhatIfPreference) {
        $answer = Read-Host "Type the workspace name ($name) to delete it"
        if ($answer -ne $name) { Write-Warn 'cancelled'; continue }
    }
    if ($PSCmdlet.ShouldProcess($name, 'Delete workspace and all items')) {
        Invoke-RestMethod -Method Delete -Uri "$FabricApi/v1/workspaces/$($ws.id)" -Headers (Get-FabricHeaders) | Out-Null
        Write-Ok "deleted $name"
    }
}
Write-Step 'Done. Deleted workspaces may sit in the admin portal workspace recycle/retention period; item names can take a few minutes to become reusable.'
