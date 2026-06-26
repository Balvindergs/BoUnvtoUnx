# ==============================================================
#  CONFIGURATION - update these values before running
# ==============================================================
$BO_SERVER     = "your_bo_server"
$BO_PORT       = 6405
$USERNAME      = "administrator"
$PASSWORD      = "your_password"
$AUTH_TYPE     = "secEnterprise"
$UNIVERSE_NAME = "YOUR_UNIVERSE_NAME.unv"   # e.g. "Sales.unv" or just "Sales"
# ==============================================================

$REST_BASE = "http://"  + $BO_SERVER + ":" + $BO_PORT + "/biprws"
$RAYLIGHT  = $REST_BASE + "/raylight/v1"
$INFOSTORE = "https://" + $BO_SERVER + "/biprws/infostore"
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

$script:JsonHeaders = @{ "Content-Type" = "application/xml"; "Accept" = "application/json" }
$script:XmlHeaders  = @{ "Content-Type" = "application/xml"; "Accept" = "application/xml" }
$script:WebSession  = $null

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
    Write-Host "Logged in as $USERNAME" -ForegroundColor Green
}

function Invoke-BOLogoff {
    try {
        Invoke-RestMethod -Uri ($REST_BASE + "/logoff") -Method POST `
            -Headers $script:JsonHeaders -WebSession $script:WebSession | Out-Null
        Write-Host "Logged off." -ForegroundColor Gray
    } catch { }
}

# Resolve universe SI_ID using three strategies:
#   1. SL /universes endpoint  (UNX and UNV)
#   2. CI_APPOBJECTS SI_KIND='Universe'  (classic UNV)
#   3. CI_INFOOBJECTS SI_KIND='Universe' (some BO configurations)
function Resolve-UniverseSIID($name) {
    $amp      = [char]38
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($name)

    # Strategy 1: SL universes endpoint
    try {
        $page = 1
        do {
            $url  = $SL + "/universes?page=" + $page + $amp + "pageSize=100"
            $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $script:JsonHeaders -WebSession $script:WebSession
            $list = $null
            if ($resp.universes -and $resp.universes.universe) { $list = @($resp.universes.universe) }
            elseif ($resp.universe) { $list = @($resp.universe) }
            if ($list) {
                $m = $list | Where-Object {
                    $_.name -eq $name -or $_.name -eq $baseName -or
                    $_.fileName -eq $name -or $_.fileName -eq $baseName
                } | Select-Object -First 1
                if ($m -and $m.id) {
                    Write-Host ("  [SL] Found '$($m.name)'  SI_ID=" + $m.id) -ForegroundColor Gray
                    return [string]$m.id
                }
            }
            $page++
        } while ($list -and $list.Count -eq 100)
    } catch {
        Write-Host ("  [SL lookup skipped] " + $_.Exception.Message) -ForegroundColor DarkGray
    }

    # Strategy 2 & 3: CMS query against CI_APPOBJECTS then CI_INFOOBJECTS
    foreach ($table in @("CI_APPOBJECTS", "CI_INFOOBJECTS")) {
        try {
            $query    = "SELECT SI_ID,SI_NAME FROM $table WHERE SI_KIND='Universe'"
            $encodedQ = [Uri]::EscapeDataString($query)
            $offset   = 0; $limit = 50
            do {
                $url     = $INFOSTORE + "?query=" + $encodedQ + $amp + "offset=" + $offset + $amp + "limit=" + $limit
                $resp    = Invoke-RestMethod -Uri $url -Method GET -Headers $script:JsonHeaders -WebSession $script:WebSession
                $entries = if ($resp.entries) { @($resp.entries) } elseif ($resp.entry) { @($resp.entry) } else { $null }
                if ($entries) {
                    $m = $entries | Where-Object {
                        $n = if ($_.name) { $_.name } elseif ($_.title) { $_.title } else { "" }
                        $n -eq $name -or $n -eq $baseName -or $n -like ($baseName + ".*")
                    } | Select-Object -First 1
                    if ($m -and $m.id) {
                        Write-Host ("  [$table] Found '$($m.name)'  SI_ID=" + $m.id) -ForegroundColor Gray
                        return [string]$m.id
                    }
                }
                $offset += $limit
            } while ($entries -and $entries.Count -eq $limit)
        } catch {
            Write-Host ("  [$table lookup skipped] " + $_.Exception.Message) -ForegroundColor DarkGray
        }
    }

    return $null
}

# Get all base WebI reports from CMS
function Get-AllWebiDocs {
    $docs   = [System.Collections.Generic.List[object]]::new()
    $offset = 0; $limit = 50; $amp = [char]38
    $query  = "SELECT SI_ID,SI_NAME,SI_OWNER FROM CI_INFOOBJECTS WHERE SI_PROGID='CrystalEnterprise.WebiReport' AND SI_INSTANCE=0 AND SI_RECURRING=0"
    do {
        $encodedQ = [Uri]::EscapeDataString($query)
        $url      = $INFOSTORE + "?query=" + $encodedQ + $amp + "offset=" + $offset + $amp + "limit=" + $limit
        $resp     = Invoke-RestMethod -Uri $url -Method GET -Headers $script:JsonHeaders -WebSession $script:WebSession
        $entries  = $resp.entries
        if ($null -eq $entries) { $entries = $resp.entry }
        if ($entries) { $docs.AddRange([object[]](@($entries))) }
        $offset += $limit
    } while ($entries -and (@($entries)).Count -eq $limit)
    return $docs
}

function Open-BODocument($docId) {
    try {
        Invoke-RestMethod -Uri ($RAYLIGHT + "/documents/" + $docId) -Method GET `
            -Headers $script:XmlHeaders -WebSession $script:WebSession | Out-Null
        return $true
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 404) { return "skip" }
        return $false
    }
}

function Close-BODocument($docId) {
    try {
        Invoke-RestMethod -Uri ($RAYLIGHT + "/documents/" + $docId) -Method DELETE `
            -Headers $script:XmlHeaders -WebSession $script:WebSession | Out-Null
    } catch { }
}

function Get-DataProviderIDs($docId) {
    try {
        $resp = Invoke-RestMethod -Uri ($RAYLIGHT + "/documents/" + $docId + "/dataproviders") `
            -Method GET -Headers $script:XmlHeaders -WebSession $script:WebSession
        $dps = $null
        if ($resp.dataproviders -and $resp.dataproviders.dataprovider) { $dps = @($resp.dataproviders.dataprovider) }
        elseif ($resp.dataprovider) { $dps = @($resp.dataprovider) }
        if ($dps) { return @($dps | ForEach-Object { $_.id }) }
        return @()
    } catch { return @() }
}

# Check if a data provider's datasource matches the target universe (by SI_ID or name)
function Test-DPUsesUniverse($docId, $dpId, $univId, $univName) {
    try {
        $resp = Invoke-RestMethod -Uri ($RAYLIGHT + "/documents/" + $docId + "/dataproviders/" + $dpId) `
            -Method GET -Headers $script:XmlHeaders -WebSession $script:WebSession
        $ds = $null
        if ($resp.dataprovider -and $resp.dataprovider.datasource) { $ds = $resp.dataprovider.datasource }
        elseif ($resp.datasource) { $ds = $resp.datasource }
        if (-not $ds) { return $false }

        $dsId   = if ($ds.id)   { [string]$ds.id }   else { "" }
        $dsName = if ($ds.name) { [string]$ds.name }  else { "" }
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($univName)

        return ($univId -and $dsId -eq $univId) -or
               ($dsName -eq $univName) -or
               ($dsName -eq $baseName) -or
               ($dsName -like "*$baseName*")
    } catch { return $false }
}

# --- MAIN ---
Write-Host ""
Write-Host $SEP -ForegroundColor Cyan
Write-Host "  Get Reports Linked to Universe: $UNIVERSE_NAME" -ForegroundColor Cyan
Write-Host $SEP -ForegroundColor Cyan
Write-Host ""

Invoke-BOLogon

try {
    # Step 1: Resolve universe SI_ID (tries SL, CI_APPOBJECTS, CI_INFOOBJECTS)
    Write-Host "Resolving universe '$UNIVERSE_NAME' ..." -ForegroundColor Gray
    $univId = Resolve-UniverseSIID $UNIVERSE_NAME
    if ($univId) {
        Write-Host ("  Universe SI_ID resolved: " + $univId) -ForegroundColor Green
    } else {
        Write-Host ("  WARNING: Universe not found via any lookup strategy.") -ForegroundColor Yellow
        Write-Host ("  Falling back to name-only matching against data provider datasource names.") -ForegroundColor Yellow
        Write-Host ("  Tip: Check that UNIVERSE_NAME exactly matches the name in BO (with or without .unv).") -ForegroundColor Yellow
    }
    Write-Host ""

    # Step 2: Fetch all WebI reports
    Write-Host "Fetching all base WebI reports ..." -ForegroundColor Gray
    $docs = Get-AllWebiDocs
    Write-Host ("  Total WebI reports: " + $docs.Count) -ForegroundColor Gray
    Write-Host ""

    # Step 3: Open each report via Raylight and inspect data providers
    $linked  = [System.Collections.Generic.List[object]]::new()
    $counter = 0

    foreach ($doc in $docs) {
        $counter++
        $docId    = $doc.id
        $docName  = if ($doc.name)  { $doc.name }  elseif ($doc.title)    { $doc.title }    else { "ID:$docId" }
        $docOwner = if ($doc.owner) { $doc.owner } elseif ($doc.SI_OWNER) { $doc.SI_OWNER } else { "-" }

        Write-Host ("  [$counter/$($docs.Count)] $docName") -ForegroundColor DarkGray

        $opened = Open-BODocument $docId
        if ($opened -eq "skip") { continue }
        if ($opened -eq $false) { continue }

        $dpIds    = Get-DataProviderIDs $docId
        $isLinked = $false
        foreach ($dpId in $dpIds) {
            if (Test-DPUsesUniverse $docId $dpId $univId $UNIVERSE_NAME) {
                $isLinked = $true
                break
            }
        }

        Close-BODocument $docId

        if ($isLinked) {
            $linked.Add([PSCustomObject]@{ ID = $docId; Name = $docName; Owner = $docOwner })
            Write-Host ("    --> LINKED") -ForegroundColor Green
        }
    }

    # Output results
    Write-Host ""
    Write-Host $SEP -ForegroundColor Cyan
    Write-Host ("  Reports linked to '$UNIVERSE_NAME': " + $linked.Count) -ForegroundColor Yellow
    Write-Host $SEP -ForegroundColor Cyan
    if ($linked.Count -gt 0) {
        $linked | ForEach-Object {
            Write-Host ("  ID: {0,-10} Owner: {1,-20} Name: {2}" -f $_.ID, $_.Owner, $_.Name)
        }
        Write-Host $SEP -ForegroundColor Cyan
    }

} finally {
    Invoke-BOLogoff
}