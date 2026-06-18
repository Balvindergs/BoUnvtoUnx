# ==============================================================
#  CONFIGURATION
# ==============================================================
$BO_SERVER    = "your_bo_server"
$BO_PORT      = 6405
$USERNAME     = "administrator"
$PASSWORD     = "your_password"
$AUTH_TYPE    = "secEnterprise"
$UNIVERSE_ID  = "12345"   # SI_ID of the source UNV universe
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

    # Step 1 — Fetch all dependent objects via /infostore/{SI_ID}/dependents
    Write-Host "`nFetching dependents for universe SI_ID: $UNIVERSE_ID" -ForegroundColor Gray
    $allDeps = [System.Collections.Generic.List[object]]::new()
    $offset  = 0

    do {
        $url     = $INFOSTORE + "/" + $UNIVERSE_ID + "/dependents?offset=" + $offset + $amp + "limit=50"
        $resp    = Invoke-RestMethod -Uri $url -Method GET -Headers $script:Headers -WebSession $script:WebSession
        $entries = if ($resp.entries) { @($resp.entries) } elseif ($resp.entry) { @($resp.entry) } else { $null }
        if ($entries) { $allDeps.AddRange([object[]](@($entries))) }
        $offset += 50
    } while ($entries -and $entries.Count -eq 50)

    # Step 2 — Filter to WebI reports only
    $reports = @($allDeps | Where-Object {
        $kind = if ($_.kind) { $_.kind } elseif ($_.SI_KIND) { $_.SI_KIND } else { "" }
        $kind -match "(?i)webi"
    })

    # Display
    Write-Host ""
    Write-Host $SEP -ForegroundColor Cyan
    Write-Host (" WebI reports linked to universe SI_ID: $UNIVERSE_ID  ($($reports.Count) found)") -ForegroundColor Cyan
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