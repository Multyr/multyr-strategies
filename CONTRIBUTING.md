# Contributing

Thanks for your interest in contributing to `multyr-strategies`. This file
describes how external contributions are handled.

## Branch Convention

| Branch pattern | Purpose |
|---|---|
| `main` | Latest tagged release |
| `pierdev` | Development integration branch (not stable) |
| `reorg/runbook-<id>` | Individual Run Book execution branches |
| `feat/<short-name>` | Feature branches — rebase onto `pierdev` before review |
| `fix/<short-name>` | Bug fix branches |

## Commit Style

Internal commits use the Run Book step format:

```
runbook-<id>: step <N> — <one-line action>
```

External contributors may use a simpler `<area>: <imperative summary>` style.
Examples:

```
strategy: fix scoring overflow at tier boundary
docs: add USDC Lending threat-model adapter section
test: add AaveAdapter fork test for oracle staleness
```

## Pull Request Process

1. Open the PR against `pierdev` (never against `main` directly).
2. Ensure CI passes: `forge build`, `forge test`, `forge fmt --check`.
3. Update `CHANGELOG.md` under the relevant heading.
4. A Foundation reviewer will respond within 7 days.
5. Squash or rebase before merge if requested.

## Code Style

- Solidity 0.8.20
- `forge fmt` is the canonical formatter — run before pushing
- All new adapter functions need at least one unit test and one fork test
- All revert paths need a named custom error
- Comments in English only
- Each new market adapter must implement the full `ILendingAdapter` interface

## Testing

- Unit and integration tests: `forge test --no-match-path "test/fork*"`
- Fork tests for adapters require `ARBITRUM_ARCHIVE_RPC_URL` and a pinned block
- Coverage goal: ≥ 90% line coverage on `src/`
- Adapter fork tests must cover: deposit, withdraw, rate query, and market availability

## Scope Notes

This repo contains production-ready public strategies only. Development strategies
(Multiply, PT-Multiply) live in private development repositories. Do not
add in-development or experimental code to this repo.

## License

By contributing, you agree that your contribution is licensed under the same
Business Source License 1.1 terms as the rest of this repository.
