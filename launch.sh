#!/usr/bin/env bash
# One-command Genesis launcher.
# Prereq: wallet 0x8630.. funded from the faucet, and .env filled in.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export PATH="$HOME/.local/bin:$PATH"

# Clear any inherited LLM creds (a Claude Code session injects a PROXY ANTHROPIC_API_KEY
# the on-chain executor cannot use). We want ONLY what your .env provides to win the
# provider-precedence in helpers.py. .env is sourced next, so a real key there still applies.
unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL OPENAI_API_KEY OPENROUTER_API_KEY 2>/dev/null || true

if [ ! -f .env ]; then
  echo "ERROR: no .env found. Run:  cp .env.example .env  then edit it." >&2
  exit 1
fi
set -a; source ./.env; set +a

: "${RPC_URL:?set RPC_URL in .env}"
: "${PRIVATE_KEY:?set PRIVATE_KEY in .env}"

ADDR=$(cast wallet address "$PRIVATE_KEY")
EXPECTED="0x8630...REplace with your Wallet Address"
echo "Deployer address: $ADDR"
if [ "${ADDR,,}" != "${EXPECTED,,}" ]; then
  echo "WARNING: key resolves to $ADDR, not the Genesis wallet $EXPECTED." >&2
  echo "         Genesis credit goes to the address that signs. Ctrl-C now if that's wrong." >&2
  sleep 4
fi

echo "Preflight: wallet must be funded before spawning."
BAL=$(cast balance "$ADDR" --rpc-url "$RPC_URL")
echo "  native balance: $(cast from-wei "$BAL") RIT"
if [ "$BAL" = "0" ]; then
  echo "ERROR: wallet still unfunded. Claim from faucet.ritualfoundation.org first." >&2
  exit 1
fi

# run.sh runs the full guarded flow: LLM-key validation -> budget gate -> pending-job check
# -> deposit -> deploy consumer -> derive+fund child -> eth_call dry-run -> spawn.
exec bash run.sh
