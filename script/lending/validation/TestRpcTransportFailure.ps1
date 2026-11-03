$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/RpcTransportFailure.ps1"
# Reproduce the observed CI error and protect the acceptance gate from retries
# that could hide a deterministic or intermittently failing contract assertion.
$reset = '[FAIL: vm.rollFork: could not instantiate forked environment with provider eth.drpc.org; error sending request for url (https://eth.drpc.org/); client error (SendRequest); connection error; connection reset] test_multiAdapterUsdtProductionScoringAndExit()'
$cases = @(
    @{ lines=@($reset); expected=$true },
    @{ lines=@($reset,$reset); expected=$true },
    @{ lines=@('[FAIL: vm.createSelectFork: HTTP 429 error sending request for url (https://eth.drpc.org/)] test_market()'); expected=$true },
    @{ lines=@($reset,'[FAIL: assertion failed: amount mismatch] test_recall()'); expected=$false },
    @{ lines=@('[FAIL: assertion failed: connection reset] test_recall()'); expected=$false },
    @{ lines=@('[FAIL: vm.rollFork: canonical block hash mismatch] test_market()'); expected=$false },
    @{ lines=@('[FAIL: execution reverted] test_market()'); expected=$false },
    @{ lines=@('Error: connection reset'); expected=$false },
    @{ lines=@('[PASS] test_market()'); expected=$false }
)
foreach ($case in $cases) {
    if ((Test-LendingForkTransportFailure -Lines $case.lines) -ne $case.expected) {
        throw "Transport classification mismatch: $($case.lines -join '; ')"
    }
}
Write-Output "PASS: $($cases.Count) fork-transport classifier cases; contract failures remain fatal"
