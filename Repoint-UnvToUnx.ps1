# ==============================================================
#  CONFIGURATION - update these values before running
# ==============================================================
$BO_SERVER       = "your_bo_server"
$BO_PORT         = 6405
$USERNAME        = "administrator"
$PASSWORD        = "your_password"
$AUTH_TYPE       = "secEnterprise"

$SOURCE_UNV_NAME = "MyUniverse.unv"   # display / PARENTS() filter only
$TARGET_UNX_NAME = "MyUniverse.unx"
$TARGET_UNX_ID   = ""                 # SI_ID of the target UNX (resolved from name if blank)

$DRY_RUN = $true   # Set to $false to actually save changes
# ==============================================================

# Raylight uses the SAME http://host:port base as logon (not HTTPS)
$REST_BASE = "http://" + $BO_SERVER + ":" + $BO_PORT + "/biprws"
$RAYLIGHT  = $REST_BASE + "/raylight/v1"
$INFOSTORE = $REST_BASE + "/infostore"
$SL        = $REST_BASE + "/sl/v1"
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

# InfoStore uses JSON; Raylight uses XML
$script:JsonHeaders = @{ "Content-Type" = "application/xml"; "Accept" = "application/json" }
$script:XmlHeaders  = @{ "Content-Type" = "application/xml"; "Accept" = "application/xml" }
$script:WebSession  = $null

function Get-Timestamp { Get-Date -Format "HH:mm:ss" }

function Invoke-BOLogon {
    $xmlBody = "<attrs>" +
        "<attr name=`"userName`" type=`"string`">" + $USERNAME + "</attr>" +
        "<attr name=`"password`" type=`"string`">" + $PASSWORD + "</attr>" +
        "<attr name=`"auth`" type=`"string`">"  + $AUTH_TYPE  + "</attr>" +
        "</attrs>"

    $resp = Invoke-RestMethod -Uri ($REST_BASE + "/logon/long") -Method POST `
        -Body $xmlBody -Headers $script:JsonHeaders -SessionVariable "script:WebSession"

    $token = $resp.logonToken
    if (-not $token) {
        $token = $resp.attrs.attr |
            Where-Object { $_.name -eq "logonToken" } |
            Select-Object -ExpandProperty "#text"
    }
    if (-not $token) { throw "Logon failed - no token returned." }

    $script:JsonHeaders = @{
        "X-SAP-LogonToken" = ('"' + $token + '"')
        "Accept"           = "application/json"
        "Content-Type"     = "application/json"
    }
    $script:XmlHeaders = @{
        "X-SAP-LogonToken" = ('"' + $token + '"')
        "Accept"           = "application/xml"
        "Content-Type"     = "application/xml"
    }
    Write-Host ("[" + (Get-Timestamp) + "] Logged in as " + $USERNAME) -ForegroundColor Green
}

function Invoke-BOLogoff {
    try {
        Invoke-RestMethod -Uri ($REST_BASE + "/logoff") -Method POST `
            -Headers $script:JsonHeaders -WebSession $script:WebSession | Out-Null
        Write-Host ("[" + (Get-Timestamp) + "] Logged off.") -ForegroundColor Gray
    } catch { }
}

# Resolve the SI_ID (not CUID) of a universe by name - needed for targetDatasourceId in mappings
function Resolve-UniverseSIID($name) {
    $amp      = [char]38
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($name)

    # Try sl/v1/universes first (UNX)
    try {
        $page = 1
        do {
            $url  = $SL + "/universes?page=" + $page + $amp + "pageSize=100"
            $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:JsonHeaders -WebSession $script:WebSession
            $list = $null
            if ($resp.universes -and $resp.universes.universe) { $list = @($resp.universes.universe) }
            elseif ($resp.universe) { $list = @($resp.universe) }
            if ($list) {
                $m = $list | Where-Object { $_.name -eq $name -or $_.fileName -eq $name } | Select-Object -First 1
                if ($m -and $m.id) { return $m.id }
            }
            $page++
        } while ($list -and $list.Count -eq 100)
    } catch {
        Write-Host ("  [SL Lookup Error] " + $_.Exception.Message) -ForegroundColor Red
    }

    # Fallback: CI_APPOBJECTS (UNV)
    try {
        $query        = "SELECT SI_ID,SI_NAME FROM CI_APPOBJECTS WHERE SI_KIND='Universe'"
        $encodedQuery = [Uri]::EscapeDataString($query)
        $offset       = 0; $limit = 50
        do {
            $url     = $INFOSTORE + "?query=" + $encodedQuery + $amp + "offset=" + $offset + $amp + "limit=" + $limit
            $resp    = Invoke-RestMethod -Uri $url -Method GET -Headers $script:JsonHeaders -WebSession $script:WebSession
            $entries = if ($resp.entries) { @($resp.entries) } elseif ($resp.entry) { @($resp.entry) } else { $null }
            if ($entries) {
                $m = $entries | Where-Object {
                    $n = if ($_.name) { $_.name } elseif ($_.title) { $_.title } else { "" }
                    $n -eq $name -or $n -eq $baseName -or $n -like ($baseName + ".*")
                } | Select-Object -First 1
                if ($m -and $m.id) { return $m.id }
            }
            $offset += $limit
        } while ($entries -and $entries.Count -eq $limit)
    } catch {
        Write-Host ("  [CMS Lookup Error] " + $_.Exception.Message) -ForegroundColor Red
    }

    return $null
}

# Get all base WebI reports. Universe filtering is handled naturally by the mappings endpoint:
# GET /dataproviders/mappings only succeeds for DPs compatible with the target UNX.
function Get-AllWebiDocs {
    $docs   = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    $limit  = 50
    $amp    = [char]38
    $query  = "SELECT SI_ID,SI_NAME FROM CI_INFOOBJECTS WHERE SI_PROGID='CrystalEnterprise.WebiReport' AND SI_INSTANCE=0 AND SI_RECURRING=0"

    do {
        $encodedQuery = [Uri]::EscapeDataString($query)
        $url     = $INFOSTORE + "?query=" + $encodedQuery + $amp + "offset=" + $offset + $amp + "limit=" + $limit
        $resp    = Invoke-RestMethod -Uri $url -Method GET -Headers $script:JsonHeaders -WebSession $script:WebSession
        $entries = $resp.entries
        if ($null -eq $entries) { $entries = $resp.entry }
        if ($entries) { $docs.AddRange([object[]](@($entries))) }
        $offset += $limit
    } while ($entries -and (@($entries)).Count -eq $limit)

    return $docs
}

# Open a document in the Raylight session (required before accessing dataproviders)
function Open-BODocument($docId) {
    try {
        Invoke-RestMethod -Uri ($RAYLIGHT + "/documents/" + $docId) -Method GET `
            -Headers $script:XmlHeaders -WebSession $script:WebSession | Out-Null
        return $true
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 404) { return "skip" }
        Write-Host ("  [Open Error] HTTP $code - " + $_.Exception.Message) -ForegroundColor DarkRed
        return $false
    }
}

# Get all data provider IDs for a document
function Get-DataProviderIDs($docId) {
    try {
        $resp = Invoke-RestMethod -Uri ($RAYLIGHT + "/documents/" + $docId + "/dataproviders") `
            -Method GET -Headers $script:XmlHeaders -WebSession $script:WebSession
        $dps = $null
        if ($resp.dataproviders -and $resp.dataproviders.dataprovider) { $dps = @($resp.dataproviders.dataprovider) }
        elseif ($resp.dataprovider) { $dps = @($resp.dataprovider) }
        if ($dps) { return @($dps | ForEach-Object { $_.id }) }
        return @()
    } catch {
        Write-Host ("  [DP Error] " + $_.Exception.Message) -ForegroundColor DarkRed
        return $null
    }
}

# GET the field mappings between a DP's current universe and the new UNX
function Get-DPMappings($docId, $dpId, $targetId) {
    $amp = [char]38
    $url = $RAYLIGHT + "/documents/" + $docId + "/dataproviders/mappings?originDataproviderIds=" + $dpId + $amp + "targetDatasourceId=" + $targetId
    try {
        # Return raw XML string so it can be POSTed back unchanged
        $resp = Invoke-WebRequest -Uri $url -Method GET -Headers $script:XmlHeaders `
            -WebSession $script:WebSession -UseBasicParsing
        return $resp.Content
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Host ("  [Mapping GET Error] DP $dpId HTTP $code - " + $_.Exception.Message) -ForegroundColor DarkYellow
        return $null
    }
}

# POST the mappings back to apply the datasource change for a DP
function Apply-DPMappings($docId, $dpId, $targetId, $mappingXml) {
    $amp = [char]38
    $url = $RAYLIGHT + "/documents/" + $docId + "/dataproviders/mappings?originDataproviderIds=" + $dpId + $amp + "targetDatasourceId=" + $targetId
    try {
        $resp = Invoke-WebRequest -Uri $url -Method POST -Body $mappingXml `
            -Headers $script:XmlHeaders -WebSession $script:WebSession -UseBasicParsing
        return $resp.StatusCode
    } catch {
        Write-Host ("  [Mapping POST Error] DP $dpId HTTP " + $_.Exception.Response.StatusCode.value__ + " - " + $_.Exception.Message) -ForegroundColor DarkRed
        return $_.Exception.Response.StatusCode.value__
    }
}

function Save-BODocument($docId) {
    try {
        $resp = Invoke-WebRequest -Uri ($RAYLIGHT + "/documents/" + $docId) -Method PUT `
            -Headers $script:XmlHeaders -WebSession $script:WebSession -UseBasicParsing
        return $resp.StatusCode
    } catch {
        Write-Host ("  [Save Error] HTTP " + $_.Exception.Response.StatusCode.value__ + " - " + $_.Exception.Message) -ForegroundColor DarkRed
        return $_.Exception.Response.StatusCode.value__
    }
}

function Close-BODocument($docId) {
    try {
        Invoke-RestMethod -Uri ($RAYLIGHT + "/documents/" + $docId) -Method DELETE `
            -Headers $script:XmlHeaders -WebSession $script:WebSession | Out-Null
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
    # Resolve target UNX SI_ID
    if (-not $TARGET_UNX_ID -and $TARGET_UNX_NAME) {
        Write-Host ("Resolving target UNX SI_ID: " + $TARGET_UNX_NAME) -ForegroundColor Gray
        $TARGET_UNX_ID = Resolve-UniverseSIID $TARGET_UNX_NAME
        if ($TARGET_UNX_ID) {
            Write-Host ("  SI_ID: " + $TARGET_UNX_ID) -ForegroundColor Gray
        } else {
            throw "Target UNX '$TARGET_UNX_NAME' not found. Set TARGET_UNX_ID directly in config."
        }
    }
    if (-not $TARGET_UNX_ID) { throw "TARGET_UNX_ID is empty - set name or ID in config." }

    Write-Host ""
    Write-Host (" Source UNV : " + $SOURCE_UNV_NAME)
    Write-Host (" Target UNX : " + $TARGET_UNX_NAME + "  [SI_ID=" + $TARGET_UNX_ID + "]")
    Write-Host ""

    $docs = Get-AllWebiDocs
    Write-Host ("[" + (Get-Timestamp) + "] Found " + $docs.Count + " base WebI report(s). Reports not using the source UNV will be skipped automatically by the mappings endpoint.")
    Write-Host ""

    $success = 0
    $failed  = 0

    foreach ($doc in $docs) {
        $docId   = $doc.id
        $docName = if ($doc.name)     { $doc.name }
                   elseif ($doc.title)    { $doc.title }
                   elseif ($doc.SI_NAME)  { $doc.SI_NAME }
                   else { "ID:" + $docId }

        Write-Host ("[" + (Get-Timestamp) + "] Processing: " + $docName + " (ID:" + $docId + ")") -ForegroundColor Yellow

        # Open document in Raylight session
        $opened = Open-BODocument $docId
        if ($opened -eq "skip") { Write-Host "  [SKIP] Not found." -ForegroundColor DarkYellow; continue }
        if ($opened -eq $false) { $failed++; continue }

        # Get data provider IDs
        $dpIds = Get-DataProviderIDs $docId
        if ($null -eq $dpIds) { $failed++; Close-BODocument $docId; continue }
        if ($dpIds.Count -eq 0) {
            Write-Host "  [SKIP] No data providers found." -ForegroundColor DarkYellow
            Close-BODocument $docId; continue
        }
        Write-Host ("  Data providers: " + ($dpIds -join ", ")) -ForegroundColor Gray

        if ($DRY_RUN) {
            Write-Host ("  [DRY RUN] Would remap " + $dpIds.Count + " DP(s) to: " + $TARGET_UNX_NAME) -ForegroundColor Gray
            $success++
            Close-BODocument $docId
            continue
        }

        # For each DP: GET mappings then POST mappings to apply the datasource change.
        # Mapping errors mean the DP uses a different universe - those DPs are skipped silently.
        $remappedCount = 0
        $remapFailed   = $false
        foreach ($dpId in $dpIds) {
            $mappingXml = Get-DPMappings $docId $dpId $TARGET_UNX_ID
            if (-not $mappingXml) { continue }   # different universe - skip this DP
            $applyStatus = Apply-DPMappings $docId $dpId $TARGET_UNX_ID $mappingXml
            if ($applyStatus -in @(200, 201, 204)) {
                Write-Host ("  [OK] DP $dpId remapped.") -ForegroundColor Green
                $remappedCount++
            } else {
                Write-Host ("  [FAIL] DP $dpId remap HTTP $applyStatus") -ForegroundColor Red
                $remapFailed = $true
            }
        }

        if ($remappedCount -eq 0) {
            Write-Host "  [SKIP] No DPs use the source UNV - not a match." -ForegroundColor DarkGray
            Close-BODocument $docId; continue
        }

        if (-not $remapFailed) {
            $saveStatus = Save-BODocument $docId
            if ($saveStatus -in @(200, 201, 204)) {
                Write-Host "  [OK] Saved." -ForegroundColor Green
                $success++
            } else {
                Write-Host ("  [FAIL] Save HTTP $saveStatus") -ForegroundColor Red
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