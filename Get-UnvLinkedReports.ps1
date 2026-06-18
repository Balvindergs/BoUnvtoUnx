# ==============================================================
#  CONFIGURATION - update these values before running
# ==============================================================
$BO_SERVER      = "your_bo_server"
$BO_PORT        = 6405
$USERNAME       = "administrator"
$PASSWORD       = "your_password"
$AUTH_TYPE      = "secEnterprise"
$UNIVERSE_NAME  = "YOUR_UNIVERSE_NAME"
# ==============================================================

$REST_BASE = "http://"  + $BO_SERVER + ":" + $BO_PORT + "/biprws"
$INFOSTORE = "https://" + $BO_SERVER + "/biprws/infostore"
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
    Write-Host "Logged in as $USERNAME" -ForegroundColor Green
}

function Invoke-BOLogoff {
    try {
        Invoke-RestMethod -Uri ($REST_BASE + "/logoff") -Method POST `
            -Headers $script:AuthHeaders -WebSession $script:WebSession | Out-Null
        Write-Host "Logged off." -ForegroundColor Gray
    } catch { }
}

Write-Host ""
Write-Host $SEP -ForegroundColor Cyan
Write-Host " UNV Linked Reports  |  Universe: $UNIVERSE_NAME" -ForegroundColor Cyan
Write-Host $SEP -ForegroundColor Cyan
Write-Host ""

Invoke-BOLogon

try {
    $amp          = [char]38
    $query        = "SELECT SI_ID,SI_NAME,SI_KIND,SI_OWNER FROM CI_INFOOBJECTS WHERE PARENTS(`"SI_NAME='webi-universe'`",`"SI_NAME='$UNIVERSE_NAME'`") AND SI_INSTANCE=0"
    $encodedQuery = [Uri]::EscapeDataString($query)
    $offset       = 0
    $limit        = 50
    $results      = [System.Collections.Generic.List[object]]::new()

    do {
        $url     = $INFOSTORE + "?query=" + $encodedQuery + $amp + "offset=" + $offset + $amp + "limit=" + $limit
        $resp    = Invoke-RestMethod -Uri $url -Method GET -Headers $script:AuthHeaders -WebSession $script:WebSession
        $entries = $resp.entries
        if ($null -eq $entries) { $entries = $resp.entry }
        if ($entries) { $results.AddRange([object[]](@($entries))) }
        $offset += $limit
    } while ($entries -and (@($entries)).Count -eq $limit)

    Write-Host ("Found " + $results.Count + " object(s) linked to: $UNIVERSE_NAME") -ForegroundColor Yellow
    Write-Host ""

    if ($results.Count -gt 0) {
        $results | ForEach-Object {
            $id    = $_.id
            $name  = if ($_.name)  { $_.name }  elseif ($_.title)  { $_.title }  else { "-" }
            $kind  = if ($_.kind)  { $_.kind }  elseif ($_.SI_KIND) { $_.SI_KIND } else { "-" }
            $owner = if ($_.owner) { $_.owner } elseif ($_.SI_OWNER){ $_.SI_OWNER } else { "-" }
            Write-Host ("  ID: {0,-12} Kind: {1,-30} Owner: {2,-20} Name: {3}" -f $id, $kind, $owner, $name)
        }
    }

    Write-Host ""
    Write-Host $SEP -ForegroundColor Cyan

} finally {
    Invoke-BOLogoff
}