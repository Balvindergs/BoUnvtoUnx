# ==============================================================
#  CONFIGURATION - update these values before running
# ==============================================================
$BO_SERVER   = "your_bo_server"
$BO_PORT     = 6405           # REST API port (HTTP) - used for logon/logoff only
$USERNAME    = "administrator"
$PASSWORD    = "your_password"
$AUTH_TYPE   = "secEnterprise"

$SOURCE_UNV_CUID = "AUBFikpv32Nv_c"
$TARGET_UNX_CUID = "CX2pwjuQLcwIs_6XI"
$TARGET_UNX_NAME = "Jcxh.unx"

$DRY_RUN = $true   # Set to $false to actually save changes
# ==============================================================

# Logon uses HTTP + explicit port; Raylight uses HTTPS on default port
$REST_BASE = "http://" + $BO_SERVER + ":" + $BO_PORT + "/biprws"
$RAYLIGHT  = "https://" + $BO_SERVER + "/biprws/raylight/v1"
$SEP       = "=" * 60

[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
    param($sender, $cert, $chain, $errors)
    return $true
}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$script:AuthHeaders = @{
    "Content-Type" = "application/xml"
    "Accept"       = "application/xml"
}
$script:WebSession = $null

function Get-Timestamp { Get-Date -Format "HH:mm:ss" }

function Invoke-BOLogon {
    $xmlBody = "<attrs>" +
        "<attr name=`"userName`" type=`"string`">" + $USERNAME + "</attr>" +
        "<attr name=`"password`" type=`"string`">" + $PASSWORD + "</attr>" +
        "<attr name=`"auth`" type=`"string`">" + $AUTH_TYPE + "</attr>" +
        "</attrs>"

    $resp = Invoke-RestMethod `
        -Uri ($REST_BASE + "/logon/long") `
        -Method POST `
        -Body $xmlBody `
        -Headers $script:AuthHeaders `
        -SessionVariable "script:WebSession"

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

# Use Raylight /documents to enumerate only real WebI documents
function Get-AllWebiDocs {
    $docs   = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    $limit  = 50
    $amp    = [char]38

    do {
        $url  = $RAYLIGHT + "/documents?limit=" + $limit + $amp + "offset=" + $offset
        $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession

        # Handle response shape: {documents:{document:[...]}} or {document:[...]}
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
        $url  = $RAYLIGHT + "/documents/" + $docId + "/dataProviders"
        $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession

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
Write-Host (" Source UNV CUID : " + $SOURCE_UNV_CUID)
Write-Host (" Target UNX CUID : " + $TARGET_UNX_CUID)
Write-Host $SEP -ForegroundColor Cyan
Write-Host ""

Invoke-BOLogon

try {
    $docs = Get-AllWebiDocs
    Write-Host ("[" + (Get-Timestamp) + "] Found " + $docs.Count + " WebI documents via Raylight.")
    Write-Host ""

    $success       = 0
    $skippedNoMatch = 0
    $failed        = 0

    foreach ($doc in $docs) {
        $docId   = $doc.id
        $docName = if ($doc.name) { $doc.name } elseif ($doc.title) { $doc.title } else { "ID:" + $docId }

        $dps = Get-DataProviders $docId
        if ($null -eq $dps)   { $failed++;         continue }
        if ($dps.Count -eq 0) { $skippedNoMatch++; continue }

        # Show DP CUIDs to help verify source CUID
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
            $dpId = $dp.id
            $status = Set-DataProvider $docId $dpId
            if ($status -in @(200, 204)) {
                Write-Host ("  [OK] DP " + $dpId + " repointed.") -ForegroundColor Green
            } else {
                Write-Host ("  [FAIL] DP " + $dpId + " HTTP " + $status) -ForegroundColor Red
                $allOk = $false
            }
        }

        if ($allOk) {
            $status = Save-BODocument $docId
            if ($status -in @(200, 204)) {
                Write-Host "  [OK] Saved." -ForegroundColor Green
                $success++
            } else {
                Write-Host ("  [FAIL] Save HTTP " + $status) -ForegroundColor Red
                $failed++
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