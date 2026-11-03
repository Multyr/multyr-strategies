function Test-LendingForkTransportFailure {
    param([string[]]$Lines)
    $failures = @($Lines | Where-Object { $_ -match '^\s*\[FAIL(?:\]|:)' })
    if ($failures.Count -eq 0) { return $false }
    foreach ($failure in $failures) {
        # Only Foundry fork-client failures, never a contract assertion/revert.
        if ($failure -notmatch '^\s*\[FAIL:\s+vm\.(?:rollFork|createFork|createSelectFork|selectFork):' -or
            $failure -notmatch 'error sending request for url|HTTP (?:status )?(?:429|502|503|504)' -or
            $failure -notmatch 'connection reset|connection closed|connection refused|timed out|HTTP (?:status )?(?:429|502|503|504)') {
            return $false
        }
    }
    return $true
}
