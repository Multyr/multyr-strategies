param(
    [string]$LogPath = 'deployments/lending-full-validation-20261101/actual-release.log',
    [string]$EvidencePath = 'docs/lending-full-validation-20261101/actual-acceptance.json'
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
# Foundry 1.4.2 recreates clients in vm.createSelectFork/rollFork; CLI limits
# alone do not bind those literal endpoints. Apply the same policy locally as CI.
if ([string]::IsNullOrWhiteSpace($env:FOUNDRY_RPC_ENDPOINTS)) {
    $rpcPolicy = 'retries = 8, retry_backoff = 5000, compute_units_per_second = 10'
    $rpcEndpoints = @('https://arbitrum-one.public.blastapi.io','https://eth-mainnet.public.blastapi.io',
        'https://bsc-mainnet.public.blastapi.io','https://mainnet.base.org','https://base-mainnet.public.blastapi.io',
        'https://polygon.drpc.org','https://mainnet.optimism.io')
    $env:FOUNDRY_RPC_ENDPOINTS = '{ ' + (($rpcEndpoints | ForEach-Object {
        $endpoint = if ($_ -eq 'https://eth-mainnet.public.blastapi.io') { 'https://eth.drpc.org' } else { $_ }
        '"' + $_ + '" = { endpoint = "' + $endpoint + '", ' + $rpcPolicy + ' }'
    }) -join ', ') + ' }'
}
$config = & forge config --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $config.solc -ne '0.8.28' -or $config.optimizer -ne $true -or
    $config.optimizer_runs -ne 200 -or $config.via_ir -ne $true -or $config.evm_version -ne 'cancun' -or
    $config.bytecode_hash -ne 'none' -or $config.cbor_metadata -ne $false) { throw 'Unexpected actual-market compiler settings' }
$tests = 'test/strategies/usdc-lending/fork/actual'
# These twenty-one suites are the no-mock gate. Controlled fault tests run separately.
$forbidden = '\b(?:vm\.)?(?:deal|etch|store|mockCall|mockCallRevert|warp)\s*\('
$violations = @(Get-ChildItem -LiteralPath $tests -Filter '*.sol' | Select-String -Pattern $forbidden)
if ($violations.Count -gt 0) { throw ('Synthetic-state operation in actual-market gate: ' + ($violations -join '; ')) }
function Source-Snapshot {
    $paths = @(& git ls-files -- src script test foundry.toml) + @(& git ls-files --others --exclude-standard -- src script test foundry.toml)
    @($paths | Where-Object { $_ -match '\.sol$' -or $_ -eq 'foundry.toml' } | Sort-Object -Unique | ForEach-Object {
        [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
}
$sources = Source-Snapshot
$before = ConvertTo-Json -InputObject $sources -Depth 4 -Compress
New-Item -ItemType Directory -Path (Split-Path $LogPath -Parent) -Force | Out-Null
. "$PSScriptRoot/lending/validation/RpcTransportFailure.ps1"
$runnerSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
$classifierPath = "$PSScriptRoot/lending/validation/RpcTransportFailure.ps1"
$classifierSha256 = (Get-FileHash -LiteralPath $classifierPath -Algorithm SHA256).Hash.ToLowerInvariant()
$infrastructureAttempts = @()
for ($attempt = 1; $attempt -le 3; $attempt++) {
    & forge test --match-path "$tests/**" --threads 1 `
        --fork-url https://eth-mainnet.public.blastapi.io --fork-block-number 26300000 `
        --compute-units-per-second 20 --fork-retries 8 --fork-retry-backoff 2000 -vvvv --summary *> $LogPath
    $code = $LASTEXITCODE
    if ($code -eq 0) { break }
    $transportOnly = Test-LendingForkTransportFailure -Lines @(Get-Content -LiteralPath $LogPath)
    if (-not $transportOnly -or $attempt -eq 3) { break }
    $failedPath = "$LogPath.transport-attempt-$attempt.log"
    if (Test-Path -LiteralPath $failedPath) { throw "Refusing to overwrite failed transport evidence: $failedPath" }
    Copy-Item -LiteralPath $LogPath -Destination $failedPath
    $infrastructureAttempts += [ordered]@{attempt=$attempt;log=$failedPath;exitCode=$code;
        logSha256=(Get-FileHash -LiteralPath $failedPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    $infrastructureAttempts | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$LogPath.transport-attempts.json" -Encoding utf8
    Write-Warning "RPC transport failure; preserving attempt $attempt and restarting all 50 cases on the same pinned blocks"
    Start-Sleep -Seconds 15
}
Get-Content -LiteralPath $LogPath -Tail 28
if ($code -ne 0) { throw "Actual-market acceptance failed: exit $code" }
& "$PSScriptRoot/AssertLendingTestSummary.ps1" -LogPath $LogPath -ExpectedPassed 50 -ExpectedSuites 21
if ((ConvertTo-Json -InputObject @(Source-Snapshot) -Depth 4 -Compress) -ne $before) { throw 'Source changed during actual-market acceptance' }
if ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $runnerSha256 -or
    (Get-FileHash -LiteralPath $classifierPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $classifierSha256) {
    throw 'Validation runner changed during actual-market acceptance'
}
New-Item -ItemType Directory -Path (Split-Path $EvidencePath -Parent) -Force | Out-Null
$headerPath = Join-Path (Split-Path $EvidencePath -Parent) ((Split-Path $EvidencePath -LeafBase) + '-canonical-headers.json')
& "$PSScriptRoot/RecordLendingActualHeaders.ps1" -ReportPath $headerPath | Out-Null
$branchName = & git branch --show-current
if ([string]::IsNullOrWhiteSpace($branchName)) { $branchName = 'DETACHED_HEAD' }
$evidence = [ordered]@{
    baseCommit=(& git rev-parse HEAD).Trim();branch=$branchName
    dependencies=@(& git submodule status);foundry=(& forge --version | Select-Object -First 1)
    compiler='0.8.28';optimizerRuns=200;viaIR=$true;evmVersion='cancun'
    passed=50;failed=0;skipped=0;suites=21
    positiveLifecycleAndIntegrationTests=48;negativeCappedMarketRejectionTests=1;negativeLegacyFeedRejectionTests=1
    log=$LogPath;logSha256=(Get-FileHash -LiteralPath $LogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    runnerSha256=$runnerSha256
    transportClassifierSha256=$classifierSha256
    maximumTransportAttempts=3
    infrastructureAttempts=$infrastructureAttempts
    canonicalHeaders=$headerPath;canonicalHeadersSha256=(Get-FileHash -LiteralPath $headerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    sources=$sources
    quantityEncoding='Raw event text preserves every integer exactly, without JSON floating-point conversion.'
    observations=@(Select-String -LiteralPath $LogPath -Pattern 'emit (Actual|Real|NativeFee)' | ForEach-Object { $_.Line.Trim() })
    limits=@('Local fork simulation; no broadcast.',
        'Historical integrated scenarios preserve affected real protocol state as a disclosed closed counterfactual; they do not replay all intervening transactions.',
        'Native ETH is unsupported by the frozen ERC20 core; WETH is tested.',
        'Only the named chain/token/market rows are accepted; market caps, liquidity and oracle validity can change.')
}
New-Item -ItemType Directory -Path (Split-Path $EvidencePath -Parent) -Force | Out-Null
$evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
