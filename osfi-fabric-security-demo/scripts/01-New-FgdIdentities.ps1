<#
    SYNTHETIC DATA · for training only · no real customer data
    ------------------------------------------------------------------
    01-New-FgdIdentities.ps1
    Creates the Entra ID test personas and security groups for the
    "Microsoft Fabric Governance and Security" demo kit.

    Creates (idempotent: existing objects are reused, never modified):
      Users  : <prefix>.dana.engineer, <prefix>.olivia.analyst, <prefix>.quentin.analyst,
               <prefix>.sam.steward, <prefix>.aaron.auditor   (UPN = <name>@<TenantDomain>)
      Groups : sg-<prefix>-admins, -engineers, -analysts, -province-on, -province-qc,
               -stewards, -auditors, -automation
      Optional: licence assignment (-LicenseSkuPartNumber POWER_BI_PRO)
      Optional: app registration + service principal sp-<prefix>-automation (-CreateServicePrincipal)

    Writes:
      ./out/fgd-identities.json   object ids (consumed by 02/03 scripts)
      ./out/fgd-credentials.csv   initial passwords of NEW users  >>> DELETE AFTER REHEARSAL <<<

    Requires: PowerShell 7, Microsoft.Graph.Authentication / .Users / .Groups /
              .Identity.DirectoryManagement (+ .Applications with -CreateServicePrincipal)
              Entra roles: User Administrator + Groups Administrator (+ Application
              Administrator for -CreateServicePrincipal), or Global Administrator.

    Examples:
      ./01-New-FgdIdentities.ps1 -WhatIf
      ./01-New-FgdIdentities.ps1 -LicenseSkuPartNumber POWER_BI_PRO
      ./01-New-FgdIdentities.ps1 -CreateServicePrincipal -CreateClientSecret
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    # Path to config.json (copy of config.sample.json). Explicit parameters win over config values.
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$TenantId,
    [string]$TenantDomain,
    [string]$PresenterUpn,
    [string]$Prefix,
    # e.g. POWER_BI_PRO (needed for report viewers on capacities below F64)
    [string]$LicenseSkuPartNumber,
    [switch]$CreateServicePrincipal,
    # Prints a 30-day client secret ONCE. It is never written to disk.
    [switch]$CreateClientSecret,
    # Do not force a password change at first sign-in (handy for a short-lived demo tenant)
    [switch]$NoForceChange,
    [string]$OutDir = (Join-Path $PSScriptRoot 'out')
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { Write-Host "[step] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "  [ok] $Message" -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "  [..] $Message" -ForegroundColor Gray }
function Write-Warn([string]$Message) { Write-Host "  [warn] $Message" -ForegroundColor Yellow }

# ------------------------------------------------------------------ [step] configuration
Write-Step 'Reading configuration'
$cfg = $null
if (Test-Path $ConfigPath) {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    Write-Info "config: $ConfigPath"
}
function Get-Setting($Value, [string]$Name, $Default) {
    if ($Value) { return $Value }
    if ($cfg -and $cfg.PSObject.Properties[$Name] -and $cfg.$Name -and ($cfg.$Name -notmatch '^0{8}-0{4}-')) { return $cfg.$Name }
    return $Default
}
$TenantId     = Get-Setting $TenantId     'tenantId'     $null
$TenantDomain = Get-Setting $TenantDomain 'tenantDomain' $null
$PresenterUpn = Get-Setting $PresenterUpn 'presenterUpn' $null
$Prefix       = Get-Setting $Prefix       'prefix'       'fgd'
if (-not $TenantDomain) { throw 'TenantDomain is required (parameter or config.json tenantDomain).' }
if ($CreateClientSecret -and -not $CreateServicePrincipal) { throw '-CreateClientSecret requires -CreateServicePrincipal.' }
Write-Info "tenantDomain=$TenantDomain prefix=$Prefix presenter=$PresenterUpn"

# Personas: key, alias, display name, job title, groups
$personas = @(
    [ordered]@{ Key = 'dana';    Alias = "$Prefix.dana.engineer";    Given = 'Dana';    Surname = 'Engineer'; Title = 'Data Engineer (demo)';      Groups = @("sg-$Prefix-engineers") }
    [ordered]@{ Key = 'olivia';  Alias = "$Prefix.olivia.analyst";   Given = 'Olivia';  Surname = 'Analyst';  Title = 'Analyst, Ontario (demo)';   Groups = @("sg-$Prefix-analysts", "sg-$Prefix-province-on") }
    [ordered]@{ Key = 'quentin'; Alias = "$Prefix.quentin.analyst";  Given = 'Quentin'; Surname = 'Analyst';  Title = 'Analyst, Quebec (demo)';    Groups = @("sg-$Prefix-analysts", "sg-$Prefix-province-qc") }
    [ordered]@{ Key = 'sam';     Alias = "$Prefix.sam.steward";      Given = 'Sam';     Surname = 'Steward';  Title = 'Data Steward (demo)';       Groups = @("sg-$Prefix-stewards") }
    [ordered]@{ Key = 'aaron';   Alias = "$Prefix.aaron.auditor";    Given = 'Aaron';   Surname = 'Auditor';  Title = 'Internal Auditor (demo)';   Groups = @("sg-$Prefix-auditors") }
)
$groupNames = @(
    "sg-$Prefix-admins", "sg-$Prefix-engineers", "sg-$Prefix-analysts", "sg-$Prefix-province-on",
    "sg-$Prefix-province-qc", "sg-$Prefix-stewards", "sg-$Prefix-auditors", "sg-$Prefix-automation"
)
$appName = "sp-$Prefix-automation"

# ------------------------------------------------------------------ [step] modules + sign-in
Write-Step 'Checking Microsoft Graph modules'
$modules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.Groups', 'Microsoft.Graph.Identity.DirectoryManagement')
if ($CreateServicePrincipal) { $modules += 'Microsoft.Graph.Applications' }
foreach ($m in $modules) {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Module $m not found. Run: Install-Module Microsoft.Graph -Scope CurrentUser" }
    Import-Module $m -ErrorAction Stop
}

Write-Step 'Connecting to Microsoft Graph'
$scopes = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Directory.Read.All')
if ($CreateServicePrincipal) { $scopes += 'Application.ReadWrite.All' }
$connect = @{ Scopes = $scopes; NoWelcome = $true }
if ($TenantId) { $connect.TenantId = $TenantId }
Connect-MgGraph @connect
$ctx = Get-MgContext
if (-not $TenantId) { $TenantId = $ctx.TenantId }
Write-Ok "signed in as $($ctx.Account) to tenant $($ctx.TenantId)"

# ------------------------------------------------------------------ helpers
function New-StrongPassword([int]$Length = 20) {
    # Cryptographically random; guarantees upper, lower, digit and symbol.
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#%^*-_=+?')
    $all = -join $sets
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $chars.Add($s[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($s.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    # Fisher-Yates shuffle
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    return -join $chars
}

function Invoke-WithRetry([scriptblock]$Action, [int]$Attempts = 6, [int]$DelaySeconds = 5) {
    # New directory objects can take a few seconds to replicate.
    for ($i = 1; $i -le $Attempts; $i++) {
        try { return & $Action }
        catch {
            if ($i -eq $Attempts) { throw }
            Write-Info "retry $i/$Attempts in $DelaySeconds s: $($_.Exception.Message)"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Get-UserByUpn([string]$Upn) {
    try { return Get-MgUser -UserId $Upn -Property Id, UserPrincipalName, DisplayName, AssignedLicenses -ErrorAction Stop }
    catch { return $null }
}

function Get-GroupByName([string]$Name) {
    return Get-MgGroup -Filter "displayName eq '$Name'" -All | Select-Object -First 1
}

$memberCache = @{}
function Add-GroupMemberIfMissing([string]$GroupName, [string]$GroupId, [string]$MemberId, [string]$Label) {
    if (-not $GroupId -or -not $MemberId) { Write-Info "skip $Label -> $GroupName (no id, WhatIf?)"; return }
    if (-not $memberCache.ContainsKey($GroupId)) {
        $memberCache[$GroupId] = @(Get-MgGroupMember -GroupId $GroupId -All | ForEach-Object { $_.Id })
    }
    if ($memberCache[$GroupId] -contains $MemberId) { Write-Info "$Label already in $GroupName"; return }
    if ($PSCmdlet.ShouldProcess($GroupName, "Add member $Label")) {
        Invoke-WithRetry { New-MgGroupMember -GroupId $GroupId -DirectoryObjectId $MemberId } | Out-Null
        $memberCache[$GroupId] += $MemberId
        Write-Ok "added $Label to $GroupName"
    }
}

# ------------------------------------------------------------------ [step] groups
Write-Step 'Creating security groups'
$groups = [ordered]@{}
foreach ($g in $groupNames) {
    $existing = Get-GroupByName $g
    if ($existing) {
        $groups[$g] = $existing.Id
        Write-Info "group $g exists ($($existing.Id))"
        continue
    }
    if ($PSCmdlet.ShouldProcess($g, 'Create security group')) {
        $new = New-MgGroup -DisplayName $g -MailEnabled:$false -MailNickname $g -SecurityEnabled -Description 'FGD demo'
        $groups[$g] = $new.Id
        Write-Ok "created group $g ($($new.Id))"
    }
    else { $groups[$g] = $null }
}

# ------------------------------------------------------------------ [step] users
Write-Step 'Creating persona users'
$users = [ordered]@{}
$credentials = [System.Collections.Generic.List[object]]::new()
foreach ($p in $personas) {
    $upn = "$($p.Alias)@$TenantDomain"
    $existing = Get-UserByUpn $upn
    if ($existing) {
        $users[$p.Key] = [ordered]@{ upn = $upn; id = $existing.Id }
        Write-Info "user $upn exists ($($existing.Id)) - password unchanged"
        continue
    }
    if ($PSCmdlet.ShouldProcess($upn, 'Create user')) {
        $password = New-StrongPassword
        $body = @{
            AccountEnabled    = $true
            DisplayName       = "$($p.Given) $($p.Surname) (FGD demo)"
            GivenName         = $p.Given
            Surname           = $p.Surname
            JobTitle          = $p.Title
            Department        = 'FGD demo - synthetic persona'
            MailNickname      = $p.Alias.Replace('.', '-')
            UserPrincipalName = $upn
            UsageLocation     = 'CA'
            PasswordProfile   = @{ Password = $password; ForceChangePasswordNextSignIn = (-not $NoForceChange) }
        }
        $new = New-MgUser -BodyParameter $body
        $users[$p.Key] = [ordered]@{ upn = $upn; id = $new.Id }
        $credentials.Add([pscustomobject]@{ Persona = $p.Key; UserPrincipalName = $upn; InitialPassword = $password; ForceChange = (-not $NoForceChange) })
        Write-Ok "created $upn ($($new.Id))"
    }
    else { $users[$p.Key] = [ordered]@{ upn = $upn; id = $null } }
}

# ------------------------------------------------------------------ [step] memberships
Write-Step 'Adding group memberships'
foreach ($p in $personas) {
    foreach ($g in $p.Groups) { Add-GroupMemberIfMissing $g $groups[$g] $users[$p.Key].id $users[$p.Key].upn }
}
$presenter = $null
if ($PresenterUpn) {
    $presenter = Get-UserByUpn $PresenterUpn
    if ($presenter) { Add-GroupMemberIfMissing "sg-$Prefix-admins" $groups["sg-$Prefix-admins"] $presenter.Id $PresenterUpn }
    else { Write-Warn "presenter $PresenterUpn not found - add yourself to sg-$Prefix-admins manually (guest UPNs contain #EXT#)." }
}
else { Write-Warn "no presenterUpn - add yourself to sg-$Prefix-admins manually." }

# ------------------------------------------------------------------ [step] licences (optional)
if ($LicenseSkuPartNumber) {
    Write-Step "Assigning licence $LicenseSkuPartNumber"
    $sku = Get-MgSubscribedSku -All | Where-Object { $_.SkuPartNumber -eq $LicenseSkuPartNumber } | Select-Object -First 1
    if (-not $sku) {
        $available = (Get-MgSubscribedSku -All | ForEach-Object { $_.SkuPartNumber }) -join ', '
        Write-Warn "SKU $LicenseSkuPartNumber not found in tenant. Available: $available"
    }
    else {
        $free = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
        Write-Info "$LicenseSkuPartNumber free seats: $free"
        foreach ($k in $users.Keys) {
            $u = $users[$k]
            if (-not $u.id) { continue }
            $current = Get-UserByUpn $u.upn
            if ($current -and ($current.AssignedLicenses.SkuId -contains $sku.SkuId)) { Write-Info "$($u.upn) already licensed"; continue }
            if (-not $PSCmdlet.ShouldProcess($u.upn, "Assign $LicenseSkuPartNumber")) { continue }
            try {
                if (Get-Command Set-MgUserLicense -ErrorAction SilentlyContinue) {
                    Invoke-WithRetry { Set-MgUserLicense -UserId $u.id -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @() } | Out-Null
                }
                else {
                    # Set-MgUserLicense lives in Microsoft.Graph.Users.Actions; fall back to the raw Graph call.
                    $payload = @{ addLicenses = @(@{ skuId = $sku.SkuId; disabledPlans = @() }); removeLicenses = @() } | ConvertTo-Json -Depth 5
                    Invoke-WithRetry { Invoke-MgGraphRequest -Method POST -Uri "v1.0/users/$($u.id)/assignLicense" -Body $payload -ContentType 'application/json' } | Out-Null
                }
                Write-Ok "licensed $($u.upn)"
            }
            catch { Write-Warn "licence for $($u.upn) failed: $($_.Exception.Message). Assign in the Microsoft 365 admin center." }
        }
    }
}

# ------------------------------------------------------------------ [step] service principal (optional)
$spInfo = $null
if ($CreateServicePrincipal) {
    Write-Step "Creating app registration + service principal $appName"
    $app = Get-MgApplication -Filter "displayName eq '$appName'" -All | Select-Object -First 1
    if (-not $app -and $PSCmdlet.ShouldProcess($appName, 'Create app registration')) {
        $app = New-MgApplication -DisplayName $appName -SignInAudience 'AzureADMyOrg' -Notes 'FGD demo - Fabric API automation (synthetic demo)'
        Write-Ok "created app $appName (appId $($app.AppId))"
    }
    elseif ($app) { Write-Info "app $appName exists (appId $($app.AppId))" }

    if ($app) {
        $sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -All | Select-Object -First 1
        if (-not $sp -and $PSCmdlet.ShouldProcess($appName, 'Create service principal')) {
            $sp = Invoke-WithRetry { New-MgServicePrincipal -AppId $app.AppId }
            Write-Ok "created service principal ($($sp.Id))"
        }
        elseif ($sp) { Write-Info "service principal exists ($($sp.Id))" }
        if ($sp) {
            Add-GroupMemberIfMissing "sg-$Prefix-automation" $groups["sg-$Prefix-automation"] $sp.Id $appName
            $spInfo = [ordered]@{ displayName = $appName; appId = $app.AppId; applicationObjectId = $app.Id; servicePrincipalId = $sp.Id }
        }
        if ($CreateClientSecret -and $PSCmdlet.ShouldProcess($appName, 'Create 30-day client secret')) {
            $secret = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential @{ DisplayName = 'fgd-demo'; EndDateTime = (Get-Date).AddDays(30) }
            Write-Host ''
            Write-Host '  ================= CLIENT SECRET (shown once, NOT saved) =================' -ForegroundColor Yellow
            Write-Host "  appId    : $($app.AppId)" -ForegroundColor Yellow
            Write-Host "  tenantId : $TenantId" -ForegroundColor Yellow
            Write-Host "  secret   : $($secret.SecretText)" -ForegroundColor Yellow
            Write-Host "  expires  : $($secret.EndDateTime)" -ForegroundColor Yellow
            Write-Host '  Store it in a password manager or Key Vault. Never in a file or repo.' -ForegroundColor Yellow
            Write-Host '  ===========================================================================' -ForegroundColor Yellow
            Write-Host ''
            Remove-Variable secret
        }
    }
}

# ------------------------------------------------------------------ [step] outputs
Write-Step 'Writing outputs'
if (-not $WhatIfPreference) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $result = [ordered]@{
        generatedAt      = (Get-Date).ToString('s')
        tenantId         = $TenantId
        tenantDomain     = $TenantDomain
        prefix           = $Prefix
        presenter        = if ($presenter) { [ordered]@{ upn = $PresenterUpn; id = $presenter.Id } } else { $null }
        users            = $users
        groups           = $groups
        servicePrincipal = $spInfo
    }
    $idPath = Join-Path $OutDir 'fgd-identities.json'
    $result | ConvertTo-Json -Depth 6 | Set-Content -Path $idPath -Encoding utf8
    Write-Ok "ids -> $idPath"

    if ($credentials.Count -gt 0) {
        $credPath = Join-Path $OutDir 'fgd-credentials.csv'
        if (Test-Path $credPath) {
            # Keep earlier rows for users created in a previous run.
            $old = @(Import-Csv $credPath | Where-Object { $credentials.UserPrincipalName -notcontains $_.UserPrincipalName })
            $old | ForEach-Object { $credentials.Add($_) }
        }
        $credentials | Export-Csv -Path $credPath -NoTypeInformation -Encoding utf8
        Write-Host ''
        Write-Host '  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' -ForegroundColor Red
        Write-Host "  !!  INITIAL PASSWORDS WRITTEN TO: $credPath" -ForegroundColor Red
        Write-Host '  !!  Sign each persona in once (browser profile), then DELETE THIS FILE.' -ForegroundColor Red
        Write-Host '  !!  Never commit, email or screen-share it.' -ForegroundColor Red
        Write-Host '  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' -ForegroundColor Red
        Write-Host ''
    }
    else { Write-Info 'no new users - credentials file not touched' }
}
else { Write-Info 'WhatIf: no files written' }

Write-Step 'Done. Next: ./02-Deploy-FgdWorkspace.ps1'
