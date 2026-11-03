param(
    [string]$ReportPath = 'docs/lending-verification-20261031/candidate-structure.json',
    [string]$OutputDirectory = 'deployments/lending-source-review-20261031/structure-out',
    [string]$CachePath = 'deployments/lending-source-review-20261031/structure-cache.json'
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$effectiveConfig = & forge config --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $effectiveConfig.solc -ne '0.8.28' -or
    $effectiveConfig.optimizer -ne $true -or $effectiveConfig.optimizer_runs -ne 200 -or
    $effectiveConfig.via_ir -ne $true -or $effectiveConfig.evm_version -ne 'cancun' -or
    $effectiveConfig.bytecode_hash -ne 'none' -or $effectiveConfig.cbor_metadata -ne $false) {
    throw 'Unexpected release compiler settings'
}
$foundryVersion = (& forge --version | Select-Object -First 1).Trim()
function Release-SourceSnapshot {
    $paths = @(& git ls-files -- src foundry.toml) + @(& git ls-files --others --exclude-standard -- src foundry.toml)
    @($paths | Where-Object { $_ -match '\.sol$' -or $_ -eq 'foundry.toml' } | Sort-Object -Unique | ForEach-Object {
        $normalized = [IO.File]::ReadAllText((Join-Path (Get-Location) $_)).Replace("`r`n", "`n")
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalized))).ToLowerInvariant()
        [ordered]@{path=$_; utf8LfSha256=$digest}
    })
}
$sourceSnapshot = @(Release-SourceSnapshot)
$sourceSnapshotText = ConvertTo-Json -InputObject $sourceSnapshot -Depth 4 -Compress
$inspectArguments = @('--skip', 'test', '--skip', 'script', '--extra-output', 'storageLayout')
if ($OutputDirectory) { $inspectArguments += @('--out', $OutputDirectory) }
if ($CachePath) { $inspectArguments += @('--cache-path', $CachePath) }
$modules = @('UsdcMultiLendingVault','StrategyParamsModule','StrategyScoringModule',
    'StrategyAdapterOpsModule','StrategyRebalanceGateModule','StrategyRebalancePlanModule',
    'StrategyAllocCalcModule','StrategySafetyOverflowModule','StrategySettingsModule')
$adapters = @('AaveV3USDCAdapter','CometUsdcMultiMarketAdapter','DolomiteUsdcMultiMarketAdapter',
    'EulerUsdcMultiMarketAdapter','FluidUsdcMultiMarketAdapter','MorphoUsdcMultiMarketAdapter',
    'VenusUsdcMultiMarketAdapter','MorphoVaultV2LiquidityView','RewardSwapHelper','StrategyBootstrapper','ReadOnlyGasEstimator','OPStackFeeInfo','NativeL1FeeInfo')
$support = @('AdapterFactory','ProtocolRegistry','StrategyUpkeep','StrategyExplainabilityLens',
    'AdapterMigrationGuard','AdapterSwapGuard','AaveLiquidityRateProvider','DolomiteSupplyRateProvider',
    'GovernedReadOnlyGasEstimator','StrategyMigrationGuard','StrategyStorageLayout','WstEthUsdPriceFeed')
# Build the complete production graph before inspection. A partial inspect cache
# can contain ABI/storage output without executable bytecode for later targets.
& forge build @inspectArguments | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Production graph compilation failed' }
function Inspect-Json($Name, $Field) {
    $raw = & forge inspect $Name $Field --json @inspectArguments
    if ($LASTEXITCODE -ne 0) { throw "forge inspect failed: $Name $Field" }
    return ($raw -join "`n" | ConvertFrom-Json -AsHashtable)
}
function Layout-Rows($Layout) {
    return @($Layout.storage | ForEach-Object {
        [ordered]@{label=$_.label; slot=$_.slot; offset=$_.offset; type=$Layout.types[$_.type].label}
    })
}
$sizes = [ordered]@{}
$runtimeHashes = [ordered]@{}
function Runtime-Keccak([string]$Code) {
    # Direct stdin write avoids Windows' command-line length limit and the
    # CRLF that a PowerShell native pipeline would append to the hex payload.
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = (Get-Command cast -ErrorAction Stop).Source
    $process.StartInfo.ArgumentList.Add('keccak')
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    [void]$process.Start()
    $process.StandardInput.Write($Code); $process.StandardInput.Close()
    $hash = $process.StandardOutput.ReadToEnd().Trim()
    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or $hash -notmatch '^0x[0-9a-f]{64}$') { throw "Runtime hashing failed: $errorText" }
    $process.Dispose()
    return $hash
}
$selectors = @{}
$canonical = $null
foreach ($name in ($modules + $adapters + $support)) {
    $code = (& forge inspect $name deployedBytecode --json @inspectArguments) -join ''
    if ($LASTEXITCODE -ne 0) { throw "Bytecode inspection failed: $name" }
    $code = $code.Trim()
    if ($code -notmatch '^0x[0-9a-fA-F]+$') { throw "Unexpected bytecode for $name" }
    $bytes = ($code.Length - 2) / 2
    if ($bytes -gt 23552) { throw "$name exceeds project runtime buffer: $bytes" }
    $sizes[$name] = $bytes
    $runtimeHashes[$name] = Runtime-Keccak $code
    if ($name -in $modules) {
        $methods = Inspect-Json $name 'methodIdentifiers'
        foreach ($signature in $methods.Keys) {
            $selector = $methods[$signature]
            if ($selectors.ContainsKey($selector) -and $selectors[$selector] -ne $signature) {
                throw "Selector collision: $signature / $($selectors[$selector])"
            }
            $selectors[$selector] = $signature
        }
        $rows = Layout-Rows (Inspect-Json $name 'storageLayout')
        $serialized = ConvertTo-Json -InputObject $rows -Depth 20 -Compress
        if ($null -eq $canonical) { $canonical = $serialized }
        elseif ($serialized -ne $canonical) { throw "Module storage mismatch: $name" }
    }
}
$appendChecks = [ordered]@{}
foreach ($name in @('AaveV3USDCAdapter','CometUsdcMultiMarketAdapter','DolomiteUsdcMultiMarketAdapter',
    'EulerUsdcMultiMarketAdapter','FluidUsdcMultiMarketAdapter','MorphoUsdcMultiMarketAdapter',
    'VenusUsdcMultiMarketAdapter','RewardSwapHelper','StrategyBootstrapper')) {
    $baseline = Get-Content -LiteralPath "test/strategies/usdc-lending/adapters/snapshots/$name.storage.json" -Raw | ConvertFrom-Json -AsHashtable
    $oldRows = Layout-Rows $baseline
    $newRows = Layout-Rows (Inspect-Json $name 'storageLayout')
    if ($newRows.Count -lt $oldRows.Count) { throw "Storage removed: $name" }
    for ($i=0; $i -lt $oldRows.Count; $i++) {
        if ((ConvertTo-Json -InputObject $oldRows[$i] -Compress) -ne (ConvertTo-Json -InputObject $newRows[$i] -Compress)) {
            throw "Existing storage moved: $name index $i"
        }
    }
    $appendChecks[$name] = @{preservedFields=$oldRows.Count; appendedFields=$newRows.Count-$oldRows.Count}
}
$report = [ordered]@{foundry=$foundryVersion; solc='0.8.28'; optimizerRuns=200; viaIR=$true; evmVersion='cancun';
    runtimeLimitBytes=23552; runtimeBytes=$sizes; runtimeTemplateKeccak256=$runtimeHashes;
    runtimeHashPolicy='Compiler runtime templates; constructor immutables require deployment-specific patching. Only contracts without immutables can match the template directly; every immutable-bearing helper requires its own constructor-bound runtime verification.';
    uniqueSelectors=$selectors.Count;
    distinctSignatureCollisions=0; identicalModuleLayouts=$modules.Count; appendOnly=$appendChecks;
    strategyReferenceUnitLast=($rows[-1].label -eq 'referenceUnit'); strategyReferenceUnitSlot=$rows[-1].slot}
if (-not $report.strategyReferenceUnitLast) { throw 'referenceUnit must be the last strategy storage entry' }
if ((ConvertTo-Json -InputObject @(Release-SourceSnapshot) -Depth 4 -Compress) -ne $sourceSnapshotText) {
    throw 'Production source changed during structural acceptance'
}
$report.sourceSnapshot = $sourceSnapshot
$report.sourceSnapshotSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceSnapshotText))).ToLowerInvariant()
$report.runnerSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
$report.dependencies = @(& git submodule status)
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ReportPath -Encoding utf8
$report | ConvertTo-Json -Depth 20
