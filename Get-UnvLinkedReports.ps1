# ==============================================================
#  CONFIGURATION
# ==============================================================
$BO_SERVER    = "your_bo_server"
$BO_PORT      = 6405
$USERNAME     = "administrator"
$PASSWORD     = "your_password"
$AUTH_TYPE    = "secEnterprise"
$UNIVERSE_ID  = "157755"   # SI_ID of the source UNV universe
# ==============================================================

$REST_BASE = "http://"  + $BO_SERVER + ":" + $BO_PORT + "/biprws"
$INFOSTORE = "https://" + $BO_SERVER + "/biprws/infostore"
$SEP       = "=" * 60

[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { param($s,$c,$ch,$e); return $true }
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11
[System.Net.ServicePointManager]::Expect100Continue = $false

$script:Headers    = @{ "Content-Type" = "application/xml"; "Accept" = "application/json" }
$script:WebSession = $null

# --- Logon ---
$xmlBody = "<attrs><attr name=`"userName`" type=`"string`">$USERNAME</attr><attr name=`"password`" type=`"string`">$PASSWORD</attr><attr name=`"auth`" type=`"string`">$AUTH_TYPE</attr></attrs>"
$resp    = Invoke-RestMethod -Uri ($REST_BASE + "/logon/long") -Method POST -Body $xmlBody -Headers $script:Headers -SessionVariable "script:WebSession"

$token = $resp.logonToken
if (-not $token) { $token = $resp.attrs.attr | Where-Object { $_.name -eq "logonToken" } | Select-Object -ExpandProperty "#text" }
if (-not $token) { throw "Logon failed." }

$script:Headers = @{ "X-SAP-LogonToken" = ('"' + $token + '"'); "Accept" = "application/json"; "Content-Type" = "application/json" }
Write-Host "Logged in." -ForegroundColor Green

try {
    $amp = [char]38

    # Step 1 — Resolve SI_CUID from SI_ID via CI_APPOBJECTS
    Write-Host "`nResolving CUID for universe SI_ID: $UNIVERSE_ID ..." -ForegroundColor Gray
    $q       = [Uri]::EscapeDataString("SELECT SI_ID,SI_NAME,SI_CUID FROM CI_APPOBJECTS WHERE SI_KIND='Universe' AND SI_ID=$UNIVERSE_ID")
    $resp    = Invoke-RestMethod -Uri ($INFOSTORE + "?query=" + $q) -Method GET -Headers $script:Headers -WebSession $script:WebSession
    $entry   = if ($resp.entries) { @($resp.entries)[0] } elseif ($resp.entry) { @($resp.entry)[0] } else { $null }

    if (-not $entry) { throw "Universe SI_ID=$UNIVERSE_ID not found in CI_APPOBJECTS. Verify the ID." }

    $universeCuid = if ($entry.cuid) { $entry.cuid } elseif ($entry.SI_CUID) { $entry.SI_CUID } else { $null }
    $universeName = if ($entry.name) { $entry.name } elseif ($entry.title) { $entry.title } else { "ID:$UNIVERSE_ID" }
    if (-not $universeCuid) { throw "Could not read SI_CUID for universe SI_ID=$UNIVERSE_ID." }

    Write-Host "  Name : $universeName" -ForegroundColor Gray
    Write-Host "  CUID : $universeCuid"  -ForegroundColor Gray

    # Step 2 — Query WebI base reports filtered by SI_UNIVERSE_CUID (BO 4.3 field)
    Write-Host "Querying WebI reports with SI_UNIVERSE_CUID='$universeCuid' ..." -ForegroundColor Gray
    $reports = [System.Collections.Generic.List[object]]::new()
    $offset  = 0
    $q2      = [Uri]::EscapeDataString("SELECT SI_ID,SI_NAME,SI_OWNER,SI_PATH FROM CI_INFOOBJECTS WHERE SI_PROGID='CrystalEnterprise.WebiReport' AND SI_UNIVERSE_CUID='$universeCuid' AND SI_INSTANCE=0 AND SI_RECURRING=0")

    do {
        $url     = $INFOSTORE + "?query=" + $q2 + $amp + "offset=" + $offset + $amp + "limit=50"
        $resp    = Invoke-RestMethod -Uri $url -Method GET -Headers $script:Headers -WebSession $script:WebSession
        $entries = if ($resp.entries) { @($resp.entries) } elseif ($resp.entry) { @($resp.entry) } else { $null }
        if ($entries) { $reports.AddRange([object[]](@($entries))) }
        $offset += 50
    } while ($entries -and $entries.Count -eq 50)

    # Display
    Write-Host ""
    Write-Host $SEP -ForegroundColor Cyan
    Write-Host (" WebI reports linked to: $universeName  ($($reports.Count) found)") -ForegroundColor Cyan
    Write-Host (" SI_ID: $UNIVERSE_ID  |  CUID: $universeCuid") -ForegroundColor Cyan
    Write-Host $SEP -ForegroundColor Cyan

    if ($reports.Count -gt 0) {
        Write-Host ("{0,-10} {1,-22} {2}" -f "SI_ID", "Owner", "Report Name") -ForegroundColor Yellow
        Write-Host ("-" * 75) -ForegroundColor Yellow
        $reports | Sort-Object { if ($_.name) { $_.name } else { $_.title } } | ForEach-Object {
            $id    = $_.id
            $name  = if ($_.name)  { $_.name }  elseif ($_.title)   { $_.title }   else { "-" }
            $owner = if ($_.owner) { $_.owner } elseif ($_.SI_OWNER) { $_.SI_OWNER } else { "-" }
            Write-Host ("{0,-10} {1,-22} {2}" -f $id, $owner, $name)
        }
    } else {
        Write-Host "  No reports found. Verify SI_UNIVERSE_CUID is populated in your BO environment." -ForegroundColor Yellow
        Write-Host "  You can check by running in CMC QueryBuilder:" -ForegroundColor Yellow
        Write-Host "  SELECT SI_ID,SI_NAME,SI_UNIVERSE_CUID FROM CI_INFOOBJECTS WHERE SI_PROGID='CrystalEnterprise.WebiReport' AND SI_INSTANCE=0" -ForegroundColor Gray
    }

    Write-Host ""

} finally {
    try {
        Invoke-RestMethod -Uri ($REST_BASE + "/logoff") -Method POST -Headers $script:Headers -WebSession $script:WebSession | Out-Null
        Write-Host "Logged off." -ForegroundColor Gray
    } catch { }
}