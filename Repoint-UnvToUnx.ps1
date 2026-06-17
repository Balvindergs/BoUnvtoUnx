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
        -Uri ($BASE_URL + "/logon/long") `
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
        if ($null -eq $entries) { $entries = $resp.entry }

        if ($entries) { $docs.AddRange([object[]](@($entries))) }
        $offset += $limit
    } while ($entries -and (@($entries)).Count -eq $limit)

    return $docs
}

# Test that the Raylight endpoint is reachable at all
function Test-RaylightAccess {
    try {
        $resp = Invoke-RestMethod -Uri ($RAYLIGHT + "/documents") -Method GET `
            -Headers $script:AuthHeaders -WebSession $script:WebSession
        Write-Host "  [OK] Raylight /documents reachable." -ForegroundColor Green
        return $true
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Host ("  [FAIL] Raylight not reachable: HTTP " + $code + " - " + $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Open-BODocument($docId) {
    try {
        Invoke-RestMethod -Uri ($RAYLIGHT + "/documents/" + $docId) -Method GET `
            -Headers $script:AuthHeaders -WebSession $script:WebSession | Out-Null
        return "ok"
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 404) { return "skip-404" }
        return ("fail-" + $code)
    }
}

function Close-BODocument($docId) {
    try {
        Invoke-RestMethod -Uri ($RAYLIGHT + "/documents/" + $docId) -Method DELETE `
            -Headers $script:AuthHeaders -WebSession $script:WebSession | Out-Null
    } catch { }
}

function Get-DataProviders($docId) {
    try {
        $url  = $RAYLIGHT + "/documents/" + $docId + "/dataProviders"
        $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession

        # Raylight wraps DPs: {dataProviders:{dataProvider:[...]}} or {dataProvider:[...]}
        if ($resp.dataProviders -and $resp.dataProviders.dataProvider) {
            return @($resp.dataProviders.dataProvider)
        }
        if ($resp.dataProviders) { return @($resp.dataProviders) }
        if ($resp.dataProvider)  { return @($resp.dataProvider) }
        return @()
    } catch {
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
    # Verify Raylight is accessible before processing
    Write-Host "Testing Raylight connectivity..." -ForegroundColor Gray
    $rlOk = Test-RaylightAccess
    if (-not $rlOk) {
        Write-Host "Raylight is not accessible. Check that the Raylight service is enabled on the BO server." -ForegroundColor Red
        return
    }
    Write-Host ""

    $docs = Get-AllWebiDocs
    Write-Host ("[" + (Get-Timestamp) + "] Found " + $docs.Count + " candidates to scan.")
    Write-Host ""

    # Counters by reason
    $success     = 0
    $skipped404  = 0
    $skippedNoDp = 0
    $skippedNoMatch = 0
    $failed      = 0

    foreach ($doc in $docs) {
        $docId   = $doc.id
        $docName = if ($doc.name)    { $doc.name }
                   elseif ($doc.title)   { $doc.title }
                   elseif ($doc.SI_NAME) { $doc.SI_NAME }
                   else { "ID:" + $docId }

        $openResult = Open-BODocument $docId

        if ($openResult -eq "skip-404") {
            Write-Host ("  [SKIP-404]  " + $docName + " (ID:" + $docId + ") - not a Raylight document") -ForegroundColor DarkGray
            $skipped404++
            continue
        }
        if ($openResult -ne "ok") {
            Write-Host ("  [FAIL-OPEN] " + $docName + " (ID:" + $docId + ") - " + $openResult) -ForegroundColor Red
            $failed++
            continue
        }

        try {
            $dps = Get-DataProviders $docId

            if ($null -eq $dps) {
                Write-Host ("  [FAIL-DP]  " + $docName + " (ID:" + $docId + ")") -ForegroundColor Red
                $failed++
                continue
            }

            if ($dps.Count -eq 0) {
                Write-Host ("  [SKIP-NDP] " + $docName + " (ID:" + $docId + ") - no data providers") -ForegroundColor DarkGray
                $skippedNoDp++
                continue
            }

            # Show DP CUIDs found (helps verify CUID matching)
            $dpCuids = ($dps | ForEach-Object {
                $c = if ($_.dataSource) { $_.dataSource.cuid } elseif ($_.universe) { $_.universe.cuid } else { $_.cuid }
                $c
            }) -join ", "
            Write-Host ("  [DPs]      " + $docName + " (ID:" + $docId + ") CUIDs: " + $dpCuids) -ForegroundColor DarkCyan

            $matched = @($dps | Where-Object {
                ($_.universe   -and $_.universe.cuid   -eq $SOURCE_UNV_CUID) -or
                ($_.dataSource -and $_.dataSource.cuid -eq $SOURCE_UNV_CUID) -or
                ($_.cuid -eq $SOURCE_UNV_CUID)
            })

            if ($matched.Count -eq 0) {
                $skippedNoMatch++
                continue
            }

            Write-Host ("[" + (Get-Timestamp) + "] MATCH: " + $docName + " (ID:" + $docId + ") - " + $matched.Count + " DP(s)") -ForegroundColor Yellow

            if ($DRY_RUN) {
                Write-Host "  [DRY RUN] Would repoint." -ForegroundColor Gray
                $success++
                continue
            }

            $allOk = $true
            foreach ($dp in $matched) {
                $dpId = $dp.id
                if (-not $dpId -and $dp.dataProvider) { $dpId = $dp.dataProvider.id }
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
            } else {
                $failed++
            }

        } finally {
            Close-BODocument $docId
        }
    }

    Write-Host ""
    Write-Host $SEP -ForegroundColor Cyan
    Write-Host (" DONE - Repointed: " + $success + " | Skipped(404): " + $skipped404 + " | Skipped(no DP): " + $skippedNoDp + " | Skipped(no match): " + $skippedNoMatch + " | Failed: " + $failed) -ForegroundColor Cyan
    Write-Host $SEP -ForegroundColor Cyan

} finally {
    Invoke-BOLogoff
}