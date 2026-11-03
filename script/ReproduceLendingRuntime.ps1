param(
    [Parameter(Mandatory=$true)][string]$SolcPath,
    [string]$RpcUrl = 'https://arbitrum-one.public.blastapi.io',
    [uint64]$Block = 520094008
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$original = Join-Path $root 'deployments/ema-first-20261023/allocator-exact-input.json'
$outDir = Join-Path $root 'deployments/lending-source-review-20261031'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$targets = [ordered]@{
    StrategyParamsModule='0x9DdbFF7a2D6cbfdA7fE5Fe72A7e7A09eef8F2772'
    StrategyScoringModule='0x5Aa4d01CEe130f5C5CfADd091c1aFF12496f7A01'
    StrategyAdapterOpsModule='0xe55fB758f1B7e418670849AF812A1B9C80b40f59'
    StrategyRebalanceGateModule='0x7aa669f8Ef61071Cd5FA2b30f26B5ba5Cd741Fc2'
    StrategySettingsModule='0xbF0541cFd02933825739e64FD618Bdd5155D77f9'
    StrategyRebalancePlanModule='0x32631c98C8CeA03e69285d9cA6cf2A9d516231C5'
    StrategySafetyOverflowModule='0x5FC0ae46a8c9e15C08553b55Fd3033AC500caA7d'
    StrategyAllocCalcModule='0x08a1eb6FC01042447A35CA59c3c00c588C41A878'
    UsdcMultiLendingVault='0x2AD722B6241605481829E4B251AE8A4Ba8Be86cE'
}
$inputObject = Get-Content -LiteralPath $original -Raw | ConvertFrom-Json
$selection = @{}
foreach ($name in $targets.Keys) {
    $file = if ($name -eq 'UsdcMultiLendingVault') { 'UsdcLendingStrategy' } else { $name }
    $source = 'src/strategies/usdc-lending/controller/' + $file + '.sol'
    $selection[$source] = @{ $name=@('evm.deployedBytecode.object','evm.deployedBytecode.immutableReferences'); ''=@('ast') }
}
$selection['src/strategies/usdc-lending/controller/StrategyStorageLayout.sol'] = @{ ''=@('ast') }
# Preserve the complete original source graph. Pruning it changes via-IR codegen
# identities and fails exact runtime reproduction even with identical target text.
$inputObject.settings.outputSelection = $selection
$inputJson = $inputObject | ConvertTo-Json -Depth 100 -Compress
$inputPath = Join-Path $outDir 'live-modules-input.json'
$outputPath = Join-Path $outDir 'live-modules-output.json'
$inputJson | Set-Content -LiteralPath $inputPath -Encoding utf8
$compiler = (Resolve-Path -LiteralPath $SolcPath).Path
$temporaryCompiler = $null
try {
    # Foundry's Windows SVM binary has no .exe extension; PowerShell otherwise
    # treats it as a document in a pipeline. Copy the same local binary to temp.
    if ($IsWindows -and [IO.Path]::GetExtension($compiler) -ne '.exe') {
        $temporaryCompiler = Join-Path $env:TEMP ('multyr-solc-audit-' + [guid]::NewGuid().ToString('N') + '.exe')
        Copy-Item -LiteralPath $compiler -Destination $temporaryCompiler
        $compiler = $temporaryCompiler
    }
    $version = & $compiler --version
    if ($LASTEXITCODE -ne 0 -or ($version -join ' ') -notmatch '0\.8\.28\+commit\.7893614a') { throw 'Requires exact solc 0.8.28 build' }
    $inputJson | & $compiler --standard-json | Set-Content -LiteralPath $outputPath -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Compiler failed' }
    foreach ($entry in $targets.GetEnumerator()) {
        & (Join-Path $PSScriptRoot 'VerifyPinnedRuntime.ps1') -Contract $entry.Key -Address $entry.Value `
            -CompilerInput $inputPath -CompilerOutput $outputPath `
            -ProofPath (Join-Path $outDir ($entry.Key + '-proof.json')) -Block $Block -RpcUrl $RpcUrl
    }
} finally {
    if ($null -ne $temporaryCompiler) { Remove-Item -LiteralPath $temporaryCompiler -ErrorAction SilentlyContinue }
}
