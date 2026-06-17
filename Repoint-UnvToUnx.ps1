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
    if (-not $token) { throw "Logon failed - no token returned. Check server/credentials." }

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
    # SI_KIND='Webi' is the correct filter for WebI documents via REST API
    $query  = "SELECT SI_ID,SI_NAME,SI_CUID FROM CI_INFOOBJECTS WHERE SI_KIND='Webi' AND SI_INSTANCE=0"

    do {
        $encodedQuery = [Uri]::EscapeUriString($query)
        $url = $INFOSTORE + "?query=" + $encodedQuery + $amp + "offset=" + $offset + $amp + "limit=" + $limit

        $resp    = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
        $entries = $resp.entries
        if ($null -eq $entries) { $entries = $resp.entry }

        if ($entries) {
            $arr = @($entries)
            # Keep only Webi objects in case other types slip through
            $webi = $arr | Where-Object { -not $_.type -or $_.type -eq "Webi" -or $_.type -eq "Document" }
            if ($webi) { $docs.AddRange([object[]](@($webi))) }
        }
        $offset += $limit
    } while ($entries -and (@($entries)).Count -eq $limit)

    return $docs
}

# Open a document in the Raylight engine (required before accessing data providers)
function Open-BODocument($docId) {
    try {
        $url  = $RAYLIGHT + "/documents/" + $docId
        Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession | Out-Null
        return $true
    } catch {
        Write-Host ("         [Open Error] HTTP " + $_.Exception.Response.StatusCode.value__ + " - " + $_.Exception.Message) -ForegroundColor DarkYellow
        return $false
    }
}

# Release the document from Raylight server memory
function Close-BODocument($docId) {
    try {
        $url = $RAYLIGHT + "/documents/" + $docId
        Invoke-RestMethod -Uri $url -Method DELETE -Headers $script:AuthHeaders -WebSession $script:WebSession | Out-Null
    } catch { }
}

function Get-DataProviders($docId) {
    try {
        $url  = $RAYLIGHT + "/documents/" + $docId + "/dataProviders"
        $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
        if ($resp.dataProviders) { return @($resp.dataProviders) }
        if ($resp.dataProvider)  { return @($resp.dataProvider) }
        return @()
    } catch {
        Write-Host ("         [DP Error] " + $_.Exception.Message) -ForegroundColor DarkRed
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
        Write-Host ("         [PUT Error] " + $_.Exception.Message) -ForegroundColor DarkRed
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
        Write-Host ("         [Save Error] " + $_.Exception.Message) -ForegroundColor DarkRed
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
    Write-Host ("[" + (Get-Timestamp) + "] Found " + $docs.Count + " WebI reports to process.")
    Write-Host ""

    $success = 0
    $skipped = 0
    $failed  = 0

    foreach ($doc in $docs) {
        $docId   = $doc.id
        $docName = if ($doc.name) { $doc.name } elseif ($doc.title) { $doc.title } else { "ID:" + $docId }

        Write-Host ("[" + (Get-Timestamp) + "] Checking: " + $docName + " (ID:" + $docId + ")")

        # Step 1: Open document in Raylight
        $opened = Open-BODocument $docId
        if (-not $opened) {
            Write-Host ("  [WARN] Could not open document.") -ForegroundColor Yellow
            $failed++
            continue
        }

        try {
            # Step 2: Get data providers
            $dps = Get-DataProviders $docId

            if ($null -eq $dps) {
                $failed++
                continue
            }

            if ($dps.Count -eq 0) {
                Write-Host "  [SKIP] No data providers." -ForegroundColor Gray
                $skipped++
                continue
            }

            # Find DPs using the source UNV CUID
            $matched = @($dps | Where-Object {
                ($_.universe -and $_.universe.cuid -eq $SOURCE_UNV_CUID) -or
                ($_.dataSource -and $_.dataSource.cuid -eq $SOURCE_UNV_CUID) -or
                ($_.cuid -eq $SOURCE_UNV_CUID)
            })

            if ($matched.Count -eq 0) {
                Write-Host "  [SKIP] No matching UNV data provider." -ForegroundColor Gray
                $skipped++
                continue
            }

            Write-Host ("  [MATCH] " + $matched.Count + " data provider(s) use source UNV.") -ForegroundColor Yellow

            if ($DRY_RUN) {
                Write-Host "  [DRY RUN] Would repoint - skipping actual change." -ForegroundColor Gray
                $success++
                continue
            }

            # Step 3: Repoint each matching DP
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

            # Step 4: Save
            if ($allOk) {
                $status = Save-BODocument $docId
                if ($status -in @(200, 204)) {
                    Write-Host "  [OK] Document saved." -ForegroundColor Green
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
    Write-Host (" DONE - Repointed: " + $success + " | Skipped: " + $skipped + " | Failed: " + $failed) -ForegroundColor Cyan
    Write-Host $SEP -ForegroundColor Cyan

} finally {
    Invoke-BOLogoff
}