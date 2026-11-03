param([string]$Case = '')
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
# Public endpoints only by default; no dotenv, workstation keys or broadcasts.
if (-not $env:ETH_RPC_URL) { $env:ETH_RPC_URL = 'https://eth-mainnet.public.blastapi.io' }
if (-not $env:ARB_RPC_URL) { $env:ARB_RPC_URL = 'https://arbitrum-one.public.blastapi.io' }
if (-not $env:BSC_RPC_URL) { $env:BSC_RPC_URL = 'https://bsc-mainnet.public.blastapi.io' }
$env:PYTHONIOENCODING = 'utf-8'
$directory = 'deployments/lending-full-validation-20261101/production/transaction-gas'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmss') + '-' + $PID
$log = Join-Path $directory ($stamp + '.log')
$arguments = @('script/lending/validation/transaction-gas/runner.py')
if ($Case) { $arguments += @('--case', $Case) }
& python @arguments *> $log
$code = $LASTEXITCODE
Get-Content -LiteralPath $log -Tail 24
if ($code -ne 0) { throw "Transaction-gas validation failed ($code); raw log: $log" }
Write-Output "Raw log: $log"
