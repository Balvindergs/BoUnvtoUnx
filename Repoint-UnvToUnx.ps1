# ==============================================================
#  CONFIGURATION - update these values before running
# ==============================================================
$BO_SERVER   = "your_bo_server"
$BO_PORT     = 6405              # HTTP port used only for logon/logoff
$USERNAME    = "administrator"
$PASSWORD    = "your_password"
$AUTH_TYPE   = "secEnterprise"

# Source UNV name (as it appears in the CMS)
$SOURCE_UNV_NAME = "MyUniverse.unv"

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

# Resolve a universe CUID by name.
# Pass 1: sl/v1/universes (UNX universes).
# Pass 2: CI_APPOBJECTS fallback (UNV universes).
function Resolve-UniverseCuid($name) {
    $amp      = [char]38
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($name)

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

    try {
        $query        = "SELECT SI_CUID,SI_ID,SI_NAME FROM CI_APPOBJECTS WHERE SI_KIND='Universe'"
        $encodedQuery = [Uri]::EscapeDataString($query)
        $offset       = 0; $limit = 50
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

# Find all base WebI reports linked to a universe using the PARENTS() CMS relationship query.
# This is more reliable than CUID matching via data providers.
function Get-LinkedWebiDocs($universeName) {
    $docs   = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    $limit  = 50
    $amp    = [char]38
    $query  = "SELECT SI_ID,SI_NAME FROM CI_INFOOBJECTS WHERE PARENTS(`"SI_NAME='webi-universe'`",`"SI_NAME='$universeName'`") AND SI_INSTANCE=0 AND SI_RECURRING=0"

    do {
        $encodedQuery = [Uri]::EscapeDataString($query)
        $url     = $INFOSTORE + "?query=" + $encodedQuery + $amp + "offset=" + $offset + $amp + "limit=" + $limit
        $resp    = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
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
            $msg  = $_.Exception.Message
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
    # Resolve target UNX CUID if not supplied directly
    if (-not $TARGET_UNX_CUID -and $TARGET_UNX_NAME) {
        Write-Host ("Resolving target UNX: " + $TARGET_UNX_NAME) -ForegroundColor Gray
        $TARGET_UNX_CUID = Resolve-UniverseCuid $TARGET_UNX_NAME
        if ($TARGET_UNX_CUID) {
            Write-Host ("  CUID: " + $TARGET_UNX_CUID) -ForegroundColor Gray
        } else {
            Write-Host "  Not found - set TARGET_UNX_CUID directly in config." -ForegroundColor Red
            throw "Aborting - target universe not found."
        }
    }
    if (-not $TARGET_UNX_CUID) { throw "TARGET_UNX_CUID is empty - set name or CUID in config." }

    Write-Host ""
    Write-Host (" Source UNV : " + $SOURCE_UNV_NAME)
    Write-Host (" Target UNX : " + $TARGET_UNX_NAME + "  [" + $TARGET_UNX_CUID + "]")
    Write-Host ""

    # Use PARENTS() CMS query to find only reports directly linked to the source UNV
    Write-Host ("Querying reports linked to: " + $SOURCE_UNV_NAME) -ForegroundColor Gray
    $docs = Get-LinkedWebiDocs $SOURCE_UNV_NAME
    Write-Host ("[" + (Get-Timestamp) + "] Found " + $docs.Count + " linked WebI report(s).")
    Write-Host ""

    if ($docs.Count -eq 0) {
        Write-Host "  No reports found. Verify SOURCE_UNV_NAME matches the exact CMS name of the universe." -ForegroundColor Yellow
    }

    $success = 0
    $failed  = 0

    foreach ($doc in $docs) {
        $docId   = $doc.id
        $docName = if ($doc.name)    { $doc.name }
                   elseif ($doc.title)   { $doc.title }
                   elseif ($doc.SI_NAME) { $doc.SI_NAME }
                   else { "ID:" + $docId }

        Write-Host ("[" + (Get-Timestamp) + "] Processing: " + $docName + " (ID:" + $docId + ")") -ForegroundColor Yellow

        $dps = Get-DataProviders $docId
        if ($dps -eq "skip" -or $null -eq $dps -or $dps.Count -eq 0) {
            Write-Host "  [SKIP] Could not retrieve data providers." -ForegroundColor DarkYellow
            $failed++
            continue
        }

        $dpIds = @($dps | ForEach-Object { $_.id })
        Write-Host ("  Data providers: " + ($dpIds -join ", ")) -ForegroundColor Gray

        if ($DRY_RUN) {
            Write-Host "  [DRY RUN] Would repoint " + $dpIds.Count + " DP(s) to: " + $TARGET_UNX_NAME -ForegroundColor Gray
            $success++
            continue
        }

        $status = Set-DataProviders $docId $dpIds
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
    Write-Host (" DONE - Repointed: " + $success + " | Failed: " + $failed) -ForegroundColor Cyan
    Write-Host $SEP -ForegroundColor Cyan

} finally {
    Invoke-BOLogoff
}