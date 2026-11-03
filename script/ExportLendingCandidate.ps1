param([string]$Destination = 'deployments/lending-full-validation-20261101/final')
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$base = '211f1a0a4cb9c63232ae18dac24ccb921e5a4699'
$head = (& git rev-parse HEAD).Trim()
& git merge-base --is-ancestor $base $head
if ($LASTEXITCODE -ne 0) { throw 'Candidate must descend from the reviewed base' }
$branch = (& git branch --show-current).Trim()
if ($branch -ne 'codex/lending-multitoken-multichain') { throw 'Unexpected candidate branch' }
& git diff --quiet --ignore-submodules=none $base -- lib
if ($LASTEXITCODE -ne 0) { throw 'Frozen dependency checkout is dirty or moved' }
$frozenCore = '9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9'
if ((& git rev-parse 'HEAD:lib/multyr-core').Trim() -ne $frozenCore -or
    (& git -C lib/multyr-core rev-parse HEAD).Trim() -ne $frozenCore) { throw 'Frozen Core pin changed' }
$validationPath = 'docs/lending-full-validation-20261101/final-validation.json'
if (-not (Test-Path -LiteralPath $validationPath)) { throw 'Final expanded validation ledger is required before release export' }
$validation = Get-Content -LiteralPath $validationPath -Raw | ConvertFrom-Json
if ($validation.status -ne 'COMPLETE_FOR_VALIDATED_MATRIX') { throw 'Expanded validation gates are not closed' }
if ($validation.readiness -ne 'PRODUCTION_READY') { throw 'Production readiness is not approved' }
$changed = @(& git diff --name-only $base)
$added = @(& git ls-files --others --exclude-standard -- src test script docs .github foundry.toml README.md .gitignore)
$patch = [Text.StringBuilder]::new()
foreach ($line in @(& git diff --binary --no-ext-diff $base)) { [void]$patch.Append($line).Append("`n") }
if ($LASTEXITCODE -ne 0) { throw 'Tracked diff export failed' }
foreach ($file in $added) {
    foreach ($line in @(& git diff --no-index --binary --no-ext-diff -- /dev/null $file)) { [void]$patch.Append($line).Append("`n") }
    if ($LASTEXITCODE -notin @(0,1)) { throw "New-file diff export failed: $file" }
}
$encoding = [Text.UTF8Encoding]::new($false)
$patchPath = Join-Path $Destination 'candidate.patch'
$entries = @(@($changed + $added) | Sort-Object -Unique | ForEach-Object {
    if (Test-Path -LiteralPath $_ -PathType Leaf) {
        $normalized = [IO.File]::ReadAllText((Join-Path (Get-Location) $_)).Replace("`r`n", "`n")
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalized))).ToLowerInvariant()
        [ordered]@{path=$_; utf8LfSha256=$digest; rawSha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant(); bytes=(Get-Item -LiteralPath $_).Length}
    } else { [ordered]@{path=$_; deleted=$true} }
})
$manifest = [ordered]@{baseCommit=$base; candidateCommit=$head; branch=$branch;
    frozenCoreCommit='9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9';
    hashPolicy='Verify utf8LfSha256 after decoding UTF-8 and normalizing CRLF to LF; rawSha256 is same-host diagnostic only'; files=$entries}
$functional = @($entries | Where-Object { $_.path -match '^(src|test|script)/.*\.(sol|ps1|py)$' -or $_.path -match '^(script|test)/.*\.json$' -or $_.path -in @('foundry.toml','.gitignore','.github/workflows/lending-asset-matrix.yml','.github/workflows/forge-test.yml') } |
    Sort-Object { $_['path'] } | ForEach-Object { $_['path'] + ' ' + $_['utf8LfSha256'] })
$functionalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($functional -join "`n") + "`n"))).ToLowerInvariant()
if ($functionalHash -ne $validation.functionalSnapshotSha256) { throw 'Functional source changed since recorded validation; rerun tests and refresh the ledger' }
$manifestPath = Join-Path $Destination 'candidate-files.json'
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
[IO.File]::WriteAllText((Join-Path (Get-Location) $patchPath), $patch.ToString(), $encoding)
& git apply --check --reverse -- $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Exported patch does not reverse-check against candidate' }
[IO.File]::WriteAllText((Join-Path (Get-Location) $manifestPath), ($manifest | ConvertTo-Json -Depth 10), $encoding)
$checksums = foreach ($path in @($patchPath,$manifestPath)) {
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() + ' *' + (Split-Path $path -Leaf)
}
[IO.File]::WriteAllText((Join-Path (Get-Location) (Join-Path $Destination 'candidate-bundle.sha256')), ($checksums -join "`n")+"`n", $encoding)
[ordered]@{files=$entries.Count; patchBytes=(Get-Item -LiteralPath $patchPath).Length; checksums=$checksums} | ConvertTo-Json
