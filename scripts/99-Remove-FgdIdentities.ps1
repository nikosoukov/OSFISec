<#
    SYNTHETIC DATA · for training only · no real customer data
    ------------------------------------------------------------------
    99-Remove-FgdIdentities.ps1
    Removes the demo personas, security groups and (if present) the
    sp-<prefix>-automation app registration created by 01-New-FgdIdentities.ps1.

    Objects are found by NAME (UPN / display name), so this works even
    if ./out/fgd-identities.json was deleted. Asks for confirmation unless -Force.
    Deleted users/groups/apps go to the Entra recycle bin for 30 days;
    add -PurgeDeleted to remove them permanently.

    Examples:
      ./99-Remove-FgdIdentities.ps1 -WhatIf
      ./99-Remove-FgdIdentities.ps1 -Force -PurgeDeleted
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$TenantId,
    [string]$TenantDomain,
    [string]$Prefix,
    [switch]$Force,
    [switch]$PurgeDeleted,
    [string]$OutDir = (Join-Path $PSScriptRoot 'out')
)

$ErrorActionPreference = 'Stop'
function Write-Step([string]$Message) { Write-Host "[step] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "  [ok] $Message" -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "  [..] $Message" -ForegroundColor Gray }
function Write-Warn([string]$Message) { Write-Host "  [warn] $Message" -ForegroundColor Yellow }

Write-Step 'Reading configuration'
$cfg = if (Test-Path $ConfigPath) { Get-Content $ConfigPath -Raw | ConvertFrom-Json } else { $null }
if (-not $TenantId -and $cfg -and $cfg.tenantId -notmatch '^0{8}-') { $TenantId = $cfg.tenantId }
if (-not $TenantDomain -and $cfg) { $TenantDomain = $cfg.tenantDomain }
if (-not $Prefix) { $Prefix = if ($cfg -and $cfg.prefix) { $cfg.prefix } else { 'fgd' } }
if (-not $TenantDomain) { throw 'TenantDomain is required (parameter or config.json).' }

$userUpns = @('dana.engineer', 'olivia.analyst', 'quentin.analyst', 'sam.steward', 'aaron.auditor') |
    ForEach-Object { "$Prefix.$_@$TenantDomain" }
$groupNames = @('admins', 'engineers', 'analysts', 'province-on', 'province-qc', 'stewards', 'auditors', 'automation') |
    ForEach-Object { "sg-$Prefix-$_" }
$appName = "sp-$Prefix-automation"

Write-Step 'Connecting to Microsoft Graph'
foreach ($m in 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.Groups', 'Microsoft.Graph.Applications', 'Microsoft.Graph.Identity.DirectoryManagement') {
    Import-Module $m -ErrorAction Stop
}
$connect = @{ Scopes = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'Application.ReadWrite.All', 'Directory.Read.All'); NoWelcome = $true }
if ($TenantId) { $connect.TenantId = $TenantId }
Connect-MgGraph @connect

Write-Step 'Finding demo objects'
$targets = [System.Collections.Generic.List[object]]::new()
foreach ($upn in $userUpns) {
    try { $u = Get-MgUser -UserId $upn -ErrorAction Stop; $targets.Add([pscustomobject]@{ Kind = 'User'; Name = $upn; Id = $u.Id }) }
    catch { Write-Info "user $upn not found" }
}
foreach ($g in $groupNames) {
    $grp = Get-MgGroup -Filter "displayName eq '$g'" -All | Select-Object -First 1
    if ($grp) { $targets.Add([pscustomobject]@{ Kind = 'Group'; Name = $g; Id = $grp.Id }) } else { Write-Info "group $g not found" }
}
$app = Get-MgApplication -Filter "displayName eq '$appName'" -All | Select-Object -First 1
if ($app) { $targets.Add([pscustomobject]@{ Kind = 'Application'; Name = $appName; Id = $app.Id }) } else { Write-Info "app $appName not found" }

if ($targets.Count -eq 0) { Write-Ok 'nothing to remove'; return }
$targets | Format-Table Kind, Name, Id -AutoSize | Out-String | Write-Host

if (-not $Force -and -not $WhatIfPreference) {
    $answer = Read-Host "Type DELETE to remove these $($targets.Count) objects"
    if ($answer -ne 'DELETE') { Write-Warn 'cancelled'; return }
}

Write-Step 'Removing'
foreach ($t in $targets) {
    if (-not $PSCmdlet.ShouldProcess("$($t.Kind) $($t.Name)", 'Delete')) { continue }
    try {
        switch ($t.Kind) {
            'User'        { Remove-MgUser -UserId $t.Id }
            'Group'       { Remove-MgGroup -GroupId $t.Id }
            'Application' { Remove-MgApplication -ApplicationId $t.Id }   # also removes its service principal
        }
        Write-Ok "deleted $($t.Kind) $($t.Name)"
        if ($PurgeDeleted) {
            Start-Sleep -Seconds 3
            try { Remove-MgDirectoryDeletedItem -DirectoryObjectId $t.Id; Write-Ok "purged $($t.Name)" }
            catch { Write-Warn "purge $($t.Name) failed (retry later or use the Entra admin center > Deleted items): $($_.Exception.Message)" }
        }
    }
    catch { Write-Warn "delete $($t.Kind) $($t.Name) failed: $($_.Exception.Message)" }
}

$cred = Join-Path $OutDir 'fgd-credentials.csv'
if ((Test-Path $cred) -and $PSCmdlet.ShouldProcess($cred, 'Delete credentials file')) {
    Remove-Item $cred -Force
    Write-Ok "deleted $cred"
}
Write-Step 'Done. Remember to revert tenant settings scoped to the deleted groups (README > Teardown).'
