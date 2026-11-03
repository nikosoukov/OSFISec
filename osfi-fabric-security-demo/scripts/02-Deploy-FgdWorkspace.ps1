#Requires -Version 7.2
<#
    SYNTHETIC DATA · for training only · no real customer data
    ------------------------------------------------------------------
    02-Deploy-FgdWorkspace.ps1
    Deploys the FGD security demo workspace end-to-end with the Fabric REST API:

      workspace FGD-Security-Demo (on your F-SKU capacity)
        + group role assignments (Admin / Contributor / Viewer)
        + lh_bronze, lh_silver (lakehouses, no schemas), wh_gold (warehouse)
        + sqldb_core_banking (SQL database in Fabric) seeded with sql/10_sqldb_seed.sql
        + notebooks nb_01_ingest_files, nb_02_bronze_to_silver, nb_03_check_my_access
        + pipeline pl_daily_load (nb_01 -> nb_02), run once
        + wh_gold built with sql/30_wh_gold_build.sql
        + semantic model sm_gold_banking (Direct Lake, TMDL from ../model)
      optional: FGD-Analyst-Sandbox workspace so Viewer personas can run nb_03 (-CreateAnalystSandbox)

    Idempotent: existing items are reused (notebooks / pipeline / model definitions are updated).
    Every step is wrapped in try/catch; on failure it prints the README click-fallback and continues
    where possible. Writes ./out/fgd-workspace.json with all item ids.

    Requires: PowerShell 7, Az.Accounts, SqlServer (v22+ for -AccessToken),
              Fabric capacity admin/contributor, ./out/fgd-identities.json from script 01.

    Examples:
      ./02-Deploy-FgdWorkspace.ps1
      ./02-Deploy-FgdWorkspace.ps1 -CreateAnalystSandbox
      ./02-Deploy-FgdWorkspace.ps1 -SkipPipelineRun -SkipSemanticModel
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$TenantId,
    [string]$TenantDomain,
    [string]$CapacityId,
    [string]$WorkspaceName,
    [string]$IdentitiesPath = (Join-Path $PSScriptRoot 'out/fgd-identities.json'),
    [switch]$SkipSemanticModel,
    [switch]$SkipPipelineRun,
    [switch]$CreateAnalystSandbox,
    [string]$SandboxWorkspaceName = 'FGD-Analyst-Sandbox',
    [int]$MirroringTimeoutMinutes = 20,
    [int]$PipelineTimeoutMinutes = 45,
    [switch]$UseDeviceAuthentication,
    [string]$OutDir = (Join-Path $PSScriptRoot 'out')
)

$ErrorActionPreference = 'Stop'
$KitRoot        = Split-Path $PSScriptRoot -Parent
$FabricApi      = 'https://api.fabric.microsoft.com'
$FabricResource = 'https://api.fabric.microsoft.com'
$SqlResource    = 'https://database.windows.net/'
$StorageResource = 'https://storage.azure.com/'
$PbiResource    = 'https://analysis.windows.net/powerbi/api'
$Started        = Get-Date

function Write-Step([string]$Message) { Write-Host "[step] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "  [ok] $Message" -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "  [..] $Message" -ForegroundColor Gray }
function Write-Warn([string]$Message) { Write-Host "  [warn] $Message" -ForegroundColor Yellow }

# ================================================================== configuration
Write-Step 'Reading configuration'
$cfg = if (Test-Path $ConfigPath) { Get-Content $ConfigPath -Raw | ConvertFrom-Json } else { $null }
function Get-Setting($Value, [string]$Name, $Default) {
    if ($Value) { return $Value }
    if ($cfg -and $cfg.PSObject.Properties[$Name] -and $cfg.$Name -and ($cfg.$Name -notmatch '^0{8}-0{4}-')) { return $cfg.$Name }
    return $Default
}
$TenantId      = Get-Setting $TenantId      'tenantId'      $null
$TenantDomain  = Get-Setting $TenantDomain  'tenantDomain'  $null
$CapacityId    = Get-Setting $CapacityId    'capacityId'    $null
$WorkspaceName = Get-Setting $WorkspaceName 'workspaceName' 'FGD-Security-Demo'
if (-not $CapacityId)   { throw 'CapacityId is required (Admin portal > Capacity settings > your F-SKU > capacity id).' }
if (-not $TenantDomain) { throw 'TenantDomain is required.' }
if (-not (Test-Path $IdentitiesPath)) { throw "Identities file not found: $IdentitiesPath. Run 01-New-FgdIdentities.ps1 first." }
$ids = Get-Content $IdentitiesPath -Raw | ConvertFrom-Json
if (-not $TenantId) { $TenantId = $ids.tenantId }
$Prefix = if ($ids.prefix) { $ids.prefix } else { 'fgd' }
Write-Info "workspace=$WorkspaceName capacity=$CapacityId tenantDomain=$TenantDomain prefix=$Prefix"

foreach ($m in 'Az.Accounts', 'SqlServer') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Module $m not found. Install-Module $m -Scope CurrentUser" }
}
Import-Module Az.Accounts -ErrorAction Stop
Import-Module SqlServer -ErrorAction Stop
if (-not (Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('AccessToken')) { throw 'SqlServer module v22+ is required (Invoke-Sqlcmd -AccessToken).' }

# ================================================================== auth helpers
Write-Step 'Signing in to Azure (Az.Accounts)'
$azCtx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $azCtx -or ($TenantId -and $azCtx.Tenant.Id -ne $TenantId)) {
    $connect = @{ ErrorAction = 'Stop' }
    if ($TenantId) { $connect.Tenant = $TenantId }
    if ($UseDeviceAuthentication) { $connect.UseDeviceAuthentication = $true }
    $connect.AuthScope = 'https://api.fabric.microsoft.com'
    Connect-AzAccount @connect | Out-Null
    $azCtx = Get-AzContext
}
Write-Ok "signed in as $($azCtx.Account.Id)"

$script:TokenCache = @{}
function Get-Token([string]$ResourceUrl) {
    # Newer Az.Accounts returns Token as SecureString; older returns a string.
    # When Conditional Access (MFA) requires interaction for a resource, sign in again
    # with -AuthScope for that resource (one browser prompt per resource), then retry.
    $t = $null
    try {
        $t = Get-AzAccessToken -ResourceUrl $ResourceUrl -ErrorAction Stop -WarningAction SilentlyContinue
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -notmatch 'interaction|AuthScope|multi-factor|MFA|AADSTS50076|AADSTS50079|AADSTS53003|claims') { throw }
        if ($script:TokenCache[$ResourceUrl]) { throw }   # already re-authenticated once for this resource
        Write-Info "Conditional Access needs an interactive sign-in for $ResourceUrl - opening sign-in..."
        $re = @{ AuthScope = $ResourceUrl; ErrorAction = 'Stop' }
        if ($TenantId) { $re.Tenant = $TenantId }
        if ($UseDeviceAuthentication) { $re.UseDeviceAuthentication = $true }
        Connect-AzAccount @re -WarningAction SilentlyContinue | Out-Null
        $script:TokenCache[$ResourceUrl] = $true
        $t = Get-AzAccessToken -ResourceUrl $ResourceUrl -ErrorAction Stop -WarningAction SilentlyContinue
    }
    if ($t.Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $t.Token).Password
    }
    return [string]$t.Token
}

# ================================================================== Fabric REST helpers
function Get-HeaderValue($Response, [string]$Name) {
    foreach ($k in $Response.Headers.Keys) {
        if ($k -ieq $Name) { return [string]($Response.Headers[$k] | Select-Object -First 1) }
    }
    return $null
}

function Get-RetryAfter($Response, [int]$Default = 5) {
    $v = Get-HeaderValue $Response 'Retry-After'
    $n = 0
    if ($v -and [int]::TryParse($v, [ref]$n)) { return [Math]::Min([Math]::Max($n, 2), 60) }
    return $Default
}

function ConvertFrom-FabricContent($Response) {
    $c = $Response.Content
    if ($c -is [byte[]]) { $c = [System.Text.Encoding]::UTF8.GetString($c) }
    if ([string]::IsNullOrWhiteSpace($c)) { return $null }
    try { return $c | ConvertFrom-Json } catch { return $c }
}

function Invoke-Fabric {
    <#
      Calls the Fabric REST API.
      - 429 and 5xx: retried with Retry-After.
      - 202: long-running operation; polls Location / x-ms-operation-id until done,
        then returns /v1/operations/{id}/result when available.
      - -Raw returns the raw response (no error/LRO handling) for job scheduler calls.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        $Body,
        [switch]$Raw,
        [int]$MaxAttempts = 8,
        [int]$LroTimeoutMinutes = 30
    )
    $uri = if ($Path -match '^https?://') { $Path } else { "$FabricApi$Path" }
    $json = $null
    if ($null -ne $Body) { $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 64 -Compress } }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $req = @{
            Method             = $Method
            Uri                = $uri
            Headers            = @{ Authorization = "Bearer $(Get-Token $FabricResource)" }
            SkipHttpErrorCheck = $true
            ErrorAction        = 'Stop'
        }
        if ($null -ne $json) {
            $req.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
            $req.ContentType = 'application/json; charset=utf-8'
        }
        $resp = Invoke-WebRequest @req
        $code = [int]$resp.StatusCode
        if (($code -eq 429 -or $code -ge 500) -and $attempt -lt $MaxAttempts) {
            $wait = Get-RetryAfter $resp (5 * $attempt)
            Write-Info "HTTP $code on $Method $uri - retry $attempt/$MaxAttempts in $wait s"
            Start-Sleep -Seconds $wait
            continue
        }
        if ($Raw) { return $resp }
        if ($code -ge 400) {
            $detail = ConvertFrom-FabricContent $resp
            $text = if ($detail -is [string]) { $detail } else { $detail | ConvertTo-Json -Depth 10 -Compress }
            $ex = [System.Exception]::new("Fabric $Method $uri -> HTTP $code $text")
            $ex.Data['StatusCode'] = $code
            throw $ex
        }
        if ($code -eq 202) { return Wait-FabricOperation -Response $resp -TimeoutMinutes $LroTimeoutMinutes }
        return ConvertFrom-FabricContent $resp
    }
}

function Wait-FabricOperation {
    param($Response, [int]$TimeoutMinutes = 30)
    $opId = Get-HeaderValue $Response 'x-ms-operation-id'
    $location = Get-HeaderValue $Response 'Location'
    if (-not $location -and $opId) { $location = "$FabricApi/v1/operations/$opId" }
    if (-not $location) { return ConvertFrom-FabricContent $Response }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $delay = Get-RetryAfter $Response 5
    while ($true) {
        Start-Sleep -Seconds $delay
        $poll = Invoke-Fabric -Method GET -Path $location -Raw
        if ([int]$poll.StatusCode -ge 400) { throw "Operation poll failed: HTTP $([int]$poll.StatusCode) $($poll.Content)" }
        $state = ConvertFrom-FabricContent $poll
        $status = if ($state -and $state.PSObject.Properties['status']) { [string]$state.status } else { 'Unknown' }
        switch ($status) {
            'Succeeded' {
                if ($opId) {
                    $res = Invoke-Fabric -Method GET -Path "/v1/operations/$opId/result" -Raw
                    if ([int]$res.StatusCode -lt 300) { return ConvertFrom-FabricContent $res }
                }
                return $state
            }
            { $_ -in 'Failed', 'Cancelled' } {
                $err = if ($state.PSObject.Properties['error']) { $state.error | ConvertTo-Json -Depth 10 -Compress } else { '' }
                throw "Long-running operation $opId $($status): $err"
            }
            default {
                if ((Get-Date) -gt $deadline) { throw "Long-running operation $opId timed out after $TimeoutMinutes min (last status $status)" }
                $pct = if ($state -and $state.PSObject.Properties['percentComplete']) { " $($state.percentComplete)%" } else { '' }
                Write-Info "operation $($status)$pct ..."
                $delay = Get-RetryAfter $poll 5
            }
        }
    }
}

function Get-FabricList([string]$Path) {
    # Follows continuationUri paging; returns all "value" entries.
    $all = [System.Collections.Generic.List[object]]::new()
    $next = $Path
    while ($next) {
        $r = Invoke-Fabric -Path $next
        if ($r -and $r.PSObject.Properties['value']) { foreach ($v in $r.value) { $all.Add($v) } }
        $next = if ($r -and $r.PSObject.Properties['continuationUri']) { $r.continuationUri } else { $null }
    }
    return $all.ToArray()
}

function Find-FabricItem([string]$WorkspaceId, [string]$Type, [string]$Name) {
    return Get-FabricList "/v1/workspaces/$WorkspaceId/items?type=$Type" |
        Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
}

function New-OrGetItem([string]$WorkspaceId, [string]$Type, [string]$Endpoint, [string]$Name, [hashtable]$Extra = @{}) {
    $existing = Find-FabricItem $WorkspaceId $Type $Name
    if ($existing) { Write-Info "$Type '$Name' exists ($($existing.id))"; return $existing }
    $body = @{ displayName = $Name }
    foreach ($k in $Extra.Keys) { $body[$k] = $Extra[$k] }
    $created = Invoke-Fabric -Method POST -Path "/v1/workspaces/$WorkspaceId/$Endpoint" -Body $body
    if (-not $created -or -not $created.PSObject.Properties['id']) {
        Start-Sleep -Seconds 5
        $created = Find-FabricItem $WorkspaceId $Type $Name
    }
    if (-not $created) { throw "$Type '$Name' was not found after creation." }
    Write-Ok "created $Type '$Name' ($($created.id))"
    return $created
}

function ConvertTo-InlinePart([string]$PartPath, [string]$Text) {
    return @{ path = $PartPath; payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)); payloadType = 'InlineBase64' }
}

function Set-ItemWithDefinition([string]$WorkspaceId, [string]$Type, [string]$Endpoint, [string]$Name, [string]$Description, [hashtable]$Definition) {
    # Create with definition, or update the definition of an existing item.
    $existing = Find-FabricItem $WorkspaceId $Type $Name
    if ($existing) {
        Invoke-Fabric -Method POST -Path "/v1/workspaces/$WorkspaceId/$Endpoint/$($existing.id)/updateDefinition" -Body @{ definition = $Definition } | Out-Null
        Write-Ok "updated $Type '$Name' definition ($($existing.id))"
        return $existing
    }
    $created = Invoke-Fabric -Method POST -Path "/v1/workspaces/$WorkspaceId/$Endpoint" -Body @{ displayName = $Name; description = $Description; definition = $Definition }
    if (-not $created -or -not $created.PSObject.Properties['id']) { Start-Sleep -Seconds 5; $created = Find-FabricItem $WorkspaceId $Type $Name }
    if (-not $created) { throw "$Type '$Name' was not found after creation." }
    Write-Ok "created $Type '$Name' ($($created.id))"
    return $created
}

function Test-OneLakePath([string]$WorkspaceId, [string]$ItemId, [string]$RelativePath) {
    # ADLS Gen2 "Get Properties" (HEAD) against OneLake: 200 = exists.
    $uri = "https://onelake.dfs.fabric.microsoft.com/$WorkspaceId/$ItemId/$RelativePath"
    $r = Invoke-WebRequest -Method Head -Uri $uri -SkipHttpErrorCheck -Headers @{
        Authorization  = "Bearer $(Get-Token $StorageResource)"
        'x-ms-version' = '2023-11-03'
    }
    return ([int]$r.StatusCode -eq 200)
}

function Invoke-FabricSql([string]$Server, [string]$Database, [string]$InputFile, [string[]]$Variables) {
    $p = @{
        ServerInstance    = $Server
        Database          = $Database
        AccessToken       = (Get-Token $SqlResource)
        InputFile         = $InputFile
        QueryTimeout      = 1800
        ConnectionTimeout = 60
        OutputSqlErrors   = $true
        OutputAs          = 'DataSet'
        ErrorAction       = 'Stop'
        Verbose           = $true      # shows PRINT messages
    }
    if ($Variables) { $p.Variable = $Variables }
    $ds = Invoke-Sqlcmd @p 4>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.VerboseRecord]) { Write-Info $_.Message } else { $_ }
    }
    foreach ($set in @($ds)) {
        if ($set -is [System.Data.DataSet]) {
            foreach ($tbl in $set.Tables) { $tbl | Format-Table -AutoSize | Out-String -Width 200 | Write-Host }
        }
    }
}

# ================================================================== step runner
$S = @{}                     # shared state (hashtable so script blocks can write into it)
$Failures = [System.Collections.Generic.List[string]]::new()
function Invoke-Step([string]$Name, [string]$Fallback, [scriptblock]$Action) {
    Write-Step $Name
    $t0 = Get-Date
    try {
        $null = & $Action
        Write-Info ("{0:n0}s" -f ((Get-Date) - $t0).TotalSeconds)
        return $true
    }
    catch {
        Write-Host "  [fail] $Name : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  [fallback] $Fallback" -ForegroundColor Yellow
        $Failures.Add($Name)
        return $false
    }
}

# ================================================================== 1. workspace
$ok = Invoke-Step "Workspace '$WorkspaceName' on capacity $CapacityId" 'README > Setup > S4 (create workspace, assign capacity in Workspace settings > License info).' {
    $ws = Get-FabricList '/v1/workspaces' | Where-Object { $_.displayName -eq $WorkspaceName } | Select-Object -First 1
    if (-not $ws) {
        $ws = Invoke-Fabric -Method POST -Path '/v1/workspaces' -Body @{
            displayName = $WorkspaceName
            capacityId  = $CapacityId
            description = 'FGD - Fabric Governance and Security demo. SYNTHETIC DATA - for training only - no real customer data.'
        }
        Write-Ok "created workspace $($ws.id)"
    }
    else {
        Write-Info "workspace exists ($($ws.id))"
        if ($ws.PSObject.Properties['capacityId'] -and $ws.capacityId -ne $CapacityId) {
            Invoke-Fabric -Method POST -Path "/v1/workspaces/$($ws.id)/assignToCapacity" -Body @{ capacityId = $CapacityId } | Out-Null
            Write-Ok 'assigned to capacity'
        }
    }
    $S.wsId = $ws.id
}
if (-not $ok -or -not $S.wsId) { throw 'Cannot continue without a workspace.' }
$wsId = $S.wsId

# ================================================================== 2. role assignments
function Set-WorkspaceRoles([string]$WorkspaceId, [System.Collections.IDictionary]$RoleMap) {
    $existing = @(Get-FabricList "/v1/workspaces/$WorkspaceId/roleAssignments")
    foreach ($groupName in $RoleMap.Keys) {
        $role = $RoleMap[$groupName]
        $gid = $ids.groups.$groupName
        if (-not $gid) { Write-Warn "no object id for $groupName in $IdentitiesPath - skipped"; continue }
        $hit = $existing | Where-Object { $_.principal.id -eq $gid } | Select-Object -First 1
        if ($hit -and $hit.role -eq $role) { Write-Info "$groupName already $role"; continue }
        if ($hit) {
            Invoke-Fabric -Method PATCH -Path "/v1/workspaces/$WorkspaceId/roleAssignments/$($hit.id)" -Body @{ role = $role } | Out-Null
            Write-Ok "$groupName role changed $($hit.role) -> $role"
        }
        else {
            Invoke-Fabric -Method POST -Path "/v1/workspaces/$WorkspaceId/roleAssignments" -Body @{
                principal = @{ id = $gid; type = 'Group' }
                role      = $role
            } | Out-Null
            Write-Ok "$groupName -> $role"
        }
    }
}

Invoke-Step 'Workspace role assignments (groups only)' 'README > Setup > S4: Manage access > Add people or groups.' {
    $roleMap = [ordered]@{
        "sg-$Prefix-admins"    = 'Admin'
        "sg-$Prefix-engineers" = 'Contributor'
        "sg-$Prefix-analysts"  = 'Viewer'
        "sg-$Prefix-stewards"  = 'Viewer'
        "sg-$Prefix-auditors"  = 'Viewer'
    }
    Set-WorkspaceRoles $wsId $roleMap
} | Out-Null

# ================================================================== 3. lakehouses + warehouse
Invoke-Step 'Lakehouses lh_bronze, lh_silver (no schemas)' 'README > Setup > S5: New item > Lakehouse (leave "Lakehouse schemas" unticked).' {
    # VERIFY: lakehouses are created without schemas unless creationPayload.enableSchemas = true.
    $S.lhBronze = New-OrGetItem $wsId 'Lakehouse' 'lakehouses' 'lh_bronze' @{ description = 'Bronze: landed files + shortcuts (SYNTHETIC)' }
    $S.lhSilver = New-OrGetItem $wsId 'Lakehouse' 'lakehouses' 'lh_silver' @{ description = 'Silver: conformed tables, OneLake security demo (SYNTHETIC)' }
} | Out-Null

Invoke-Step 'Warehouse wh_gold' 'README > Setup > S5: New item > Warehouse > wh_gold.' {
    $S.whGold = New-OrGetItem $wsId 'Warehouse' 'warehouses' 'wh_gold' @{ description = 'Gold star schema, T-SQL security demo (SYNTHETIC)' }
} | Out-Null

# ================================================================== 4. SQL database + seed
Invoke-Step 'SQL database sqldb_core_banking' 'README > Setup > S5: New item > SQL database > sqldb_core_banking.' {
    try {
        # VERIFY: creationPayload.creationMode for SQL database; retried without it if rejected.
        $S.sqlDb = New-OrGetItem $wsId 'SQLDatabase' 'sqlDatabases' 'sqldb_core_banking' @{
            description     = 'Core banking OLTP, auto-replicated to OneLake (SYNTHETIC)'
            creationPayload = @{ creationMode = 'New' }
        }
    }
    catch {
        if ($_.Exception.Data['StatusCode'] -eq 400) {
            Write-Info 'retrying without creationPayload'
            $S.sqlDb = New-OrGetItem $wsId 'SQLDatabase' 'sqlDatabases' 'sqldb_core_banking' @{ description = 'Core banking OLTP, auto-replicated to OneLake (SYNTHETIC)' }
        }
        else { throw }
    }
    # Wait until connection properties are available
    for ($i = 0; $i -lt 30; $i++) {
        $db = Invoke-Fabric -Path "/v1/workspaces/$wsId/sqlDatabases/$($S.sqlDb.id)"
        if ($db.properties -and $db.properties.serverFqdn -and $db.properties.databaseName) { break }
        Write-Info 'waiting for SQL database provisioning ...'
        Start-Sleep -Seconds 10
    }
    $S.sqlServer = $db.properties.serverFqdn
    $S.sqlDbName = $db.properties.databaseName
    Write-Ok "server=$($S.sqlServer) database=$($S.sqlDbName)"
} | Out-Null

Invoke-Step 'Seed sqldb_core_banking (sql/10_sqldb_seed.sql)' 'README > Setup > S6: open sqldb_core_banking > New query > paste sql/10_sqldb_seed.sql > Run.' {
    if (-not $S.sqlServer) { throw 'SQL database connection info not available.' }
    Invoke-FabricSql -Server $S.sqlServer -Database $S.sqlDbName -InputFile (Join-Path $KitRoot 'sql/10_sqldb_seed.sql')
} | Out-Null

# ================================================================== 5. notebooks
function Get-NotebookDefinition([string]$File, [string]$LakehouseId, [string]$LakehouseName, [string]$LakehouseWorkspaceId) {
    $nb = Get-Content $File -Raw | ConvertFrom-Json -AsHashtable
    if ($LakehouseId) {
        if (-not $nb.metadata.ContainsKey('dependencies') -or $null -eq $nb.metadata.dependencies) { $nb.metadata.dependencies = @{} }
        $nb.metadata.dependencies.lakehouse = [ordered]@{
            default_lakehouse              = $LakehouseId
            default_lakehouse_name         = $LakehouseName
            default_lakehouse_workspace_id = $LakehouseWorkspaceId
        }
    }
    $json = $nb | ConvertTo-Json -Depth 100
    return @{ format = 'ipynb'; parts = @(ConvertTo-InlinePart 'notebook-content.ipynb' $json) }
}

$S.notebooks = [ordered]@{}
Invoke-Step 'Notebooks nb_01 / nb_02 / nb_03 (default lakehouse lh_silver)' 'README > Setup > S7: Import > Notebook > From this computer > notebooks/*.ipynb.' {
    foreach ($name in 'nb_01_ingest_files', 'nb_02_bronze_to_silver', 'nb_03_check_my_access') {
        $def = Get-NotebookDefinition (Join-Path $KitRoot "notebooks/$name.ipynb") $S.lhSilver.id 'lh_silver' $wsId
        $S.notebooks[$name] = Set-ItemWithDefinition $wsId 'Notebook' 'notebooks' $name 'FGD demo notebook (SYNTHETIC DATA)' $def
    }
} | Out-Null

# ================================================================== 6. pipeline
Invoke-Step 'Pipeline pl_daily_load (nb_01 -> nb_02)' 'README > Setup > S8: New item > Data pipeline > two Notebook activities, On success.' {
    $nb1 = $S.notebooks['nb_01_ingest_files']; $nb2 = $S.notebooks['nb_02_bronze_to_silver']
    if (-not $nb1 -or -not $nb2) { throw 'notebooks missing' }
    $policy = [ordered]@{ timeout = '0.01:00:00'; retry = 0; retryIntervalInSeconds = 30; secureOutput = $false; secureInput = $false }
    $content = [ordered]@{
        properties = [ordered]@{
            description = 'FGD demo daily load: ingest files to bronze, then bronze to silver. SYNTHETIC DATA.'
            activities  = @(
                [ordered]@{
                    name           = 'nb_01_ingest_files'
                    type           = 'TridentNotebook'
                    dependsOn      = @()
                    policy         = $policy
                    typeProperties = [ordered]@{ notebookId = $nb1.id; workspaceId = $wsId }
                },
                [ordered]@{
                    name           = 'nb_02_bronze_to_silver'
                    type           = 'TridentNotebook'
                    dependsOn      = @([ordered]@{ activity = 'nb_01_ingest_files'; dependencyConditions = @('Succeeded') })
                    policy         = $policy
                    typeProperties = [ordered]@{ notebookId = $nb2.id; workspaceId = $wsId }
                }
            )
        }
    }
    $def = @{ parts = @(ConvertTo-InlinePart 'pipeline-content.json' ($content | ConvertTo-Json -Depth 20)) }
    $S.pipeline = Set-ItemWithDefinition $wsId 'DataPipeline' 'dataPipelines' 'pl_daily_load' 'FGD demo daily load (SYNTHETIC DATA)' $def
} | Out-Null

# ================================================================== 7. wait for replication + run pipeline
if (-not $SkipPipelineRun) {
    Invoke-Step "Wait for sqldb_core_banking replication to OneLake (max $MirroringTimeoutMinutes min)" 'README > Setup > S6: sqldb_core_banking > Replication > Monitor replication shows all 3 tables "Running".' {
        $deadline = (Get-Date).AddMinutes($MirroringTimeoutMinutes)
        $tables = 'customers', 'accounts', 'transactions'
        while ($true) {
            # VERIFY: SQL database in Fabric replicates to <item>/Tables/dbo/<table> in OneLake.
            $ready = @($tables | Where-Object { Test-OneLakePath $wsId $S.sqlDb.id "Tables/dbo/$_/_delta_log" })
            Write-Info "replicated: $($ready.Count)/$($tables.Count) ($($ready -join ', '))"
            if ($ready.Count -eq $tables.Count) { break }
            if ((Get-Date) -gt $deadline) { throw 'replication not visible in OneLake yet' }
            Start-Sleep -Seconds 30
        }
        Start-Sleep -Seconds 30    # let the first replication cycle finish writing
    } | Out-Null

    Invoke-Step 'OneLake shortcuts lh_bronze/Tables/customers, accounts -> sqldb_core_banking' 'README > Setup > S8: lh_bronze > Tables > ... > New shortcut > Microsoft OneLake > sqldb_core_banking > Tables/dbo > tick customers, accounts > Create.' {
        # Created here with the presenter's token: a notebook's token lacks the scope the
        # shortcuts API needs (HTTP 403 InsufficientScopes), so nb_01 only checks they exist.
        foreach ($t in 'customers', 'accounts') {
            $r = Invoke-Fabric -Path "/v1/workspaces/$wsId/items/$($S.lhBronze.id)/shortcuts/Tables/$t" -Raw
            if ([int]$r.StatusCode -eq 200) { Write-Info "shortcut lh_bronze/Tables/$t exists"; continue }
            $body = @{
                path   = 'Tables'
                name   = $t
                target = @{ oneLake = @{ workspaceId = $wsId; itemId = $S.sqlDb.id; path = "Tables/dbo/$t" } }
            }
            Invoke-Fabric -Method POST -Path "/v1/workspaces/$wsId/items/$($S.lhBronze.id)/shortcuts" -Body $body | Out-Null
            Write-Ok "created shortcut lh_bronze/Tables/$t -> sqldb_core_banking/Tables/dbo/$t"
        }
    } | Out-Null

    Invoke-Step "Run pl_daily_load (max $PipelineTimeoutMinutes min)" 'README > Setup > S8: open pl_daily_load > Run; or run nb_01 then nb_02 manually.' {
        $resp = Invoke-Fabric -Method POST -Path "/v1/workspaces/$wsId/items/$($S.pipeline.id)/jobs/instances?jobType=Pipeline" -Raw
        if ([int]$resp.StatusCode -ne 202) { throw "run request failed: HTTP $([int]$resp.StatusCode) $($resp.Content)" }
        $jobUrl = Get-HeaderValue $resp 'Location'
        Write-Ok "job started: $jobUrl"
        $deadline = (Get-Date).AddMinutes($PipelineTimeoutMinutes)
        while ($true) {
            Start-Sleep -Seconds 20
            $job = Invoke-Fabric -Path $jobUrl
            Write-Info "pipeline status: $($job.status)"
            if ($job.status -eq 'Completed') { break }
            if ($job.status -in 'Failed', 'Cancelled', 'Deduped') {
                throw "pipeline $($job.status): $($job.failureReason | ConvertTo-Json -Depth 5 -Compress)"
            }
            if ((Get-Date) -gt $deadline) { throw 'pipeline still running - check Monitor hub' }
        }
        Write-Ok 'pipeline completed'
    } | Out-Null
}
else { Write-Warn 'SkipPipelineRun: run pl_daily_load yourself before building wh_gold.' }

# ================================================================== 8. lh_silver SQL endpoint refresh
Invoke-Step 'Refresh lh_silver SQL analytics endpoint metadata (best effort)' 'README > Setup > S9: open lh_silver SQL analytics endpoint > Refresh.' {
    $lh = $null
    for ($i = 0; $i -lt 30; $i++) {
        $lh = Invoke-Fabric -Path "/v1/workspaces/$wsId/lakehouses/$($S.lhSilver.id)"
        $sep = $lh.properties.sqlEndpointProperties
        if ($sep -and $sep.id -and $sep.provisioningStatus -eq 'Success') { break }
        Write-Info 'waiting for SQL analytics endpoint provisioning ...'
        Start-Sleep -Seconds 10
    }
    $S.silverSqlEndpointId = $sep.id
    $S.silverSqlConnection = $sep.connectionString
    try {
        Invoke-Fabric -Method POST -Path "/v1/workspaces/$wsId/sqlEndpoints/$($sep.id)/refreshMetadata" -Body @{} | Out-Null
    }
    catch {
        # Older tenants exposed this behind ?preview=true
        Invoke-Fabric -Method POST -Path "/v1/workspaces/$wsId/sqlEndpoints/$($sep.id)/refreshMetadata?preview=true" -Body @{} | Out-Null
    }
    Write-Ok 'metadata refresh requested'
    Start-Sleep -Seconds 30
} | Out-Null

# ================================================================== 9. wh_gold build
Invoke-Step 'Build wh_gold (sql/30_wh_gold_build.sql)' 'README > Setup > S9: open wh_gold > New SQL query > paste sql/30 (replace $(TenantDomain)) > Run.' {
    $wh = Invoke-Fabric -Path "/v1/workspaces/$wsId/warehouses/$($S.whGold.id)"
    $S.whConnection = $wh.properties.connectionString
    if (-not $S.whConnection) { throw 'warehouse connectionString not available' }
    Invoke-FabricSql -Server $S.whConnection -Database 'wh_gold' -InputFile (Join-Path $KitRoot 'sql/30_wh_gold_build.sql') -Variables @("TenantDomain=$TenantDomain")
} | Out-Null

# ================================================================== 10. semantic model
if (-not $SkipSemanticModel) {
    Invoke-Step 'Semantic model sm_gold_banking (Direct Lake, TMDL)' 'README > Setup > S10: wh_gold > New semantic model (pick gold.* + sec.user_province) > relationships, measures, roles by hand.' {
        if (-not $S.whConnection) {
            $wh = Invoke-Fabric -Path "/v1/workspaces/$wsId/warehouses/$($S.whGold.id)"
            $S.whConnection = $wh.properties.connectionString
        }
        $modelRoot = Join-Path $KitRoot 'model'
        $parts = foreach ($f in Get-ChildItem $modelRoot -Recurse -File) {
            $rel = [System.IO.Path]::GetRelativePath($modelRoot, $f.FullName).Replace('\', '/')
            $text = (Get-Content $f.FullName -Raw).Replace('__SQL_ENDPOINT__', $S.whConnection).Replace('__WAREHOUSE_ID__', $S.whGold.id)
            ConvertTo-InlinePart $rel $text
        }
        $S.semanticModel = Set-ItemWithDefinition $wsId 'SemanticModel' 'semanticModels' 'sm_gold_banking' 'Direct Lake on wh_gold; Province RLS + OLS (SYNTHETIC)' @{ parts = @($parts) }

        # Best effort: frame (refresh) the Direct Lake model via the Power BI REST API.
        try {
            Invoke-RestMethod -Method Post -Uri "https://api.powerbi.com/v1.0/myorg/groups/$wsId/datasets/$($S.semanticModel.id)/refreshes" `
                -Headers @{ Authorization = "Bearer $(Get-Token $PbiResource)" } -ContentType 'application/json' -Body '{"notifyOption":"NoNotification"}' | Out-Null
            Write-Ok 'refresh (framing) requested'
        }
        catch { Write-Warn "model refresh not started ($($_.Exception.Message)). Open the model > Refresh, or check Settings > data source credentials." }
    } | Out-Null
}
else { Write-Warn 'SkipSemanticModel: build sm_gold_banking by hand (README > Setup > S10).' }

# ================================================================== 11. optional analyst sandbox
if ($CreateAnalystSandbox) {
    Invoke-Step "Analyst sandbox workspace '$SandboxWorkspaceName' (Viewer personas can run nb_03 there)" 'README > Demo 4: create a workspace, add sg-fgd-analysts and sg-fgd-stewards as Contributor, import nb_03.' {
        $sb = Get-FabricList '/v1/workspaces' | Where-Object { $_.displayName -eq $SandboxWorkspaceName } | Select-Object -First 1
        if (-not $sb) {
            $sb = Invoke-Fabric -Method POST -Path '/v1/workspaces' -Body @{
                displayName = $SandboxWorkspaceName
                capacityId  = $CapacityId
                description = 'FGD demo: personal sandbox where Viewer personas run nb_03 against FGD-Security-Demo. SYNTHETIC.'
            }
            Write-Ok "created sandbox $($sb.id)"
        }
        $S.sandboxId = $sb.id
        Set-WorkspaceRoles $sb.id ([ordered]@{
                "sg-$Prefix-admins"    = 'Admin'
                "sg-$Prefix-engineers" = 'Contributor'
                "sg-$Prefix-analysts"  = 'Contributor'
                "sg-$Prefix-stewards"  = 'Contributor'
            })
        $def = Get-NotebookDefinition (Join-Path $KitRoot 'notebooks/nb_03_check_my_access.ipynb') $null $null $null
        $S.sandboxNotebook = Set-ItemWithDefinition $sb.id 'Notebook' 'notebooks' 'nb_03_check_my_access' 'FGD demo: who am I and what can I see (SYNTHETIC)' $def
    } | Out-Null
}

# ================================================================== outputs
Write-Step 'Writing ./out/fgd-workspace.json'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
function Get-Id($o) { if ($o -and $o.PSObject.Properties['id']) { return $o.id } else { return $null } }
$out = [ordered]@{
    generatedAt   = (Get-Date).ToString('s')
    tenantId      = $TenantId
    workspaceName = $WorkspaceName
    workspaceId   = $wsId
    capacityId    = $CapacityId
    items         = [ordered]@{
        sqldb_core_banking     = Get-Id $S.sqlDb
        lh_bronze              = Get-Id $S.lhBronze
        lh_silver              = Get-Id $S.lhSilver
        wh_gold                = Get-Id $S.whGold
        nb_01_ingest_files     = Get-Id $S.notebooks['nb_01_ingest_files']
        nb_02_bronze_to_silver = Get-Id $S.notebooks['nb_02_bronze_to_silver']
        nb_03_check_my_access  = Get-Id $S.notebooks['nb_03_check_my_access']
        pl_daily_load          = Get-Id $S.pipeline
        sm_gold_banking        = Get-Id $S.semanticModel
    }
    sqlDatabase   = [ordered]@{ serverFqdn = $S.sqlServer; databaseName = $S.sqlDbName }
    lhSilverSqlEndpoint = [ordered]@{ id = $S.silverSqlEndpointId; connectionString = $S.silverSqlConnection }
    whGold        = [ordered]@{ connectionString = $S.whConnection; database = 'wh_gold' }
    sandbox       = if ($S.sandboxId) { [ordered]@{ workspaceName = $SandboxWorkspaceName; workspaceId = $S.sandboxId; nb_03_check_my_access = (Get-Id $S.sandboxNotebook) } } else { $null }
    failedSteps   = @($Failures)
}
$outPath = Join-Path $OutDir 'fgd-workspace.json'
$out | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding utf8
Write-Ok "-> $outPath"

$elapsed = (Get-Date) - $Started
if ($Failures.Count -gt 0) {
    Write-Host ("[step] Finished in {0:n0} min with {1} failed step(s): {2}" -f $elapsed.TotalMinutes, $Failures.Count, ($Failures -join '; ')) -ForegroundColor Yellow
    Write-Host '       Use the printed README fallbacks, then rerun this script (it is idempotent).' -ForegroundColor Yellow
}
else {
    Write-Host ("[step] Finished in {0:n0} min. Next: click steps in README (report, model role members, data agent), optional 03-Grant-FgdDemoAccess.ps1." -f $elapsed.TotalMinutes) -ForegroundColor Green
}
