# On-Chain Reference Contracts

Production dApps deployed on Ritual Chain (Chain ID 1979). Use these as few-shot ICL patterns for precompile encoding, interface signatures, and feature composition.

## Contract Registry

The machine-readable registry lives at `examples/registry.json`. Current entries:

| Contract | Address | Features |
|----------|---------|----------|
| TweetRegistry | `0x188c30510Ec32E6F00620b4f1c2E63925aA39ea2` | Scheduler, HTTP precompile, Secrets/Delegation |
| TweetRentManager | `0xDb0f588a05F56aF801ED9e17241fa48706e8AE1f` | Scheduler, HTTP precompile, Secrets/Delegation, Contract-owned secrets |

## Pulling Contract Source

Use the pull script to fetch source, bytecode, and function selectors:

```bash
# Pull all registry contracts
python3 scripts/pull_contracts.py

# Pull a specific registry entry
python3 scripts/pull_contracts.py --name TweetRegistry

# Pull any address (ad-hoc, no registry entry needed)
python3 scripts/pull_contracts.py --address 0x1234...

# Pull + register for future use
python3 scripts/pull_contracts.py --address 0x1234... --register MyContract --features Scheduler HTTP

# Discover contracts deployed at a block
python3 scripts/pull_contracts.py --block 2215742
```

Output per contract:
- `source.sol` — Solidity source (from explorer API or GitHub)
- `abi.json` — ABI (if verified on explorer)
- `selectors.json` — 4-byte function selectors with resolved signatures
- `bytecode.hex` — deployed bytecode
- `interfaces/` — dependency interfaces (if available)

## Source Resolution Priority

1. **Explorer API** — `https://explorer.ritualfoundation.org/api/v2/smart-contracts/{address}` — best quality, includes ABI and compiler version
2. **GitHub** — configured per contract in `registry.json` — fallback for unverified contracts
3. **Bytecode analysis** — always available; extracts selectors and resolves via 4byte.directory

## What to Look For in Reference Contracts

- **Precompile encoding** — how call data is encoded for `0x0801` (HTTP), `0x0802` (LLM), etc.
- **Callback handling** — how results are decoded and stored on delivery
- **Feature composition** — how scheduler + secrets + HTTP work together in one contract
- **Fee management** — how `RitualWallet.lockFee()` is called before async requests
- **SPC patterns** — how state writes persist after SPC calls and in two-phase async submit functions

## Agent Deployment Modes In This Repo

- `examples/sovereign-agent/` and `examples/persistent-agent/` are **direct precompile caller mode** examples.
- The **factory-backed harness/launcher mode** documentation lives in `skills/ritual-dapp-agents/SKILL.md`.

## Authoritative Source Rule

Deployed contracts are authoritative over skill descriptions. If a reference contract uses a different interface version or encoding layout than what a skill describes, follow the contract — it is the verified, working implementation on Ritual Chain.
