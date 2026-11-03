param([string]$ReportPath = 'docs/lending-full-validation-20261101/canonical-headers.json')
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$ethereum = @(26150000,26165000,26165040,26165400,26169400,26173000,26177000,26181000)
for ($pin=26185000; $pin -lt 26250000; $pin+=4000) { $ethereum += $pin }
$ethereum += @(26250000,26299000,26300000,26310000)
$networks = @(
    @{chain=1;rpc='https://eth.drpc.org';pins=$ethereum},
    @{chain=42161;rpc='https://arbitrum-one.public.blastapi.io';pins=@(513000000,513800000,513802000,514200000,517000000,514000000,514700000,514701500,515094008,515100000,516094008,516098008,516102008,517500000,519094008,519994008,520000000,520094008)},
    @{chain=8453;rpc='https://mainnet.base.org';pins=@(52500000,52590000,52590180,52640000,52950000,53300000)},
    @{chain=56;rpc='https://bsc-mainnet.public.blastapi.io';pins=@(45000000,129000000,129400000,129401000,131080000)},
    @{chain=137;rpc='https://polygon.drpc.org';pins=@(96500000,96622546)},
    @{chain=10;rpc='https://mainnet.optimism.io';pins=@(158920000,159020249)}
)
$headers = foreach ($network in $networks) {
    $requests = @(@{jsonrpc='2.0';id=0;method='eth_chainId';params=@()})
    foreach ($pin in $network.pins) { $requests += @{jsonrpc='2.0';id=$pin;method='eth_getBlockByNumber';params=@(('0x{0:x}' -f [uint64]$pin),$false)} }
    # Small batches avoid providers' request-count caps. Every requested header
    # must exist; an RPC error or missing response fails this evidence gate.
    $responses = @()
    for ($offset=0; $offset -lt $requests.Count; $offset+=5) {
        $batch = @($requests | Select-Object -Skip $offset -First 5)
        for ($attempt=0; ; $attempt++) {
            try {
                $batchResult = Invoke-RestMethod -Method Post -Uri $network.rpc -ContentType 'application/json' `
                    -UserAgent 'Mozilla/5.0 LendingCompatibilityAudit/1.0' -TimeoutSec 45 `
                    -Body (ConvertTo-Json -InputObject $batch -Depth 5 -Compress)
                break
            } catch {
                $status = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                if ($attempt -ge 5 -or $status -notin @(429,502,503,504)) { throw }
                Write-Warning "Canonical header transport retry: chain $($network.chain), offset $offset, HTTP $status, attempt $($attempt+1)"
                Start-Sleep -Seconds ([Math]::Min(30, 2 * [Math]::Pow(2,$attempt)))
            }
        }
        foreach ($item in $batchResult) { $responses += $item }
        Start-Sleep -Milliseconds 500
    }
    if ($responses.Count -ne $requests.Count) { throw 'Missing canonical header responses' }
    foreach ($response in $responses) {
        if ($response.error -or $null -eq $response.result) { throw ('Canonical RPC failed: ' + ($response | ConvertTo-Json -Depth 5 -Compress)) }
        if ($response.id -eq 0) {
            if ([Convert]::ToUInt64($response.result,16) -ne $network.chain) { throw 'Wrong canonical chain' };continue
        }
        $block=$response.result
        if ([Convert]::ToUInt64($block.number,16) -ne $response.id -or $block.hash -notmatch '^0x[0-9a-f]{64}$') { throw 'Wrong canonical block' }
        [ordered]@{chainId=$network.chain;rpc=$network.rpc;rpcBlock=[string]$response.id;hash=$block.hash;parentHash=$block.parentHash;
            timestamp=[string][Convert]::ToUInt64($block.timestamp,16)}
    }
}
$headers | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReportPath -Encoding utf8
"Recorded $($headers.Count) canonical headers"
