param(
    [Parameter(Mandatory=$true)][string]$LogPath,
    [Parameter(Mandatory=$true)][int]$ExpectedPassed,
    [Parameter(Mandatory=$true)][int]$ExpectedSuites
)
$ErrorActionPreference = 'Stop'
$passed=0; $failed=0; $skipped=0; $suites=0
foreach ($line in Get-Content -LiteralPath $LogPath) {
    if ($line -match '^Suite result: .*? (\d+) passed; (\d+) failed; (\d+) skipped;') {
        $passed += [int]$Matches[1]; $failed += [int]$Matches[2]; $skipped += [int]$Matches[3]; ++$suites
    }
}
if ($ExpectedPassed -lt 1 -or $ExpectedSuites -lt 1 -or $passed -ne $ExpectedPassed -or
    $suites -ne $ExpectedSuites -or $failed -ne 0 -or $skipped -ne 0) {
    throw "Incomplete lending gate: passed=$passed failed=$failed skipped=$skipped suites=$suites; expected=$ExpectedPassed/$ExpectedSuites"
}
[ordered]@{passed=$passed;failed=$failed;skipped=$skipped;suites=$suites} | ConvertTo-Json -Compress
