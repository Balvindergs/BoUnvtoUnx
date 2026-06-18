# ==============================================================
#  CONFIGURATION - update these values before running
# ==============================================================
$BO_SERVER   = "your_bo_server"
$BO_PORT     = 6405              # HTTP port used only for logon/logoff
$USERNAME    = "administrator"
$PASSWORD    = "your_password"
$AUTH_TYPE   = "secEnterprise"

# Source UNV - specify EITHER the CUID or the filename
$SOURCE_UNV_NAME = "MyUniverse.unv"
$SOURCE_UNV_CUID = ""

# Target UNX - specify EITHER the CUID or the filename
$TARGET_UNX_NAME = "MyUniverse.unx"
$TARGET_UNX_CUID = ""

$DRY_RUN = $true   # Set to $false to actually save changes
# ==============================================================

$REST_BASE = "http://"  + $BO_SERVER + ":" + $BO_PORT + "/biprws"
$INFOSTORE = "https://" + $BO_SERVER + "/biprws/infostore"
$RAYLIGHT  = "https://" + $BO_SERVER + "/biprws/raylight/v1"
$SL        = "https://" + $BO_SERVER + "/biprws/sl/v1"
$SEP       = "=" * 60

[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
    param($sender, $cert, $chain, $errors); return $true
}
[System.Net.ServicePointManager]::SecurityProtocol = (
    [System.Net.SecurityProtocolType]::Tls12 -bor
    [System.Net.SecurityProtocolType]::Tls11 -bor
    [System.Net.SecurityProtocolType]::Tls
)
[System.Net.ServicePointManager]::Expect100Continue = $false

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

# Look up universe CUID by name.
# Pass 1: sl/v1/universes (UNX universes).
# Pass 2: InfoStore CMS query fallback (covers UNV universes not listed by sl/v1/universes).
function Resolve-UniverseCuid($name) {
    $amp      = [char]38
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($name)

    # Pass 1 - sl/v1/universes
    try {
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
    } catch {
        Write-Host ("  [Universe Lookup sl Error] " + $_.Exception.Message) -ForegroundColor Red
    }

    # Pass 2 - AppObjects CMS query (UNV files: CI_APPOBJECTS WHERE SI_KIND='Universe')
    try {
        $query        = "SELECT SI_CUID,SI_ID,SI_NAME FROM CI_APPOBJECTS WHERE SI_KIND='Universe'"
        $encodedQuery = [Uri]::EscapeDataString($query)
        $offset       = 0
        $limit        = 50
        do {
            $url     = $INFOSTORE + "?query=" + $encodedQuery + $amp + "offset=" + $offset + $amp + "limit=" + $limit
            $resp    = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
            $entries = if ($resp.entries) { @($resp.entries) } elseif ($resp.entry) { @($resp.entry) } else { $null }
            if ($entries) {
                $m = $entries | Where-Object {
                    $n = if ($_.name) { $_.name } elseif ($_.title) { $_.title } else { "" }
                    $n -eq $name -or $n -eq $baseName -or $n -like ($baseName + ".*")
                } | Select-Object -First 1
                if ($m) {
                    $cuid = if ($m.cuid) { $m.cuid } elseif ($m.SI_CUID) { $m.SI_CUID } else { $null }
                    if ($cuid) { return $cuid }
                }
            }
            $offset += $limit
        } while ($entries -and $entries.Count -eq $limit)
    } catch {
        Write-Host ("  [Universe Lookup CMS Error] " + $_.Exception.Message) -ForegroundColor Red
    }

    return $null
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

# List ONLY base WebI reports via infostore - excludes scheduled instances (SI_INSTANCE=0) and recurring schedule objects (SI_RECURRING=0)
function Get-AllWebiDocs {
    $docs   = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    $limit  = 50
    $amp    = [char]38
    $query  = "SELECT SI_ID,SI_NAME FROM CI_INFOOBJECTS WHERE SI_PROGID='CrystalEnterprise.WebiReport' AND SI_INSTANCE=0 AND SI_RECURRING=0"

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

# GET /dataproviders with retry on transient connection errors
function Get-DataProviders($docId) {
    $url = $RAYLIGHT + "/documents/" + $docId + "/dataproviders"
    for ($i = 0; $i -le 2; $i++) {
        try {
            $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
            if ($resp.dataproviders -and $resp.dataproviders.dataprovider) { return @($resp.dataproviders.dataprovider) }
            if ($resp.dataproviders) { return @($resp.dataproviders) }
            if ($resp.dataprovider)  { return @($resp.dataprovider) }
            return @()
        } catch {
            $msg = $_.Exception.Message
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -eq 404) { return "skip" }
            if ($i -lt 2 -and $msg -like "*connection was closed*") {
                Start-Sleep -Milliseconds 800
                continue
            }
            Write-Host ("  [DP Error] " + $msg) -ForegroundColor DarkRed
            return $null
        }
    }
    return $null
}

function Set-DataProviders($docId, $dpIds) {
    $url   = $RAYLIGHT + "/documents/" + $docId + "/dataproviders"
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
    $seenCuids      = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($doc in $docs) {
        $docId   = $doc.id
        $docName = if ($doc.name)    { $doc.name }
                   elseif ($doc.title)   { $doc.title }
                   elseif ($doc.SI_NAME) { $doc.SI_NAME }
                   else { "ID:" + $docId }

        $dps = Get-DataProviders $docId
        if ($dps -eq "skip")  { $skippedNoMatch++; continue }
        if ($null -eq $dps)   { $failed++;         continue }
        if ($dps.Count -eq 0) { $skippedNoMatch++; continue }

        $dpInfo = ($dps | ForEach-Object {
            $c = if ($_.universe -and $_.universe.cuid) { $_.universe.cuid }
                 elseif ($_.dataSource -and $_.dataSource.cuid) { $_.dataSource.cuid }
                 else { "?" }
            $seenCuids.Add($c) | Out-Null
            $_.id + "=" + $c
        }) -join "  "
        Write-Host ("  [SCAN] " + $docName + " | " + $dpInfo) -ForegroundColor DarkCyan

        $matchedIds = @($dps | Where-Object {
            ($_.universe   -and $_.universe.cuid   -eq $SOURCE_UNV_CUID) -or
            ($_.dataSource -and $_.dataSource.cuid -eq $SOURCE_UNV_CUID)
        } | ForEach-Object { $_.id })

        if ($matchedIds.Count -eq 0) { $skippedNoMatch++; continue }

        Write-Host ("[" + (Get-Timestamp) + "] MATCH: " + $docName + " (ID:" + $docId + ") - DPs: " + ($matchedIds -join ", ")) -ForegroundColor Yellow

        if ($DRY_RUN) {
            Write-Host "  [DRY RUN] Would repoint." -ForegroundColor Gray
            $success++
            continue
        }

        $status = Set-DataProviders $docId $matchedIds
        if ($status -in @(200, 204)) {
            Write-Host "  [OK] Repointed." -ForegroundColor Green
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

    # If nothing matched, print the unique universe CUIDs seen across all reports to aid diagnosis
    if ($success -eq 0 -and $skippedNoMatch -gt 0 -and $seenCuids.Count -gt 0) {
        Write-Host ""
        Write-Host "  [DIAG] No reports matched SOURCE_UNV_CUID: $SOURCE_UNV_CUID" -ForegroundColor Yellow
        Write-Host "  [DIAG] Universe CUIDs actually seen in reports:" -ForegroundColor Yellow
        $seenCuids | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor Yellow }
        Write-Host "  [DIAG] If the correct CUID appears above, set SOURCE_UNV_CUID directly in config." -ForegroundColor Yellow
    }

} finally {
    Invoke-BOLogoff
}