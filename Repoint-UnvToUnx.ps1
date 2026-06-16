# ==============================================================
#  CONFIGURATION - update these values before running
# ==============================================================
$BO_SERVER       = "your_bo_server"
$BO_PORT         = 6405
$USERNAME        = "administrator"
$PASSWORD        = "your_password"
$AUTH_TYPE       = "secEnterprise"

$SOURCE_UNV_CUID = "AUBFikpv32Nv_c"
$TARGET_UNX_CUID = "CX2pwjuQLcwIs_6XI"
$TARGET_UNX_NAME = "Jcxh.unx"

$DRY_RUN = $true   # Set to $false to actually save changes
# ==============================================================

$BASE_URL  = "http://" + $BO_SERVER + ":" + $BO_PORT + "/biprws"
$RAYLIGHT  = $BASE_URL + "/raylight/v1"
$INFOSTORE = $BASE_URL + "/infostore"
$SEP       = "=" * 60

[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
    param($sender, $cert, $chain, $errors)
    return $true
}

$script:AuthHeaders = @{
    "Content-Type" = "application/xml"
    "Accept"       = "application/json"
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
        -Uri ($BASE_URL + "/logon/long") `
        -Method POST `
        -Body $xmlBody `
        -Headers $script:AuthHeaders `
        -SessionVariable "script:WebSession"

    $token = $resp.logonToken
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
        Invoke-RestMethod `
            -Uri ($BASE_URL + "/logoff") `
            -Method POST `
            -Headers $script:AuthHeaders `
            -WebSession $script:WebSession | Out-Null
        Write-Host ("[" + (Get-Timestamp) + "] Logged off.") -ForegroundColor Gray
    } catch { }
}

function Get-AllWebiDocs {
    $docs   = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    $limit  = 50
    $amp    = [char]38
    $query  = "SELECT SI_ID,SI_NAME FROM CI_INFOOBJECTS WHERE SI_PROGID='CrystalEnterprise.WebiReport' AND SI_INSTANCE=0"

    do {
        $encodedQuery = [Uri]::EscapeUriString($query)
        $url = $INFOSTORE + "?query=" + $encodedQuery + $amp + "offset=" + $offset + $amp + "limit=" + $limit

        $resp    = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
        $entries = $resp.entries

        if ($entries) { $docs.AddRange([object[]]$entries) }
        $offset += $limit
    } while ($entries -and $entries.Count -eq $limit)

    return $docs
}

function Get-DataProviders($docId) {
    try {
        $url  = $RAYLIGHT + "/documents/" + $docId + "/dataProviders"
        $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
        return $resp.dataProviders
    } catch {
        return $null
    }
}

function Set-DataProvider($docId, $dpId) {
    $url     = $RAYLIGHT + "/documents/" + $docId + "/dataProviders/" + $dpId
    $payload = '{"dataProvider":{"universe":{"cuid":"' + $TARGET_UNX_CUID + '","name":"' + $TARGET_UNX_NAME + '"}}}'

    try {
        $resp = Invoke-WebRequest `
            -Uri $url `
            -Method PUT `
            -Body $payload `
            -Headers $script:AuthHeaders `
            -WebSession $script:WebSession `
            -UseBasicParsing
        return $resp.StatusCode
    } catch {
        return $_.Exception.Response.StatusCode.value__
    }
}

function Save-BODocument($docId) {
    $url = $RAYLIGHT + "/documents/" + $docId

    try {
        $resp = Invoke-WebRequest `
            -Uri $url `
            -Method PUT `
            -Headers $script:AuthHeaders `
            -WebSession $script:WebSession `
            -UseBasicParsing
        return $resp.StatusCode
    } catch {
        return $_.Exception.Response.StatusCode.value__
    }
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
    Write-Host ("[" + (Get-Timestamp) + "] Found " + $docs.Count + " WebI reports to scan.") 

    $success = 0
    $skipped = 0
    $failed  = 0

    foreach ($doc in $docs) {
        $docId   = $doc.id
        $docName = if ($doc.title) { $doc.title } elseif ($doc.SI_NAME) { $doc.SI_NAME } else { "ID:" + $docId }

        $dps = Get-DataProviders $docId

        if ($null -eq $dps) {
            Write-Host ("  [WARN] Could not open: " + $docName) -ForegroundColor Yellow
            $failed++
            continue
        }

        $matched = @($dps | Where-Object { $_.universe.cuid -eq $SOURCE_UNV_CUID })

        if ($matched.Count -eq 0) {
            $skipped++
            continue
        }

        Write-Host ("[" + (Get-Timestamp) + "] MATCH: " + $docName + " (ID:" + $docId + ") - " + $matched.Count + " DP(s)") -ForegroundColor Yellow

        if ($DRY_RUN) {
            Write-Host ("         [DRY RUN] Would repoint " + $matched.Count + " data provider(s).") -ForegroundColor Gray
            $success++
            continue
        }

        $allOk = $true
        foreach ($dp in $matched) {
            $status = Set-DataProvider $docId $dp.id
            if ($status -in @(200, 204)) {
                Write-Host ("         [OK] DP " + $dp.id + " repointed.") -ForegroundColor Green
            } else {
                Write-Host ("         [FAIL] DP " + $dp.id + " failed (HTTP " + $status + ")") -ForegroundColor Red
                $allOk = $false
            }
        }

        if ($allOk) {
            $status = Save-BODocument $docId
            if ($status -in @(200, 204)) {
                Write-Host "         [OK] Saved." -ForegroundColor Green
                $success++
            } else {
                Write-Host ("         [FAIL] Save failed (HTTP " + $status + ")") -ForegroundColor Red
                $failed++
            }
        } else {
            $failed++
        }
    }

    Write-Host ""
    Write-Host $SEP -ForegroundColor Cyan
    Write-Host (" DONE - Repointed: " + $success + " | Skipped: " + $skipped + " | Failed: " + $failed) -ForegroundColor Cyan
    Write-Host $SEP -ForegroundColor Cyan

} finally {
    Invoke-BOLogoff
}