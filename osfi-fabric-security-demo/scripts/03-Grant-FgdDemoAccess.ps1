<#
    SYNTHETIC DATA · for training only · no real customer data
    ------------------------------------------------------------------
    03-Grant-FgdDemoAccess.ps1   (OPTIONAL - "pre-staged" path for Demo 3)

    1. Pre-creates OneLake security (data access) roles on lh_silver:
         reader_on   -> sg-<prefix>-province-on   Read on the 4 silver tables
         reader_qc   -> sg-<prefix>-province-qc   Read on the 4 silver tables
         steward_all -> sg-<prefix>-stewards      Read on the 4 silver tables
       Table-level only by default. Row (province) and column (hide sin, date_of_birth)
       rules are added LIVE in the UI during Demo 3. Use -IncludeRowColumnRules to
       pre-create them too (rehearsal / fallback).
       DefaultReader is KEPT (you delete it live) unless -RemoveDefaultReader.
    2. Prints the click steps to add semantic model role members
       (no public REST API for RLS role membership).

    PREREQUISITE: OneLake security must already be enabled on lh_silver
    (lh_silver > Manage OneLake security > Enable). Enabling may be irreversible.

    VERIFY: dataAccessRoles request body shape (decisionRules / constraints / members)
            against the current Fabric REST reference before the session.
            Click fallback: README > Demo 3.

    Examples:
      ./03-Grant-FgdDemoAccess.ps1 -WhatIf
      ./03-Grant-FgdDemoAccess.ps1
      ./03-Grant-FgdDemoAccess.ps1 -IncludeRowColumnRules -RemoveDefaultReader
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$TenantId,
    [string]$WorkspaceName,
    [string]$IdentitiesPath = (Join-Path $PSScriptRoot 'out/fgd-identities.json'),
    [switch]$IncludeRowColumnRules,
    [switch]$RemoveDefaultReader
)

$ErrorActionPreference = 'Stop'
$FabricApi = 'https://api.fabric.microsoft.com'
function Write-Step([string]$Message) { Write-Host "[step] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "  [ok] $Message" -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "  [..] $Message" -ForegroundColor Gray }
function Write-Warn([string]$Message) { Write-Host "  [warn] $Message" -ForegroundColor Yellow }

# ------------------------------------------------------------------ [step] configuration
Write-Step 'Reading configuration'
$cfg = if (Test-Path $ConfigPath) { Get-Content $ConfigPath -Raw | ConvertFrom-Json } else { $null }
if (-not $WorkspaceName) { $WorkspaceName = if ($cfg -and $cfg.workspaceName) { $cfg.workspaceName } else { 'FGD-Security-Demo' } }
if (-not (Test-Path $IdentitiesPath)) { throw "Identities file not found: $IdentitiesPath (run 01 first)." }
$ids = Get-Content $IdentitiesPath -Raw | ConvertFrom-Json
if (-not $TenantId) { $TenantId = if ($cfg -and $cfg.tenantId -notmatch '^0{8}-') { $cfg.tenantId } else { $ids.tenantId } }
$Prefix = if ($ids.prefix) { $ids.prefix } else { 'fgd' }

# ------------------------------------------------------------------ helpers
Import-Module Az.Accounts -ErrorAction Stop
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) { Connect-AzAccount -Tenant $TenantId | Out-Null }

function Get-Token([string]$ResourceUrl) {
    $t = Get-AzAccessToken -ResourceUrl $ResourceUrl -ErrorAction Stop -WarningAction SilentlyContinue
    if ($t.Token -is [System.Security.SecureString]) { return [System.Net.NetworkCredential]::new('', $t.Token).Password }
    return [string]$t.Token
}

function Invoke-Fabric([string]$Method = 'GET', [string]$Path, $Body) {
    # Minimal helper: 429/5xx retry; 202 polled via Location until terminal.
    $uri = if ($Path -match '^https?://') { $Path } else { "$FabricApi$Path" }
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $req = @{ Method = $Method; Uri = $uri; SkipHttpErrorCheck = $true; Headers = @{ Authorization = "Bearer $(Get-Token $FabricApi)" } }
        if ($null -ne $Body) {
            $req.Body = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 32 -Compress))
            $req.ContentType = 'application/json; charset=utf-8'
        }
        $resp = Invoke-WebRequest @req
        $code = [int]$resp.StatusCode
        if (($code -eq 429 -or $code -ge 500) -and $attempt -lt 6) { Start-Sleep -Seconds (10 * $attempt); continue }
        if ($code -ge 400) { throw "Fabric $Method $uri -> HTTP $code $($resp.Content)" }
        if ($code -eq 202) {
            $loc = [string]($resp.Headers['Location'] | Select-Object -First 1)
            while ($loc) {
                Start-Sleep -Seconds 5
                $st = Invoke-RestMethod -Uri $loc -Headers @{ Authorization = "Bearer $(Get-Token $FabricApi)" }
                if ($st.status -in 'Succeeded', 'Completed') { return $st }
                if ($st.status -in 'Failed', 'Cancelled') { throw "operation $($st.status): $($st.error | ConvertTo-Json -Compress -Depth 8)" }
            }
            return $null
        }
        if ([string]::IsNullOrWhiteSpace($resp.Content)) { return $null }
        return $resp.Content | ConvertFrom-Json
    }
}

function Get-FabricList([string]$Path) {
    $all = [System.Collections.Generic.List[object]]::new(); $next = $Path
    while ($next) {
        $r = Invoke-Fabric -Path $next
        if ($r -and $r.PSObject.Properties['value']) { foreach ($v in $r.value) { $all.Add($v) } }
        $next = if ($r -and $r.PSObject.Properties['continuationUri']) { $r.continuationUri } else { $null }
    }
    return $all.ToArray()
}

# ------------------------------------------------------------------ [step] resolve ids
Write-Step "Resolving $WorkspaceName / lh_silver"
$ws = Get-FabricList '/v1/workspaces' | Where-Object { $_.displayName -eq $WorkspaceName } | Select-Object -First 1
if (-not $ws) { throw "Workspace $WorkspaceName not found." }
$lh = Get-FabricList "/v1/workspaces/$($ws.id)/items?type=Lakehouse" | Where-Object { $_.displayName -eq 'lh_silver' } | Select-Object -First 1
if (-not $lh) { throw 'lh_silver not found.' }
Write-Ok "workspace $($ws.id) / lh_silver $($lh.id)"

# ------------------------------------------------------------------ [step] OneLake security roles
Write-Step 'Reading existing OneLake security roles on lh_silver'
$rolesPath = "/v1/workspaces/$($ws.id)/items/$($lh.id)/dataAccessRoles"
try { $existing = @((Invoke-Fabric -Path $rolesPath).value) }
catch {
    Write-Warn $_.Exception.Message
    Write-Warn 'Enable OneLake security first: open lh_silver > Manage OneLake security > Enable. Or follow README > Demo 3 by hand.'
    throw
}
Write-Info ("existing roles: " + (($existing | ForEach-Object { $_.name }) -join ', '))

$tables = 'customer', 'account', 'loan', 'transaction_monthly'
$customerColumnsAllowed = 'customer_id', 'first_name', 'last_name', 'email', 'province', 'segment', 'created_at'   # sin, date_of_birth removed

function New-DemoRole([string]$Name, [string]$GroupName, [string]$Province) {
    $gid = $ids.groups.$GroupName
    if (-not $gid) { throw "No object id for $GroupName in $IdentitiesPath" }
    $rule = [ordered]@{
        effect     = 'Permit'
        permission = @(
            [ordered]@{ attributeName = 'Path';   attributeValueIncludedIn = @($tables | ForEach-Object { "/Tables/$_" }) },
            [ordered]@{ attributeName = 'Action'; attributeValueIncludedIn = @('Read') }
        )
    }
    if ($IncludeRowColumnRules -and $Province) {
        # VERIFY: constraints shape (rows = T-SQL predicate per table; columns = permitted column list).
        $rule.constraints = [ordered]@{
            rows    = @($tables | ForEach-Object { [ordered]@{ tablePath = "/Tables/$_"; value = "SELECT * FROM $_ WHERE province = '$Province'" } })
            columns = @([ordered]@{ tablePath = '/Tables/customer'; columnNames = @($customerColumnsAllowed); columnEffect = 'Permit'; columnAction = @('Read') })
        }
    }
    return [ordered]@{
        name          = $Name
        decisionRules = @($rule)
        members       = [ordered]@{ microsoftEntraMembers = @([ordered]@{ tenantId = $TenantId; objectId = $gid }) }
    }
}

# NOTE: if the service rejects underscores in role names, rename to readerON / readerQC / stewardAll here and on the slide.
$demoRoles = @(
    New-DemoRole 'reader_on'   "sg-$Prefix-province-on" 'ON'
    New-DemoRole 'reader_qc'   "sg-$Prefix-province-qc" 'QC'
    New-DemoRole 'steward_all' "sg-$Prefix-stewards"    $null
)
$demoNames = $demoRoles | ForEach-Object { $_.name }

# Keep roles we don't own (DefaultReader unless -RemoveDefaultReader); replace ours.
$keep = @($existing | Where-Object {
        $_.name -notin $demoNames -and -not ($RemoveDefaultReader -and $_.name -eq 'DefaultReader')
    } | ForEach-Object {
        # Send back only the writable properties.
        $r = [ordered]@{ name = $_.name; decisionRules = $_.decisionRules }
        if ($_.PSObject.Properties['members']) { $r.members = $_.members }
        $r
    })
$body = @{ value = @($keep) + @($demoRoles) }

Write-Info ("roles after update: " + (($body.value | ForEach-Object { $_.name }) -join ', '))
if ($PSCmdlet.ShouldProcess('lh_silver', 'PUT OneLake security roles (replaces the full role set)')) {
    try {
        Invoke-Fabric -Method PUT -Path $rolesPath -Body $body | Out-Null
        Write-Ok 'OneLake security roles updated'
    }
    catch {
        Write-Warn "PUT dataAccessRoles failed: $($_.Exception.Message)"
        Write-Warn 'Fallback: README > Demo 3 (create the roles in the UI). Body shape is marked VERIFY in this script.'
    }
}

# ------------------------------------------------------------------ [step] semantic model roles (click steps)
Write-Step 'Semantic model role members (manual - no public REST API for RLS membership)'
Write-Host @"
  In the presenter browser profile:
    1. Workspace $WorkspaceName > sm_gold_banking > ... > Security
       (or open the model > Manage roles in the web modeling view).
    2. Role 'Province' > Members > add  sg-$Prefix-analysts  > Add > Save.
    3. Role 'Steward'  > Members > add  sg-$Prefix-stewards  > Add > Save.
    4. Do NOT add engineers/auditors: Contributors (Write permission) bypass RLS;
       auditors get no data role on purpose.
    5. Check: Province > ... > Test as role > Other user > fgd.olivia.analyst@... -> Ontario only, no SIN/DOB.
"@ -ForegroundColor Gray

Write-Step 'Done.'
