# ==============================================================
#  CONFIGURATION
# ==============================================================
$BO_SERVER     = "your_bo_server"
$BO_PORT       = 6405
$USERNAME      = "administrator"
$PASSWORD      = "your_password"
$AUTH_TYPE     = "secEnterprise"
$UNIVERSE_NAME = "YourUniverse.unv"   # exact CMS name
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

    # Step 1 — Find the UNV SI_ID from CI_APPOBJECTS
    Write-Host "`nResolving SI_ID for universe: $UNIVERSE_NAME" -ForegroundColor Gray
    $baseName     = [System.IO.Path]::GetFileNameWithoutExtension($UNIVERSE_NAME)
    $q            = [Uri]::EscapeDataString("SELECT SI_ID,SI_NAME,SI_CUID FROM CI_APPOBJECTS WHERE SI_KIND='Universe'")
    $universeId   = $null
    $offset       = 0

    do {
        $resp    = Invoke-RestMethod -Uri ($INFOSTORE + "?query=" + $q + $amp + "offset=" + $offset + $amp + "limit=50") -Method GET -Headers $script:Headers -WebSession $script:WebSession
        $entries = if ($resp.entries) { @($resp.entries) } elseif ($resp.entry) { @($resp.entry) } else { $null }
        if ($entries) {
            $m = $entries | Where-Object {
                $n = if ($_.name) { $_.name } elseif ($_.title) { $_.title } else { "" }
                $n -eq $UNIVERSE_NAME -or $n -eq $baseName -or $n -like ($baseName + ".*")
            } | Select-Object -First 1
            if ($m) { $universeId = $m.id }
        }
        $offset += 50
    } while (-not $universeId -and $entries -and $entries.Count -eq 50)

    if (-not $universeId) { throw "Universe '$UNIVERSE_NAME' not found in CI_APPOBJECTS. Verify the exact CMS name." }
    Write-Host "  Found SI_ID: $universeId" -ForegroundColor Gray

    # Step 2 — Fetch dependent objects via /infostore/{id}/dependents
    Write-Host "Fetching dependent reports..." -ForegroundColor Gray
    $allDeps = [System.Collections.Generic.List[object]]::new()
    $offset  = 0

    do {
        $url     = $INFOSTORE + "/" + $universeId + "/dependents?" + "offset=" + $offset + $amp + "limit=50"
        $resp    = Invoke-RestMethod -Uri $url -Method GET -Headers $script:Headers -WebSession $script:WebSession
        $entries = if ($resp.entries) { @($resp.entries) } elseif ($resp.entry) { @($resp.entry) } else { $null }
        if ($entries) { $allDeps.AddRange([object[]](@($entries))) }
        $offset += 50
    } while ($entries -and $entries.Count -eq 50)

    # Step 3 — Filter to WebI reports only (SI_KIND = Webi, exclude instances)
    $reports = @($allDeps | Where-Object {
        $kind = if ($_.kind) { $_.kind } elseif ($_.SI_KIND) { $_.SI_KIND } else { "" }
        $kind -match "(?i)webi"
    })

    # Display
    Write-Host ""
    Write-Host $SEP -ForegroundColor Cyan
    Write-Host (" WebI reports linked to: $UNIVERSE_NAME  ($($reports.Count) found)") -ForegroundColor Cyan
    Write-Host $SEP -ForegroundColor Cyan
    Write-Host ("{0,-10} {1,-20} {2}" -f "SI_ID", "Owner", "Report Name") -ForegroundColor Yellow
    Write-Host ("-" * 70) -ForegroundColor Yellow

    $reports | Sort-Object { if ($_.name) { $_.name } else { $_.title } } | ForEach-Object {
        $id    = $_.id
        $name  = if ($_.name)  { $_.name }  elseif ($_.title)   { $_.title }   else { "-" }
        $owner = if ($_.owner) { $_.owner } elseif ($_.SI_OWNER) { $_.SI_OWNER } else { "-" }
        Write-Host ("{0,-10} {1,-20} {2}" -f $id, $owner, $name)
    }

    Write-Host ""

} finally {
    try {
        Invoke-RestMethod -Uri ($REST_BASE + "/logoff") -Method POST -Headers $script:Headers -WebSession $script:WebSession | Out-Null
        Write-Host "Logged off." -ForegroundColor Gray
    } catch { }
}