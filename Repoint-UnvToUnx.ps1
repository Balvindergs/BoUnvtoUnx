# ==============================================================
#  CONFIGURATION - update these values before running
# ==============================================================
$BO_SERVER   = "your_bo_server"
$BO_PORT     = 6405              # HTTP port used only for logon/logoff
$USERNAME    = "administrator"
$PASSWORD    = "your_password"
$AUTH_TYPE   = "secEnterprise"

# Source UNV - specify EITHER the CUID or the filename (script will look up the other)
$SOURCE_UNV_NAME = "MyUniverse.unv"   # e.g. "Sales.unv"  (set to "" if using CUID)
$SOURCE_UNV_CUID = ""                 # e.g. "AUBFikpv32Nv_c" (set to "" if using name)

# Target UNX - specify EITHER the CUID or the filename (script will look up the other)
$TARGET_UNX_NAME = "MyUniverse.unx"   # e.g. "Sales.unx"  (set to "" if using CUID)
$TARGET_UNX_CUID = ""                 # e.g. "CX2pwjuQLcwIs_6XI" (set to "" if using name)

$DRY_RUN = $true   # Set to $false to actually save changes
# ==============================================================

$REST_BASE = "http://"  + $BO_SERVER + ":" + $BO_PORT + "/biprws"
$RAYLIGHT  = "https://" + $BO_SERVER + "/biprws/raylight/v1"
$SL        = "https://" + $BO_SERVER + "/biprws/sl/v1"
$SEP       = "=" * 60

[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
    param($sender, $cert, $chain, $errors); return $true
}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$script:AuthHeaders = @{ "Content-Type" = "application/xml"; "Accept" = "application/xml" }
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

# Look up a universe from sl/v1/universes by name and return its CUID
function Resolve-UniverseCuid($name) {
    try {
        $amp  = [char]38
        $page = 1
        $size = 100
        do {
            $url  = $SL + "/universes?page=" + $page + $amp + "pageSize=" + $size
            $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession

            $list = $null
            if ($resp.universes -and $resp.universes.universe) { $list = @($resp.universes.universe) }
            elseif ($resp.universe) { $list = @($resp.universe) }

            if ($list) {
                $match = $list | Where-Object {
                    $_.name -eq $name -or $_.fileName -eq $name -or
                    ($_.name -and $_.name.EndsWith($name))
                } | Select-Object -First 1
                if ($match) { return $match.cuid }
            }
            $page++
        } while ($list -and $list.Count -eq $size)

        return $null
    } catch {
        Write-Host ("  [Universe Lookup Error] " + $_.Exception.Message) -ForegroundColor Red
        return $null
    }
}

# List all universes (for diagnostics)
function Show-Universes {
    try {
        $amp  = [char]38
        $url  = $SL + "/universes?page=1" + $amp + "pageSize=200"
        $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
        $list = $null
        if ($resp.universes -and $resp.universes.universe) { $list = @($resp.universes.universe) }
        elseif ($resp.universe) { $list = @($resp.universe) }
        if ($list) {
            Write-Host ("  Found " + $list.Count + " universe(s):") -ForegroundColor Gray
            $list | ForEach-Object {
                Write-Host ("    " + $_.name + "  [" + $_.cuid + "]") -ForegroundColor Gray
            }
        }
    } catch {
        Write-Host ("  [Universe List Error] " + $_.Exception.Message) -ForegroundColor Red
    }
}

function Get-AllWebiDocs {
    $docs   = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    $limit  = 50
    $amp    = [char]38

    do {
        $url     = $RAYLIGHT + "/documents?limit=" + $limit + $amp + "offset=" + $offset
        $resp    = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
        $entries = $null
        if ($resp.documents -and $resp.documents.document) { $entries = @($resp.documents.document) }
        elseif ($resp.document)  { $entries = @($resp.document) }
        elseif ($resp.documents) { $entries = @($resp.documents) }
        if ($entries) { $docs.AddRange([object[]]$entries) }
        $offset += $limit
    } while ($entries -and $entries.Count -eq $limit)

    return $docs
}

function Get-DataProviders($docId) {
    try {
        $resp = Invoke-RestMethod -Uri ($RAYLIGHT + "/documents/" + $docId + "/dataProviders") `
            -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
        if ($resp.dataProviders -and $resp.dataProviders.dataProvider) { return @($resp.dataProviders.dataProvider) }
        if ($resp.dataProviders) { return @($resp.dataProviders) }
        if ($resp.dataProvider)  { return @($resp.dataProvider) }
        return @()
    } catch {
        Write-Host ("  [DP Error] " + $_.Exception.Message) -ForegroundColor DarkRed
        return $null
    }
}

function Set-DataProvider($docId, $dpId) {
    $url     = $RAYLIGHT + "/documents/" + $docId + "/dataProviders/" + $dpId
    $payload = '{"dataProvider":{"universe":{"cuid":"' + $TARGET_UNX_CUID + '","name":"' + $TARGET_UNX_NAME + '"}}}'
    try {
        $resp = Invoke-WebRequest -Uri $url -Method PUT -Body $payload `
            -Headers $script:AuthHeaders -WebSession $script:WebSession -UseBasicParsing
        return $resp.StatusCode
    } catch {
        Write-Host ("  [PUT Error] " + $_.Exception.Message) -ForegroundColor DarkRed
        return $_.Exception.Response.StatusCode.value__
    }
}

function Save-BODocument($docId) {
    try {
        $resp = Invoke-WebRequest -Uri ($RAYLIGHT + "/documents/" + $docId) -Method PUT `
            -Headers $script:AuthHeaders -WebSession $script:WebSession -UseBasicParsing
        return $resp.StatusCode
    } catch {
        Write-Host ("  [Save Error] " + $_.Exception.Message) -ForegroundColor DarkRed
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
        Write-Host ("Resolving source UNV CUID for: " + $SOURCE_UNV_NAME) -ForegroundColor Gray
        $SOURCE_UNV_CUID = Resolve-UniverseCuid $SOURCE_UNV_NAME
        if (-not $SOURCE_UNV_CUID) {
            Write-Host "Could not resolve source UNV CUID. Listing all available universes:" -ForegroundColor Red
            Show-Universes
            throw "Aborting - source universe not found."
        }
        Write-Host ("  Source UNV CUID: " + $SOURCE_UNV_CUID) -ForegroundColor Gray
    }

    if (-not $TARGET_UNX_CUID -and $TARGET_UNX_NAME) {
        Write-Host ("Resolving target UNX CUID for: " + $TARGET_UNX_NAME) -ForegroundColor Gray
        $TARGET_UNX_CUID = Resolve-UniverseCuid $TARGET_UNX_NAME
        if (-not $TARGET_UNX_CUID) {
            Write-Host "Could not resolve target UNX CUID. Listing all available universes:" -ForegroundColor Red
            Show-Universes
            throw "Aborting - target universe not found."
        }
        Write-Host ("  Target UNX CUID: " + $TARGET_UNX_CUID) -ForegroundColor Gray
    }

    if (-not $SOURCE_UNV_CUID) { throw "SOURCE_UNV_CUID is empty - set name or CUID in config." }
    if (-not $TARGET_UNX_CUID) { throw "TARGET_UNX_CUID is empty - set name or CUID in config." }

    Write-Host ""
    Write-Host (" Source : " + $SOURCE_UNV_NAME + "  [" + $SOURCE_UNV_CUID + "]")
    Write-Host (" Target : " + $TARGET_UNX_NAME + "  [" + $TARGET_UNX_CUID + "]")
    Write-Host ""

    $docs = Get-AllWebiDocs
    Write-Host ("[" + (Get-Timestamp) + "] Found " + $docs.Count + " WebI documents.")
    Write-Host ""

    $success        = 0
    $skippedNoMatch = 0
    $failed         = 0

    foreach ($doc in $docs) {
        $docId   = $doc.id
        $docName = if ($doc.name) { $doc.name } elseif ($doc.title) { $doc.title } else { "ID:" + $docId }

        $dps = Get-DataProviders $docId
        if ($null -eq $dps)   { $failed++;         continue }
        if ($dps.Count -eq 0) { $skippedNoMatch++; continue }

        $dpCuids = ($dps | ForEach-Object {
            if ($_.dataSource -and $_.dataSource.cuid) { $_.dataSource.cuid }
            elseif ($_.universe -and $_.universe.cuid) { $_.universe.cuid }
            else { $_.cuid }
        }) -join ", "
        Write-Host ("  [SCAN] " + $docName + " (ID:" + $docId + ")  CUIDs: " + $dpCuids) -ForegroundColor DarkCyan

        $matched = @($dps | Where-Object {
            ($_.universe   -and $_.universe.cuid   -eq $SOURCE_UNV_CUID) -or
            ($_.dataSource -and $_.dataSource.cuid -eq $SOURCE_UNV_CUID) -or
            ($_.cuid -eq $SOURCE_UNV_CUID)
        })

        if ($matched.Count -eq 0) { $skippedNoMatch++; continue }

        Write-Host ("[" + (Get-Timestamp) + "] MATCH: " + $docName + " (ID:" + $docId + ") - " + $matched.Count + " DP(s)") -ForegroundColor Yellow

        if ($DRY_RUN) {
            Write-Host "  [DRY RUN] Would repoint." -ForegroundColor Gray
            $success++
            continue
        }

        $allOk = $true
        foreach ($dp in $matched) {
            $status = Set-DataProvider $docId $dp.id
            if ($status -in @(200, 204)) {
                Write-Host ("  [OK] DP " + $dp.id + " repointed.") -ForegroundColor Green
            } else {
                Write-Host ("  [FAIL] DP " + $dp.id + " HTTP " + $status) -ForegroundColor Red
                $allOk = $false
            }
        }

        if ($allOk) {
            $status = Save-BODocument $docId
            if ($status -in @(200, 204)) {
                Write-Host "  [OK] Saved." -ForegroundColor Green; $success++
            } else {
                Write-Host ("  [FAIL] Save HTTP " + $status) -ForegroundColor Red; $failed++
            }
        } else { $failed++ }

        Close-BODocument $docId
    }

    Write-Host ""
    Write-Host $SEP -ForegroundColor Cyan
    Write-Host (" DONE - Repointed: " + $success + " | No match: " + $skippedNoMatch + " | Failed: " + $failed) -ForegroundColor Cyan
    Write-Host $SEP -ForegroundColor Cyan

} finally {
    Invoke-BOLogoff
}