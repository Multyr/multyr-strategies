param(
    [Parameter(Mandatory=$true)][string]$Contract,
    [Parameter(Mandatory=$true)][string]$Address,
    [Parameter(Mandatory=$true)][string]$CompilerOutput,
    [Parameter(Mandatory=$true)][string]$CompilerInput,
    [Parameter(Mandatory=$true)][string]$ProofPath,
    [uint64]$Block = 520094008,
    [string]$RpcUrl = 'https://arb1.arbitrum.io/rpc'
)
$ErrorActionPreference = 'Stop'
$compiled = Get-Content -LiteralPath $CompilerOutput -Raw | ConvertFrom-Json
if (@($compiled.errors | Where-Object severity -eq 'error').Count -gt 0) { throw 'Compiler errors in supplied output' }
$targets = @($compiled.contracts.PSObject.Properties | Where-Object { $_.Value.PSObject.Properties.Name -contains $Contract })
if ($targets.Count -ne 1) { throw 'Contract output must be unambiguous' }
$runtime = $targets[0].Value.$Contract.evm.deployedBytecode
$expected = $runtime.object.ToLowerInvariant()
$observed = & cast code $Address --block $Block --rpc-url $RpcUrl
if ($LASTEXITCODE -ne 0) { throw 'Pinned runtime query failed' }
$observed = $observed.Trim().ToLowerInvariant()
if ($observed -notmatch '^0x[0-9a-f]+$') { throw 'Invalid runtime response' }
$actual = $observed.Substring(2)
$names = @{}
function Visit-Immutable($node) {
    if ($null -eq $node) { return }
    if ($node -is [System.Management.Automation.PSCustomObject]) {
        if ($node.nodeType -eq 'VariableDeclaration' -and $node.mutability -eq 'immutable') {
            $names[[string]$node.id] = $node.name
        }
        foreach ($property in $node.PSObject.Properties) { Visit-Immutable $property.Value }
    } elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
        foreach ($item in $node) { Visit-Immutable $item }
    }
}
foreach ($source in $compiled.sources.PSObject.Properties) { Visit-Immutable $source.Value.ast }
$bindings = @()
$bindingErrors = @()
foreach ($reference in $runtime.immutableReferences.PSObject.Properties) {
    $name = $names[$reference.Name]
    if (!$name) { throw "No AST identity for immutable $($reference.Name)" }
    if ($name -eq '_self') { $value = $Address }
    else {
        $value = & cast call $Address ($name + '()(address)') --block $Block --rpc-url $RpcUrl
        if ($LASTEXITCODE -ne 0) { throw "Immutable getter query failed: $name" }
    }
    $value = $value.Trim().ToLowerInvariant()
    if ($value -notmatch '^0x[0-9a-f]{40}$') { throw "Not an address binding: $name" }
    $encoded = $value.Substring(2).PadLeft(64, '0')
    foreach ($range in $reference.Value) {
        if ($range.length -ne 32) { throw 'Unexpected immutable width' }
        $offset = [int]$range.start * 2
        if ($actual.Length -lt $offset + 64 -or $actual.Substring($offset, 64) -ne $encoded) {
            $bindingErrors += [ordered]@{ name=$name; byteOffset=$range.start; expected=$encoded }
        }
        $expected = $expected.Remove($offset, 64).Insert($offset, $encoded)
    }
    $bindings += [ordered]@{ astId=$reference.Name; name=$name; value=$value; ranges=$reference.Value }
}
function Get-RuntimeHash([string]$hex) {
    $paramsJson = ConvertTo-Json -InputObject @($hex) -Compress
    $hash = $paramsJson | & cast rpc web3_sha3 --raw --rpc-url $RpcUrl
    if ($LASTEXITCODE -ne 0) { throw 'Keccak query failed' }
    return ($hash | ConvertFrom-Json)
}
$blockHash = & cast block $Block --field hash --rpc-url $RpcUrl
if ($LASTEXITCODE -ne 0) { throw 'Block hash query failed' }
$proof = [ordered]@{
    contract=$Contract; address=$Address; block=$Block; blockHash=$blockHash.Trim();
    compilerInputSha256=(Get-FileHash -LiteralPath $CompilerInput -Algorithm SHA256).Hash.ToLowerInvariant();
    runtimeBytes=$actual.Length/2; compiledRuntimeBytes=$expected.Length/2; observedKeccak=Get-RuntimeHash $observed;
    compiledBoundKeccak=Get-RuntimeHash ('0x' + $expected);
    immutableBindings=$bindings; immutableBindingErrors=$bindingErrors; exactRuntimeMatch=($expected -ceq $actual)
}
$proof | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ProofPath -Encoding utf8
[PSCustomObject]@{ Contract=$Contract; ExactMatch=$proof.exactRuntimeMatch; Bytes=$proof.runtimeBytes }
if (!$proof.exactRuntimeMatch) { throw 'Compiled runtime does not match pinned chain runtime' }
