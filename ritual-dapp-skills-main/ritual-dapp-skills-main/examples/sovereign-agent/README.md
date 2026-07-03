# Sovereign Agent Example

End-to-end `0x080C` sovereign agent call in **direct precompile caller mode**.

## Deployment Modes

This repo supports two sovereign deployment modes:

1. **Direct precompile caller mode** (this example): a consumer contract calls `0x080C` directly.
2. **Factory-backed harness mode** (recommended for production): deploy `SovereignAgentHarness` via `SovereignAgentFactory` (`0x9dC4C054e53bCc4Ce0A0Ff09E890A7a8e817f304`), then configure/fund/start the harness.

For the factory-backed flow, use the factory section in `skills/ritual-dapp-agents/SKILL.md`.

The script:
- deploys a minimal consumer contract
- auto-funds `RitualWallet` if needed
- discovers (or pins) an executor
- ECIES-encrypts your secrets
- submits Phase 1 via `cast send --async` (hash printed immediately)
- polls and decodes Phase 2 callback delivery

## Prerequisites

```bash
# Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# uv (required - script uses `uv run --with ...`)
curl -LsSf https://astral.sh/uv/install.sh | sh
uv --version
```

No `pip`/venv setup needed for this example. `run.sh` executes `helpers.py` via:

```bash
uv run --with eciespy --with eth-abi --with web3 python3 helpers.py ...
```

## Required Inputs

`run.sh` fails fast with exit code `2` if any of these are unset or still
contain an unfilled placeholder (`<…>`, `YOUR_…`). Set them before running:

- `RPC_URL` — e.g. `https://rpc.ritualfoundation.org`
- `PRIVATE_KEY` — 0x-prefixed key funded with native RITUAL for gas
- `HF_TOKEN` — HuggingFace token (`hf_...`) with write access to `HF_REPO_ID`
- `HF_REPO_ID` — HuggingFace dataset ID **you own**, in `user/repo` form (e.g.
  `alice/my-agent-workspace`). Stores conversation history, artifacts, and
  the system prompt. This is a per-run required input; there is no default.
- `MODEL` — exact provider-routable model id
- exactly one LLM key: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, or `OPENROUTER_API_KEY`

> **For agents running this example on behalf of a user:** elicit
> `HF_REPO_ID`, `HF_TOKEN`, `PRIVATE_KEY`, and the LLM credentials from the
> user upfront. These are per-user secrets and per-user resources; the
> example will not run without them.

Example:

```bash
export RPC_URL="https://rpc.ritualfoundation.org"
export PRIVATE_KEY="0x..."
export ANTHROPIC_API_KEY="sk-ant-..."
export MODEL="claude-sonnet-4-5-20250929"
export HF_TOKEN="hf_..."
export HF_REPO_ID="alice/my-agent-workspace"
bash run.sh
```

## Optional Overrides

- `CLI_TYPE` (default `5`, Crush). Supported values: `0` (Claude Code), `5` (Crush), `6` (ZeroClaw)
- `PROMPT` (default `"Say hello world"`)
- `EXECUTOR_TEE_ADDRESS` (optional debug override; default flow discovers a live executor from `TEEServiceRegistry`)
- `CONSUMER_ADDRESS` (reuse an already-deployed consumer contract)
- `PHASE2_TIMEOUT`, `PHASE1_GAS_LIMIT`

Example with explicit executor:

```bash
export EXECUTOR_TEE_ADDRESS="0x<tee-address-from-registry>"
bash run.sh
```

## Provider Model Examples

| Variable | Provider | Example Model |
|----------|----------|---------------|
| `ANTHROPIC_API_KEY` | Anthropic | `claude-sonnet-4-5-20250929` |
| `OPENAI_API_KEY` | OpenAI | `gpt-4o-mini` |
| `GEMINI_API_KEY` | Gemini | `gemini-2.5-flash` |
| `OPENROUTER_API_KEY` | OpenRouter | `anthropic/claude-sonnet-4.5` |

Before submission, run a provider-side model preflight check (model list/validation) and pass the exact routable model id in `MODEL`.

`LLM_PROVIDER="ritual"` is sovereign-only at protocol level, but this example script currently supports Anthropic/OpenAI/Gemini/OpenRouter key flows only.

## What Gets Verified

1. Sender has no pending async job (`AsyncJobTracker`)
2. Sender has enough locked `RitualWallet` balance (auto-deposit if needed)
3. Phase 1 tx is mined
4. Phase 2 callback is delivered and decoded from `SovereignAgentResultDelivered`

## Files

| File | Purpose |
|------|---------|
| `SovereignAgentConsumer.sol` | Minimal consumer contract with callback |
| `run.sh` | One-shot orchestrator |
| `helpers.py` | Request encoding, Phase 1 submission, Phase 2 polling |
