# ==============================================================
#  CONFIGURATION - update these values before running
# ==============================================================
$BO_SERVER   = "your_bo_server"
$BO_PORT     = 6405              # HTTP port used only for logon/logoff
$USERNAME    = "administrator"
$PASSWORD    = "your_password"
$AUTH_TYPE   = "secEnterprise"

# Source UNV - specify EITHER the CUID or the filename (script looks up the other)
$SOURCE_UNV_NAME = "MyUniverse.unv"   # e.g. "Sales.unv"  (set to "" if using CUID)
$SOURCE_UNV_CUID = ""                 # e.g. "AUBFikpv32Nv_c" (set to "" if using name)

# Target UNX - specify EITHER the CUID or the filename (script looks up the other)
$TARGET_UNX_NAME = "MyUniverse.unx"   # e.g. "Sales.unx"  (set to "" if using CUID)
$TARGET_UNX_CUID = ""                 # e.g. "CX2pwjuQLcwIs_6XI" (set to "" if using name)

$DRY_RUN = $true   # Set to $false to actually save changes
# ==============================================================

$REST_BASE  = "http://"  + $BO_SERVER + ":" + $BO_PORT + "/biprws"
$HTTPS_BASE = "https://" + $BO_SERVER + "/biprws"
$INFOSTORE  = $HTTPS_BASE + "/infostore"
$RAYLIGHT   = $HTTPS_BASE + "/raylight/v1"
$SL         = $HTTPS_BASE + "/sl/v1"
$SEP       = "=" * 60

[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
    param($sender, $cert, $chain, $errors); return $true
}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$script:AuthHeaders = @{ "Content-Type" = "application/xml"; "Accept" = "application/json" }
$script:WebSession  = $null

function Get-Timestamp { Get-Date -Format "HH:mm:ss" }

function Invoke-BOLogon {
    $xmlBody = "<attrs>" +
        "<attr name=`"userName`" type=`"string`">" + $USERNAME + "</attr>" +
        "<attr name=`"password`" type=`"string`">" + $PASSWORD + "</attr>" +
        "<attr name=`"auth`" type=`"string`">"  + $AUTH_TYPE  + "</attr>" +
        "</attrs>"

    $resp = Invoke-RestMethod -Uri ($REST_BASE + "/logon/long") -Method POST `
        -Body $xmlBody -Headers $script:AuthHeaders -SessionVariable "script:WebSession"

    $token = $resp.logonToken
    if (-not $token) {
        $token = $resp.attrs.attr |
            Where-Object { $_.name -eq "logonToken" } |
            Select-Object -ExpandProperty "#text"
    }
    if (-not $token) { throw "Logon failed - no token returned." }

    $script:AuthHeaders = @{
        "X-SAP-LogonToken" = ('"' + $token + '"')
        "Accept"           = "application/json"
        "Content-Type"     = "application/json"
    }
    Write-Host ("[" + (Get-Timestamp) + "] Logged in as " + $USERNAME) -ForegroundColor Green
}

function Invoke-BOLogoff {
    try {
        Invoke-RestMethod -Uri ($REST_BASE + "/logoff") -Method POST `
            -Headers $script:AuthHeaders -WebSession $script:WebSession | Out-Null
        Write-Host ("[" + (Get-Timestamp) + "] Logged off.") -ForegroundColor Gray
    } catch { }
}

# Look up a universe CUID by filename via sl/v1/universes
function Resolve-UniverseCuid($name) {
    try {
        $amp  = [char]38
        $page = 1
        do {
            $url  = $SL + "/universes?page=" + $page + $amp + "pageSize=100"
            $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
            $list = $null
            if ($resp.universes -and $resp.universes.universe) { $list = @($resp.universes.universe) }
            elseif ($resp.universe) { $list = @($resp.universe) }
            if ($list) {
                $m = $list | Where-Object { $_.name -eq $name -or $_.fileName -eq $name } | Select-Object -First 1
                if ($m) { return $m.cuid }
            }
            $page++
        } while ($list -and $list.Count -eq 100)
        return $null
    } catch {
        Write-Host ("  [Universe Lookup Error] " + $_.Exception.Message) -ForegroundColor Red
        return $null
    }
}

function Show-Universes {
    try {
        $amp  = [char]38
        $resp = Invoke-RestMethod -Uri ($SL + "/universes?page=1" + $amp + "pageSize=200") `
            -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
        $list = $null
        if ($resp.universes -and $resp.universes.universe) { $list = @($resp.universes.universe) }
        elseif ($resp.universe) { $list = @($resp.universe) }
        if ($list) {
            Write-Host ("  Available universes (" + $list.Count + "):") -ForegroundColor Gray
            $list | ForEach-Object { Write-Host ("    " + $_.name + "  [CUID: " + $_.cuid + "]") -ForegroundColor Gray }
        }
    } catch {
        Write-Host ("  [Universe List Error] " + $_.Exception.Message) -ForegroundColor Red
    }
}

# List base WebI reports only (SI_INSTANCE=0) via infostore, then use Raylight for DP operations
function Get-AllWebiDocs {
    $docs   = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    $limit  = 50
    $amp    = [char]38
    # SI_INSTANCE=0 ensures only base reports are returned, not scheduled instances
    $query  = "SELECT SI_ID,SI_NAME FROM CI_INFOOBJECTS WHERE SI_PROGID='CrystalEnterprise.WebiReport' AND SI_INSTANCE=0"

    do {
        $encodedQuery = [Uri]::EscapeDataString($query)
        $url  = $INFOSTORE + "?query=" + $encodedQuery + $amp + "offset=" + $offset + $amp + "limit=" + $limit
        $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
        $entries = $resp.entries
        if ($null -eq $entries) { $entries = $resp.entry }
        if ($entries) { $docs.AddRange([object[]](@($entries))) }
        $offset += $limit
    } while ($entries -and (@($entries)).Count -eq $limit)

    return $docs
}

# GET /dataproviders (lowercase - correct SAP API casing)
function Get-DataProviders($docId) {
    try {
        $url  = $RAYLIGHT + "/documents/" + $docId + "/dataproviders"
        $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
        # Response: {"dataproviders":[{"id":"DP0","universe":{"cuid":"..."},...}]}
        if ($resp.dataproviders -and $resp.dataproviders.dataprovider) { return @($resp.dataproviders.dataprovider) }
        if ($resp.dataproviders) { return @($resp.dataproviders) }
        if ($resp.dataprovider)  { return @($resp.dataprovider) }
        return @()
    } catch {
        Write-Host ("  [DP Error] " + $_.Exception.Message) -ForegroundColor DarkRed
        return $null
    }
}

# PUT /dataproviders with array payload (SAP-documented format)
function Set-DataProviders($docId, $dpIds) {
    $url = $RAYLIGHT + "/documents/" + $docId + "/dataproviders"
    # Build payload: {"dataproviders":[{"id":"DP0","universe":{"cuid":"...","name":"..."}},...]}
    $items = ($dpIds | ForEach-Object {
        '{"id":"' + $_ + '","universe":{"cuid":"' + $TARGET_UNX_CUID + '","name":"' + $TARGET_UNX_NAME + '"}}'
    }) -join ","
    $payload = '{"dataproviders":[' + $items + ']}'
    try {
        $resp = Invoke-WebRequest -Uri $url -Method PUT -Body $payload `
            -Headers $script:AuthHeaders -WebSession $script:WebSession -UseBasicParsing
        return $resp.StatusCode
    } catch {
        Write-Host ("  [PUT Error] HTTP " + $_.Exception.Response.StatusCode.value__ + " - " + $_.Exception.Message) -ForegroundColor DarkRed
        return $_.Exception.Response.StatusCode.value__
    }
}

function Save-BODocument($docId) {
    try {
        $resp = Invoke-WebRequest -Uri ($RAYLIGHT + "/documents/" + $docId) -Method PUT `
            -Headers $script:AuthHeaders -WebSession $script:WebSession -UseBasicParsing
        return $resp.StatusCode
    } catch {
        Write-Host ("  [Save Error] HTTP " + $_.Exception.Response.StatusCode.value__ + " - " + $_.Exception.Message) -ForegroundColor DarkRed
        return $_.Exception.Response.StatusCode.value__
    }
}

function Close-BODocument($docId) {
    try {
        Invoke-RestMethod -Uri ($RAYLIGHT + "/documents/" + $docId) -Method DELETE `
            -Headers $script:AuthHeaders -WebSession $script:WebSession | Out-Null
    } catch { }
}

# --- MAIN ---
Write-Host ""
Write-Host $SEP -ForegroundColor Cyan
Write-Host (" BO UNV to UNX Bulk Repointer  |  DRY_RUN=" + $DRY_RUN) -ForegroundColor Cyan
Write-Host $SEP -ForegroundColor Cyan
Write-Host ""

Invoke-BOLogon

try {
    # Resolve CUIDs from names if not supplied
    if (-not $SOURCE_UNV_CUID -and $SOURCE_UNV_NAME) {
        Write-Host ("Resolving source UNV: " + $SOURCE_UNV_NAME) -ForegroundColor Gray
        $SOURCE_UNV_CUID = Resolve-UniverseCuid $SOURCE_UNV_NAME
        if ($SOURCE_UNV_CUID) {
            Write-Host ("  CUID: " + $SOURCE_UNV_CUID) -ForegroundColor Gray
        } else {
            Write-Host "  Not found. Available universes:" -ForegroundColor Red
            Show-Universes
            throw "Aborting - source universe not found."
        }
    }

    if (-not $TARGET_UNX_CUID -and $TARGET_UNX_NAME) {
        Write-Host ("Resolving target UNX: " + $TARGET_UNX_NAME) -ForegroundColor Gray
        $TARGET_UNX_CUID = Resolve-UniverseCuid $TARGET_UNX_NAME
        if ($TARGET_UNX_CUID) {
            Write-Host ("  CUID: " + $TARGET_UNX_CUID) -ForegroundColor Gray
        } else {
            Write-Host "  Not found. Available universes:" -ForegroundColor Red
            Show-Universes
            throw "Aborting - target universe not found."
        }
    }

    if (-not $SOURCE_UNV_CUID) { throw "SOURCE_UNV_CUID is empty - set name or CUID in config." }
    if (-not $TARGET_UNX_CUID) { throw "TARGET_UNX_CUID is empty - set name or CUID in config." }

    Write-Host ""
    Write-Host (" Source : " + $SOURCE_UNV_NAME + "  [" + $SOURCE_UNV_CUID + "]")
    Write-Host (" Target : " + $TARGET_UNX_NAME + "  [" + $TARGET_UNX_CUID + "]")
    Write-Host ""

    $docs = Get-AllWebiDocs
    Write-Host ("[" + (Get-Timestamp) + "] Found " + $docs.Count + " base WebI reports (SI_INSTANCE=0).")
    Write-Host ""

    $success        = 0
    $skippedNoMatch = 0
    $failed         = 0

    foreach ($doc in $docs) {
        $docId   = $doc.id
        $docName = if ($doc.name) { $doc.name } elseif ($doc.title) { $doc.title } elseif ($doc.SI_NAME) { $doc.SI_NAME } else { "ID:" + $docId }

        $dps = Get-DataProviders $docId
        if ($null -eq $dps)   { $failed++;         continue }
        if ($dps.Count -eq 0) { $skippedNoMatch++; continue }

        # Show each DP's universe CUID for diagnostics
        $dpInfo = ($dps | ForEach-Object {
            $c = if ($_.universe -and $_.universe.cuid) { $_.universe.cuid }
                 elseif ($_.dataSource -and $_.dataSource.cuid) { $_.dataSource.cuid }
                 else { "?" }
            $_.id + "=" + $c
        }) -join "  "
        Write-Host ("  [SCAN] " + $docName + " | " + $dpInfo) -ForegroundColor DarkCyan

        # Find DPs whose universe CUID matches the source UNV
        $matchedIds = @($dps | Where-Object {
            ($_.universe -and $_.universe.cuid -eq $SOURCE_UNV_CUID) -or
            ($_.dataSource -and $_.dataSource.cuid -eq $SOURCE_UNV_CUID)
        } | ForEach-Object { $_.id })

        if ($matchedIds.Count -eq 0) { $skippedNoMatch++; continue }

        Write-Host ("[" + (Get-Timestamp) + "] MATCH: " + $docName + " (ID:" + $docId + ") - DPs: " + ($matchedIds -join ", ")) -ForegroundColor Yellow

        if ($DRY_RUN) {
            Write-Host "  [DRY RUN] Would repoint." -ForegroundColor Gray
            $success++
            continue
        }

        # Repoint all matched DPs in one PUT call
        $status = Set-DataProviders $docId $matchedIds
        if ($status -in @(200, 204)) {
            Write-Host "  [OK] Repointed." -ForegroundColor Green
            # Save document
            $saveStatus = Save-BODocument $docId
            if ($saveStatus -in @(200, 204)) {
                Write-Host "  [OK] Saved." -ForegroundColor Green
                $success++
            } else {
                Write-Host ("  [FAIL] Save HTTP " + $saveStatus) -ForegroundColor Red
                $failed++
            }
        } else {
            $failed++
        }

        Close-BODocument $docId
    }

    Write-Host ""
    Write-Host $SEP -ForegroundColor Cyan
    Write-Host (" DONE - Repointed: " + $success + " | No match: " + $skippedNoMatch + " | Failed: " + $failed) -ForegroundColor Cyan
    Write-Host $SEP -ForegroundColor Cyan

} finally {
    Invoke-BOLogoff
}