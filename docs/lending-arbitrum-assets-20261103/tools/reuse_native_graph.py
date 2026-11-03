"""Deploy another unfunded asset fixture from an attested fresh full graph.

Only the redundant compiler invocation is reused. Every creation template must
match the reference checkpoint's creation+constructor binding before deployment.
All financial operations remain independent real-node Native simulations.
"""
import argparse
import hashlib
import importlib.util
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('builder', ROOT / 'script/lending/validation/keeper-gas/build_checkpoint.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=pathlib.Path, required=True)
    parser.add_argument('--acceptance', type=pathlib.Path, required=True)
    parser.add_argument('--asset-profile', choices=list(b.ASSET_PROFILES), required=True)
    parser.add_argument('--old-block', type=int, help='Canonical earlier fixture deployment block; sample and simulation pins remain unchanged.')
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    reference, output = args.reference.resolve(), args.output.resolve()
    assert reference != output and reference.parent == output.parent, 'Use the same isolated canonical compiler directory'
    assert 18548 <= args.port <= 18559, 'Dedicated owned local ports only'
    c = json.loads(reference.read_text(encoding='utf-8-sig'))
    assert 'compilationReuse' not in c and c['assetProfile'] == 'usdc', 'Fresh independent full-graph reference required'
    reference_hash = hashlib.sha256(reference.read_bytes()).hexdigest()
    assert c['compilerGraph'] == b.COMPILER_GRAPH
    assert c['builderSha256'] == hashlib.sha256(pathlib.Path(b.__file__).read_bytes()).hexdigest()
    assert c['sourceAcceptanceSha256'] == hashlib.sha256(args.acceptance.read_bytes()).hexdigest()
    original_cli = b.cli
    bindings = []

    def verified_cli(command):
        if command[:3] != ['forge', 'build', '--force']:
            return original_cli(command)
        assert command == ['forge', 'build', '--force', *b.FORGE_FLAGS], 'Unexpected compiler command'
        assert hashlib.sha256(reference.read_bytes()).hexdigest() == reference_hash
        # build() already checked every current Solidity source hash, Core pin,
        # dirty Core state, branch and compiler configuration before this point.
        # Clear the cache so these are real inspect reads of the isolated graph.
        b.CREATION.clear()
        for name, proof in c['constructorProofs'].items():
            creation = b.creation_bytecode(proof['contract'])
            bound = bytes.fromhex(creation[2:] + proof['encodedConstructorArguments'][2:])
            assert hashlib.sha256(bound).hexdigest() == proof['creationSha256'], 'Canonical creation changed: ' + name
            bindings.append({'name': name, 'contract': proof['contract'], 'creationTemplateSha256': hashlib.sha256(bytes.fromhex(creation[2:])).hexdigest()})
        assert len(bindings) == len(c['constructorProofs']) and bindings
        return (reference.parent / 'production-compile.log').read_text(encoding='utf-8').rstrip()

    b.cli = verified_cli
    b.LOCAL = 'http://127.0.0.1:' + str(args.port)
    b.g.DEDICATED_PORT = args.port
    b.g.LOCAL_ANVIL_URL = b.LOCAL
    try:
        b.build(output, args.old_block if args.old_block is not None else c['oldBlock'], c['sampleBlock'], args.acceptance.resolve(), args.asset_profile)
        result = json.loads(output.read_text())
        result['compilationReuse'] = {'mode': 'EXACT_CREATION_BINDING_TO_FRESH_ISOLATED_FULL_GRAPH',
            'referenceCheckpointSha256': reference_hash, 'driverSha256': hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
            'creationBindings': bindings, 'financialStateReused': False}
        output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    finally:
        b.g._kill_anvil()
        output.parent.mkdir(parents=True, exist_ok=True)
        (output.parent / (output.stem + '-rpc-trace.json')).write_text(json.dumps(b.g.RPC_TRACE, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
