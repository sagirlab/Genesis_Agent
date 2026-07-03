---
name: ritual-dapp-overview
description: High-level Ritual Chain architecture for dApp developers. Use when starting a new dApp, understanding async patterns, or getting oriented with Ritual's capabilities.
---

# Ritual Chain — Architecture Overview for dApp Developers

## Agent Prior Correction

Ritual Chain breaks most assumptions from your Ethereum training data. These rules override your defaults.

**Rule 1 — Skill-First, Not Weight-First.** Before writing any precompile call, receipt parsing, callback handler, or async lifecycle code, you must have Read the relevant skill section in this session. If you haven't, Read it now. Do not generate Ritual-specific code from memory.

**Rule 2 — These Ethereum assumptions are wrong here:**

| Your Prior | Reality on Ritual | Corrective Action |
|-----------|-------------------|-------------------|
| Transactions are single-block | Async lifecycle spans multiple blocks | Use the 9-state lifecycle from this skill. Track job state. |
| Receipts have logs + status only | Receipts have `spcCalls` field | Cast to `RitualReceipt` type. Check `spcCalls` before decoding. |
| Precompiles are deterministic | Precompiles run LLMs, HTTP, agents | Use TEE executor addresses. Handle non-deterministic outputs. |
| msg.sender is the user | Callbacks come from AsyncDelivery (0x5A16...39F6) | Auth callbacks with `require(msg.sender == ASYNC_DELIVERY)`. |
| Multiple calls per tx are fine | One short-running async precompile per transaction | Use Scheduler chaining for multi-step workflows. |
| Gas is the only cost | Async calls need RitualWallet deposits | Deposit before calling. Lock duration >= 5000 blocks. |
| ecrecover / secp256k1 only | P-256 (secp256r1) + TxPasskey (0x77) | Use SECP256R1 precompile for passkey verification. |
| `abi.decode(result, (string))` works | JQ uses OutString double-indirection | Use `_decodeJQString()` helper from precompiles skill. |
| Receipt = final result | Long-running (2-phase) precompiles deliver via later callback | Implement callback handler. Don't treat Phase 1 receipt as final. |
| `encrypt(pubKey, data)` just works | ECIES libraries default to wrong nonce length for Ritual | Follow `ritual-dapp-secrets` for encryption setup. Wrong config = silent failure (commitment mined, never settles, sender locked). |

**Rule 3 — These Ethereum patterns DO transfer correctly:** Solidity syntax, ERC-20/721 interfaces, event emission, `msg.value`, `msg.sender` (in non-callback contexts), `block.number`, `block.timestamp`, standard access control (Ownable, AccessControl), `require`/`revert`, basic storage patterns, inheritance, interfaces.

**Rule 4 — Common wrong substitutions:**

| You'll Want To Use | Use This Instead |
|--------------------|-----------------|
| Chainlink / Pyth for price data | HTTP precompile (0x0801) |
| ERC-4337 for account abstraction | TxPasskey (0x77) — native, no bundler |
| Chainlink Keepers / Gelato for automation | Scheduler system contract (0x56e7...8B) |
| Off-chain oracle for AI inference | LLM precompile (0x0802) — on-chain |
| IPFS + manual verification | Multimodal precompiles with on-chain content hash |
| Custom ZK verifier contract | ZK long-running precompile (0x0806) |
| .env files for API keys | ECIES encryption to executor public key (see `ritual-dapp-secrets`) |

**Rule 5 — Reinforce at checkpoints.** Before these actions, re-read Rule 2: encoding a precompile call, decoding a precompile response or receipt, writing a callback handler, estimating fees or setting TTL, configuring the Scheduler.

---

## What Is Ritual Chain?

Ritual Chain is an **EVM based L1 with enshrined AI/ML capabilities**. Standard EVM smart contracts can call precompiled addresses to invoke HTTP requests, LLM inference, persistent agent execution, multimodal generation, and more — all verified by TEE (Trusted Execution Environment) attestation.

**The foundational difference:** Traditional blockchains require deterministic execution — every node must produce the same result for every transaction. This makes non-deterministic computation (HTTP calls that return different data each second, LLM inference that produces different text each run, agent reasoning that takes different paths) impossible on-chain. Ritual solves this by enshrining non-deterministic computation as native precompiles. This is why Ritual can do things no other blockchain can: smart contracts that think, see, hear, fetch live data, and run autonomous agents.

What makes Ritual different from a vanilla EVM chain:

| Aspect            | Standard EVM               | Ritual Chain                                                             |
| ----------------- | -------------------------- | ------------------------------------------------------------------------ |
| Computation       | Deterministic opcodes only | Precompiles for non-deterministic AI/ML                                  |
| Execution model   | Synchronous, single-block  | Async multi-block lifecycle for heavy tasks                              |
| Trust model       | Consensus-based            | TEE attestation + on-chain verification                                  |
| Transaction types | Standard (0x02 EIP-1559)   | + TxScheduled (0x10), TxAsyncCommitment (0x11), TxAsyncSettlement (0x12) |
| Native currency   | ETH                        | RITUAL (18 decimals)                                                     |
| Chain ID          | varies                     | **1979**                                                                 |

## Chain Configuration

| Property        | Value                                |
| --------------- | ------------------------------------ |
| Chain ID        | `1979`                               |
| Currency        | RITUAL (18 decimals)                 |
| Block time      | ~350ms (0.35s, conservative baseline) |
| RPC (HTTP)      | `https://rpc.ritualfoundation.org`      |

> For private/internal testnet deployments, override with your deployment-specific RPC endpoint (see chain-deployment-infra configuration).
> For TTL/lock/scheduler timing math, measure recent blocks on your target RPC and use `ritual-dapp-block-time`.

| RPC (WebSocket) | `wss://rpc.ritualfoundation.org/ws`     |
| Block Explorer  | `https://explorer.ritualfoundation.org` |

## Precompile Categories

Ritual precompiles fall into three categories based on execution model.

### 1. Synchronous Precompiles

These execute within a single block, like standard EVM precompiles. No executor is involved — the chain itself evaluates the call. You can make **multiple synchronous precompile calls** in a single transaction with no restrictions.

| Precompile    | Address         | Description                                |
| ------------- | --------------- | ------------------------------------------ |
| **ONNX**      | `0x0000...0800` | On-chain ML model inference (ONNX format)  |
| **JQ**        | `0x0000...0803` | JSON query/transformation                  |
| **Ed25519**   | `0x0000...0009` | Ed25519 signature verification             |
| **SECP256R1** | `0x0000...0100` | P-256 (secp256r1) signature verification   |
| **TX Hash**   | `0x0000...0830` | Returns current transaction hash            |

```
ONNX       = 0x0000000000000000000000000000000000000800
JQ         = 0x0000000000000000000000000000000000000803
ED25519    = 0x0000000000000000000000000000000000000009
SECP256R1  = 0x0000000000000000000000000000000000000100
TX_HASH    = 0x0000000000000000000000000000000000000830
```

### 2. Short-Running (1-Phase) Asynchronous Precompiles

These are handled off-chain by TEE-verified executors. The block builder simulates the user's transaction (fresh simulation), detects the async precompile call, and creates a commitment. The executor processes the operation off-chain in a TEE. The user's original transaction is deferred until the executor's result is available, then re-executed with the result injected into the precompile via the SPC mechanism (fulfilled replay). From your contract's perspective, the precompile call returns the result synchronously. The result appears in the transaction receipt's `spcCalls` field.

> **Critical constraint: at most ONE short-running async precompile call per transaction.** Because the user's transaction is deferred until the executor produces a result (see Transaction Lifecycle below), each transaction can contain only one short-running async precompile invocation. If you need multiple results, use separate transactions or batch the underlying operations into a single call (e.g., a batch JSON-RPC body in a single HTTP POST).
>
> Synchronous precompiles (JQ, ONNX, Ed25519, etc.) are **not** subject to this limit and can be called freely alongside or after a short-running async call.

| Precompile   | Address         | Description                                                     |
| ------------ | --------------- | --------------------------------------------------------------- |
| **HTTP**     | `0x0000...0801` | External HTTP API calls (GET, POST, etc.)                       |
| **LLM**      | `0x0000...0802` | Large language model inference (chat, completion, tool calling) |
| **DKMS Key** | `0x0000...081B` | Decentralized key management                                    |

```
HTTP_CALL  = 0x0000000000000000000000000000000000000801
LLM        = 0x0000000000000000000000000000000000000802
DKMS_KEY   = 0x000000000000000000000000000000000000081B
```

### 3. Long-Running (2-Phase) Asynchronous Precompiles

These are long-running operations where the result is delivered via a **callback to your contract** in a separate transaction. Phase 1 submits the request and follows the same commitment-settlement flow as a short-running async call, except the settled result is a task ID rather than the final output. Phase 2 delivers the actual result. The AsyncDelivery proxy (`0x5A16214fF555848411544b005f7Ac063742f39F6`) is `msg.sender` for all callbacks.

| Precompile           | Address         | Description                                         |
| -------------------- | --------------- | --------------------------------------------------- |
| **Long HTTP**        | `0x0000...0805` | Long-running HTTP with polling + 2-phase delivery |
| **ZK**               | `0x0000...0806` | Zero-knowledge proof generation and verification    |
| **Image**            | `0x0000...0818` | AI image generation                                 |
| **Audio**            | `0x0000...0819` | AI audio generation                                 |
| **Video**            | `0x0000...081A` | AI video generation                                 |
| **Sovereign Agent**  | `0x0000...080C` | Sovereign AI agent (Claude Code, Zero Claw, etc.)   |
| **FHE**              | `0x0000...0807` | Homomorphic encryption inference (CKKS)             |
| **Persistent Agent** | `0x0000...0820` | Persistent agent with identity and memory           |

```
LONG_RUNNING_HTTP  = 0x0000000000000000000000000000000000000805
ZK_TWO_PHASE       = 0x0000000000000000000000000000000000000806
IMAGE_CALL         = 0x0000000000000000000000000000000000000818
AUDIO_CALL         = 0x0000000000000000000000000000000000000819
VIDEO_CALL         = 0x000000000000000000000000000000000000081A
SOVEREIGN_AGENT    = 0x000000000000000000000000000000000000080C
FHE_CALL           = 0x0000000000000000000000000000000000000807
PERSISTENT_AGENT   = 0x0000000000000000000000000000000000000820
```

For agent launches, treat these precompile addresses as execution primitives, and factory contracts as deployment primitives:

- **Direct mode:** call `0x080C` or `0x0820` from your consumer contract.
- **Factory mode (recommended):** deploy child harness/launcher through `SOVEREIGN_FACTORY_ADDRESS` / `PERSISTENT_FACTORY_ADDRESS`, then arm child execution.

## Capability Enum

Each executor registers the capabilities it supports. When selecting an executor, query the TEEServiceRegistry by capability:

| Capability           | Value | Precompile / Notes                                                        |
| -------------------- | ----- | ------------------------------------------------------------------------- |
| `HTTP_CALL`          | 0     | HTTP (0x0801)                                                             |
| `LLM`                | 1     | LLM (0x0802)                                                             |
| `WORMHOLE_QUERY`     | 2     | Cross-chain query capability                                              |
| `STREAMING`          | 3     | Streaming LLM via SSE                                                     |
| `VLLM_PROXY`         | 4     | vLLM inference proxy                                                      |
| `ZK_CALL`            | 5     | ZK (0x0806)                                                               |
| `DKMS`               | 6     | Decentralized key management                                              |
| `IMAGE_CALL`         | 7     | Image (0x0818)                                                            |
| `AUDIO_CALL`         | 8     | Audio (0x0819)                                                            |
| `VIDEO_CALL`         | 9     | Video (0x081A)                                                            |
| `FHE`                | 10    | FHE / CKKS inference (0x0807)                                             |

## Async Transaction Lifecycle

Async precompile operations follow this lifecycle. The on-chain state lives in `AsyncJobTracker`.

**Short-running (HTTP, LLM):**

```
User tx submitted → Builder simulates, detects async precompile
  → TxAsyncCommitment (0x11) — job recorded in AsyncJobTracker
    → Executor processes in TEE, submits result via RPC
      → Builder re-executes deferred tx with result injected (fulfilled replay)
        → TxAsyncSettlement (0x12) — fees distributed, job removed
```

**Long-running (Sovereign Agent, Persistent Agent, Long HTTP, Image, ZK, etc.):**

```
Phase 1: same as above, but executor returns a task ID (not final result)
         → AsyncJobTracker.markPhase1Settled() — sender lock released
         → User can send other transactions

Phase 2: Executor polls/generates → submits delivery result
         → AsyncDelivery.deliver() calls your contract's callback
         → AsyncJobTracker.markDelivered() — job removed
```

If the TTL expires before settlement (short-running) or before Phase 2 delivery (long-running), the job is cleaned up by the expiry bucket system. There is no automatic retry.

> Validate executor availability before submitting. Prefer indexed APIs when finalized (`getCapabilityIndexStatus`, `pickServiceByCapability`), with `getServicesByCapability(capabilityId, true)` as fallback.

### Timing Expectations

| Operation | Typical Duration |
|-----------|-----------------|
| Submission → Commitment | 1-3 blocks (~0.35-1.05 seconds) |
| HTTP call processing | 2-30 seconds |
| LLM inference | 5-60 seconds |
| Sovereign / persistent agent jobs | 30 seconds - 10 minutes |
| Image generation | 10-120 seconds |
| Long-running HTTP | Minutes to hours |

## Custom Transaction Types

Ritual introduces three custom transaction types beyond standard EIP-1559:

| Type                  | Code   | Purpose                                        |
| --------------------- | ------ | ---------------------------------------------- |
| **TxScheduled**       | `0x10` | Scheduler-initiated precompile invocations     |
| **TxAsyncCommitment** | `0x11` | Executor commits to process a job              |
| **TxAsyncSettlement** | `0x12` | Executor settles payments after job completion |

These are system-level transactions created by the chain infrastructure, not by dApp developers directly. Understanding how they relate to your transaction is critical.

## Transaction Lifecycle by Execution Model

### Synchronous Precompiles (JQ, ONNX, Ed25519, etc.)

No system transactions. The precompile executes inline during your transaction, exactly like a standard EVM precompile (e.g., `ecrecover`). Your transaction is mined in the next block with the result immediately available.

```
Block N:  Your transaction is mined.
          call → precompile executes inline → result returned.
          Done. No commitment, no settlement.
```

Total on-chain transactions: **1** (yours).

### Short-Running Async Precompiles (HTTP, LLM, DKMS)

The block builder simulates your transaction (fresh simulation), detects the async precompile call, and creates a commitment. The executor processes the job off-chain in a TEE. When the result is ready, the builder re-executes your deferred transaction with the executor's result injected into the precompile (fulfilled replay), followed by a settlement transaction in the same block.

```
Block N:    You submit your transaction to the mempool.
            The builder simulates it and detects the async precompile call.

Block N+1:  TxAsyncCommitment (0x11) is mined.
            System transaction from 0xfa8e. AsyncJobTracker records the job.
            Your original transaction is removed from the normal pool.

            Off-chain: The executor sees the JobAdded event, performs the
            operation (e.g., makes the HTTP request) inside its TDX TEE,
            and submits the signed result via ritual_submitAsyncResult RPC.

Block N+2+: A block builder that has the executor's result:
            1. Re-executes YOUR deferred transaction with the precompile
               result injected (fulfilled replay via the SPC mechanism).
            2. Immediately follows it with a TxAsyncSettlement (0x12)
               in the SAME block, which distributes fees.
```

Total on-chain transactions: **3** (commitment + your deferred tx re-executed + settlement).
Your transaction and the settlement are always in the **same block**.

> **Why only one short-running async call per transaction:** The builder re-executes your deferred transaction with a single executor result injected. There is no mechanism to coordinate multiple independent executor results for a single transaction.
>
> **Combining with synchronous precompiles:** You CAN call synchronous precompiles (JQ, ONNX, etc.) in the same transaction as a short-running async call. The synchronous precompiles execute inline during the fulfilled replay. This is the recommended pattern for short-running async + post-processing (e.g., HTTP call followed by JQ parsing).

### Long-Running Async Precompiles (Sovereign Agent, Long HTTP, Image, etc.)

Similar commitment flow, but the result is delivered via a **separate callback transaction** rather than being slotted into the original transaction's receipt.

```
Block N:    You submit your transaction to the mempool.

Block N+1:  Your original transaction is mined (Phase 1).
            The precompile call registers an async job.
            Returns a taskId (for Long HTTP, Sovereign Agent) or jobId (for ZK).

            TxAsyncCommitment (0x11) is also mined — executor commits.

            Off-chain: The executor processes the job (may take seconds
            to hours depending on the precompile type).

Block N+K:  TxAsyncSettlement (0x12) is mined.
            This transaction calls your contract's callback function
            (e.g., onSovereignAgentResult, onLongRunningResult) with the result.
            msg.sender for the callback is the AsyncDelivery proxy
            (0x5A16214fF555848411544b005f7Ac063742f39F6).
```

Total on-chain transactions: **3** (your tx + commitment + settlement/callback).
Your transaction is mined **before** the result is ready.
The settlement/callback arrives in a **later block**.

> **Important:** `waitForTransactionReceipt()` only waits for **Phase 1** (your submission tx is mined). It does NOT wait for Phase 2 (the callback with results). For long-running (2-phase) precompiles, implement custom polling:
> ```typescript
> // Phase 1: submit and wait for mining
> const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
> // Phase 2 (long-running only): poll for callback or listen for AsyncDelivery events
> // Do NOT assume receipt contains the final result
> ```

### Sender Lock: One Async Job Per EOA

All async precompiles enforce a **sender lock** at the RPC level: only one unresolved async transaction per EOA at a time. If an EOA has a pending async job (HTTP, LLM, long-running precompiles, etc.), attempting to submit another async call from the same address will be rejected with "sender locked."

This lock is enforced at the RPC layer. The pending state is queryable on-chain via `AsyncJobTracker.hasPendingJobForSender(address)`. Workarounds:
- **Sequential:** Wait for the current job to settle before submitting the next
- **Concurrent:** Use different EOAs for each concurrent async operation

### Sequencing Rights

On most blockchains, the block proposer can order transactions in any way they choose. This is the root of MEV: the proposer reorders, inserts, or censors transactions for profit. On Ritual Chain, smart contracts can constrain this.

**Any smart contract can implement the `ISequencingRights` interface.** The interface exposes a single function, `sequencingRights()`, which returns `bytes4[][] memory` — an ordered array of selector sets. Each inner array is a priority level: selectors in the first array have the highest priority (must come first), selectors in the second array have the next priority, and so on. Selectors within the same inner array share the same priority. This is not a suggestion or an opt-in preference. It is a validity constraint enforced at the consensus layer. A block that violates a contract's sequencing rights is invalid.

**How it works:**

1. A smart contract implements `sequencingRights()` returning a `bytes4[][]`. For example, `[[selectorA], [selectorB, selectorC]]` defines two priority levels: level 0 contains `selectorA`, level 1 contains both `selectorB` and `selectorC`.
2. When building a block, each transaction is classified by simulating its execution with an EVM inspector that traces the full call graph (CALL, STATICCALL, DELEGATECALL, CALLCODE). The classification determines which contract(s) a transaction interacts with and which selectors it touches — not just the top-level call, but all internal calls.
3. Transactions are partitioned into per-contract buckets. Only transactions that interact with exactly one contract that has sequencing rights are bucketed. Transactions that touch zero SR contracts, or multiple SR contracts, are left in their original position.
4. Within each bucket, transactions are assigned a priority based on which selectors they called. If a transaction's selectors are a subset of a priority level, it gets that level's priority. If they span multiple levels, it gets the lowest (last) matching priority. Unrecognized selectors get the lowest possible priority.
5. The bucket is sorted by priority (stable sort preserving relative order within the same level). The sorted transactions are placed back into the block at the positions originally occupied by that bucket's transactions.
6. The block verifier independently repeats this classification and checks that each bucket is in non-decreasing priority order. If any bucket is out of order, the block is rejected.

**Example:** A contract with `deposit()` and `withdraw()` can implement `sequencingRights()` returning `[[deposit.selector], [withdraw.selector]]`. This guarantees that within any block, all transactions calling `deposit` on that contract are sequenced before any calling `withdraw`, eliminating a class of MEV attacks where a proposer reorders withdrawals ahead of deposits. If the contract also has a `rebalance()` function that should run at the same priority as `deposit`, the return value would be `[[deposit.selector, rebalance.selector], [withdraw.selector]]`.

**For dApp developers:** If your contract has operations that must happen in a specific order (deposits before withdrawals, bids before reveals, locks before unlocks), implement `sequencingRights()` to enforce it at the consensus layer rather than relying on application-level checks that a proposer can circumvent. Be aware that classification is based on the full call graph: if your transaction calls through a router or proxy that touches multiple SR contracts, it will be classified as `MultiContract` and exempt from reordering. Design your contract interactions so that a single user transaction touches at most one contract with sequencing rights.

## Core System Contracts

| Contract                 | Address                                      | Purpose                                          |
| ------------------------ | -------------------------------------------- | ------------------------------------------------ |
| **RitualWallet**         | `0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948` | Fee deposits and locking for async operations    |
| **AsyncJobTracker**      | `0xC069FFCa0389f44eCA2C626e55491b0ab045AEF5` | Tracks async job states and results              |
| **TEEServiceRegistry**   | `0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F` | Registry of TEE executors and their capabilities |
| **Scheduler**            | `0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B` | Time-based scheduled precompile calls            |
| **SecretsAccessControl** | `0xf9BF1BC8A3e79B9EBeD0fa2Db70D0513fecE32FD` | Access control for delegated secret sharing      |
| **ModelPricingRegistry** | `0x7A85F48b971ceBb75491b61abe279728F4c4384f` (UUPS Proxy) | Model pricing & availability registry — query pricing, discover available models. Key functions: `getAllModels()`, `getModel(string)`, `modelExists(string)`, `getAllModelsWithInfo()` |

## Agent Deployment Contracts (Factory Mode)

| Contract | Address | Purpose |
|---|---|---|
| **SovereignAgentFactory** | `0x9dC4C054e53bCc4Ce0A0Ff09E890A7a8e817f304` | Deterministic `SovereignAgentHarness` deployment + launch |
| **PersistentAgentFactory** | `0xD4AA9D55215dc8149Af57605e70921Ea16b73591` | Deterministic `PersistentAgentLauncher` deployment + launch |

Verify contract code exists at both configured addresses before launching agents.

## TEE Trust Model


### How Executors Work

```
┌──────────────────────────────────────────────────────┐
│                    Ritual Chain                        │
│                                                        │
│  Smart Contract ──call──▶ Precompile (0x0801)   │
│       ▲                              │                 │
│       │ TxAsyncSettlement            │ Job created     │
│       │ (result + attestation)       ▼                 │
│  ┌────────────────┐          ┌──────────────────┐     │
│  │ AsyncJobTracker│◀─────────│ TEEServiceRegistry│     │
│  └────────────────┘          └──────────────────┘     │
│                                      │                 │
└──────────────────────────────────────│─────────────────┘
                                       │ Select executor
                                       ▼
                              ┌──────────────────┐
                              │   TEE Executor    │
                              │  (Intel TDX)      │
                              │                   │
                              │  Runs computation │
                              │  in enclave       │
                              │  Signs with TEE   │
                              │  attestation key  │
                              └──────────────────┘
```

**Key trust properties:**

1. **TEE isolation**: Executors run inside hardware-isolated enclaves (Intel TDX). The host OS cannot observe or tamper with computation.
2. **Attestation verification**: Every result is signed with the executor's TEE attestation key. The chain verifies this before accepting settlements.
3. **Registry-based discovery**: Executors register their capabilities and TEE attestations in the on-chain `TEEServiceRegistry`. dApps query this to find suitable executors.
4. **Secret encryption**: Sensitive data (API keys, etc.) is encrypted to the executor's TEE public key using ECIES. Only the enclave can decrypt.

### Executor Selection

Before making an async precompile call, you must select an executor. If the capability index is finalized, prefer indexed selection (`pickServiceByCapability`) for bounded lookup; otherwise use `getServicesByCapability`. The example below shows the fallback-friendly baseline query:

```typescript
import { createPublicClient, http, defineChain } from "viem";

const ritualChain = defineChain({
  id: 1979,
  name: "Ritual",
  nativeCurrency: { name: "RITUAL", symbol: "RITUAL", decimals: 18 },
  rpcUrls: {
    default: {
      http: [process.env.RITUAL_RPC_URL || "https://rpc.ritualfoundation.org"],
    },
  },
});

const publicClient = createPublicClient({
  chain: ritualChain,
  transport: http(),
});

const TEE_SERVICE_REGISTRY =
  "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F" as const;
// TEEServiceContext struct returned by the registry:
// {
//   node: {
//     paymentAddress: address,  — receives payments
//     teeAddress: address,      — TEE-controlled address (USE THIS as the executor address)
//     teeType: uint8,           — 0=DEBUG, 1=TDX
//     publicKey: bytes,         — for ECIES secret encryption
//     endpoint: string,         — internal infrastructure, not used by dApp code
//     certPubKeyHash: bytes32,  — TLS cert hash
//     capability: uint8,        — capability enum value
//   },
//   isValid: bool,              — attestation still valid
//   workloadId: bytes32,        — derived workload ID
// }

const TEE_SERVICE_REGISTRY_ABI = [
  {
    inputs: [
      { name: "capability", type: "uint8" },
      { name: "checkValidity", type: "bool" },
    ],
    name: "getServicesByCapability",
    outputs: [
      {
        type: "tuple[]",
        components: [
          {
            name: "node",
            type: "tuple",
            components: [
              { name: "paymentAddress", type: "address" },
              { name: "teeAddress", type: "address" },
              { name: "teeType", type: "uint8" },
              { name: "publicKey", type: "bytes" },
              { name: "endpoint", type: "string" },
              { name: "certPubKeyHash", type: "bytes32" },
              { name: "capability", type: "uint8" },
            ],
          },
          { name: "isValid", type: "bool" },
          { name: "workloadId", type: "bytes32" },
        ],
      },
    ],
    stateMutability: "view",
    type: "function",
  },
] as const;

// Common capability IDs used by these skills: HTTP_CALL=0, LLM=1, IMAGE_CALL=7, AUDIO_CALL=8, VIDEO_CALL=9
const HTTP_CALL_CAPABILITY = 0;

const services = await publicClient.readContract({
  address: TEE_SERVICE_REGISTRY,
  abi: TEE_SERVICE_REGISTRY_ABI,
  functionName: "getServicesByCapability",
  args: [HTTP_CALL_CAPABILITY, true],
});

if (services.length === 0)
  throw new Error("No services registered for HTTP_CALL");

const executor = services[0];
console.log("Executor TEE address:", executor.node.teeAddress); // USE THIS in precompile calls
console.log("Executor public key:", executor.node.publicKey);   // USE THIS for secret encryption
console.log("Valid:", executor.isValid);

const executorAddress = executor.node.teeAddress;
const executorPublicKey = executor.node.publicKey;
```

> **Common pitfall — executor address discovery:** `getServicesByCapability()` returns an array of `TEEServiceContext` **structs**, not addresses. The executor address you pass to precompile calls is `executor.node.teeAddress` — not the payment address, not the struct offset, and not a raw address from the return value. Tools like `cast` that don't fully decode nested struct arrays will show misleading values (e.g., ABI tuple offsets like `0x...0140` that look like addresses but aren't). Always use a proper ABI decoder (viem, web3.py, ethers) with the full struct definition above.

> **You never connect to executors directly.** The `endpoint` field in the registry is internal infrastructure used to route jobs to executors. dApp developers only need `teeAddress` (for the ABI) and `publicKey` (for encrypting secrets). Ignore the endpoint.

## The Async Request Pattern

Every async precompile call follows the same high-level pattern:

### 1. Deposit RITUAL into RitualWallet

Async operations require fee deposits to compensate executors.

```typescript
import { parseEther } from "viem";

const RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948" as const;
const RITUAL_WALLET_ABI = [
  {
    inputs: [{ name: "lockDuration", type: "uint256" }],
    name: "deposit",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [{ name: "user", type: "address" }],
    name: "balanceOf",
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ name: "amount", type: "uint256" }],
    name: "withdraw",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;

const hash = await walletClient.writeContract({
  address: RITUAL_WALLET,
  abi: RITUAL_WALLET_ABI,
  functionName: "deposit",
  args: [lockDuration], // bigint — number of blocks to lock (must cover operation window)
  value: amount, // bigint — amount of RITUAL to deposit (in wei)
});
await publicClient.waitForTransactionReceipt({ hash });
```

### 2. Encode Request and Call Precompile

Each precompile has a specific ABI for its input. You encode the request using viem's `encodeAbiParameters`.

```typescript
import { encodeAbiParameters } from "viem";

const HTTP_PRECOMPILE = "0x0000000000000000000000000000000000000801" as const;

// Encode HTTP GET request per the precompile ABI
const encoded = encodeAbiParameters(
  [
    { type: "address" }, // executor
    { type: "bytes[]" }, // encrypted_secrets
    { type: "uint256" }, // ttl
    { type: "bytes[]" }, // secret_signatures
    { type: "bytes" }, // user_public_key
    { type: "string" }, // url
    { type: "uint8" }, // method (1=GET, 2=POST, 3=PUT, 4=DELETE, 5=PATCH)
    { type: "string[]" }, // header keys
    { type: "string[]" }, // header values
    { type: "bytes" }, // body
    { type: "uint256" }, // dkmsKeyIndex (0 = not using dKMS)
    { type: "uint8" }, // dkmsKeyFormat
    { type: "bool" },  // piiEnabled
  ],
  [
    executor.node.teeAddress, // executor address
    [], // no encrypted secrets
    100n, // TTL in blocks
    [], // no secret signatures
    "0x", // no user public key
    "https://api.example.com/data",
    1, // GET
    ["Accept"], // header keys
    ["application/json"], // header values
    "0x", // empty body for GET
    0n, // dkmsKeyIndex
    0, // dkmsKeyFormat
    false,  // piiEnabled (set true to enable secret string replacement)
  ],
);

// Submit directly to the HTTP precompile
const hash = await walletClient.sendTransaction({
  to: HTTP_PRECOMPILE,
  data: encoded,
  gas: 2_000_000n,
  maxFeePerGas: 20_000_000_000n,        // 20 gwei
  maxPriorityFeePerGas: 2_000_000_000n,  // 2 gwei
});
```

### 3. Track Job Status

After submission, monitor the async job through its lifecycle:

```typescript
// Watch for job events on the AsyncJobTracker
const logs = await publicClient.getLogs({
  address: "0xC069FFCa0389f44eCA2C626e55491b0ab045AEF5", // AsyncJobTracker
  fromBlock: "latest",
});
```

### 4. Decode Result

When the job reaches SETTLED state, decode the precompile-specific output:

```typescript
import { decodeAbiParameters } from "viem";

const [statusCode, respHeaderKeys, respHeaderValues, body, errorMessage] =
  decodeAbiParameters(
    [
      { type: "uint16" }, // HTTP status code
      { type: "string[]" }, // response header keys
      { type: "string[]" }, // response header values
      { type: "bytes" }, // response body
      { type: "string" }, // error message (empty on success)
    ],
    resultData,
  );

console.log("Status:", statusCode);
console.log("Body:", new TextDecoder().decode(body));
console.log("Error:", errorMessage || "(none)");
```

## Quick Start (Standalone viem)

### Installation

```bash
npm install viem eciesjs
```

### Chain Definition & Client Setup

```typescript
import {
  createPublicClient,
  createWalletClient,
  http,
  defineChain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

// Define the Ritual chain
const ritualChain = defineChain({
  id: 1979,
  name: "Ritual",
  nativeCurrency: { name: "RITUAL", symbol: "RITUAL", decimals: 18 },
  rpcUrls: {
    default: {
      http: [process.env.RITUAL_RPC_URL || "https://rpc.ritualfoundation.org"],
      webSocket: [
        process.env.RITUAL_WS_URL || "wss://rpc.ritualfoundation.org/ws",
      ],
    },
  },
  blockExplorers: {
    default: {
      name: "Ritual Explorer",
      url: "https://explorer.ritualfoundation.org",
    },
  },
});

// Create viem clients
const account = privateKeyToAccount(process.env.PRIVATE_KEY as `0x${string}`);
const publicClient = createPublicClient({
  chain: ritualChain,
  transport: http(),
});
const walletClient = createWalletClient({
  account,
  chain: ritualChain,
  transport: http(),
});
```

### System Contract Addresses

```typescript
// Core system contracts
const ADDRESSES = {
  RITUAL_WALLET: "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948",
  ASYNC_JOB_TRACKER: "0xC069FFCa0389f44eCA2C626e55491b0ab045AEF5",
  TEE_SERVICE_REGISTRY: "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F",
  SCHEDULER: "0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B",
  SECRETS_ACCESS_CONTROL: "0xf9BF1BC8A3e79B9EBeD0fa2Db70D0513fecE32FD",
} as const;

// Precompile addresses
const PRECOMPILES = {
  HTTP_CALL: "0x0000000000000000000000000000000000000801",
  LLM: "0x0000000000000000000000000000000000000802",
  LONG_RUNNING_HTTP: "0x0000000000000000000000000000000000000805",
  ZK_TWO_PHASE: "0x0000000000000000000000000000000000000806",
  IMAGE_CALL: "0x0000000000000000000000000000000000000818",
  AUDIO_CALL: "0x0000000000000000000000000000000000000819",
  VIDEO_CALL: "0x000000000000000000000000000000000000081A",
  ONNX: "0x0000000000000000000000000000000000000800",
  JQ: "0x0000000000000000000000000000000000000803",
  FHE_CALL: "0x0000000000000000000000000000000000000807",
  SOVEREIGN_AGENT: "0x000000000000000000000000000000000000080C",
  DKMS_KEY: "0x000000000000000000000000000000000000081B",
  PERSISTENT_AGENT: "0x0000000000000000000000000000000000000820",
  TX_HASH: "0x0000000000000000000000000000000000000830",
  ED25519: "0x0000000000000000000000000000000000000009",
  SECP256R1: "0x0000000000000000000000000000000000000100",
} as const;

// Capability values for TEEServiceRegistry queries
const Capability = {
  HTTP_CALL: 0,
  LLM: 1,
  WORMHOLE_QUERY: 2,
  STREAMING: 3,
  VLLM_PROXY: 4,
  ZK_CALL: 5,
  DKMS: 6,
  IMAGE_CALL: 7,
  AUDIO_CALL: 8,
  VIDEO_CALL: 9,
  FHE: 10,
} as const;
// For agent precompile capability routing, see ritual-dapp-agents.
```

## Consumer Contract Pattern (Solidity)

dApps typically write "consumer contracts" that interact with precompiles. The basic pattern:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract SimpleHTTPConsumer {
    address constant HTTP_PRECOMPILE = address(0x0801);

    event RequestSubmitted(bytes32 indexed jobId);
    event ResponseReceived(uint16 statusCode, bytes body);

    function makeRequest(
        address executor,
        string calldata url,
        uint256 ttl
    ) external {
        // Encode the request per the HTTP precompile ABI
        bytes memory input = abi.encode(
            executor,        // executor address
            new bytes[](0),  // encrypted secrets
            ttl,             // time-to-live in blocks
            new bytes[](0),  // secret signatures
            hex"",           // user public key
            url,             // target URL
            uint8(1),        // method: GET
            new string[](0), // header keys
            new string[](0), // header values
            hex"",           // body
            uint256(0),      // dkmsKeyIndex
            uint8(0),        // dkmsKeyFormat
            false            // piiEnabled
        );

        // Call the precompile — this creates an async job
        (bool success, bytes memory result) = HTTP_PRECOMPILE.call(input);
        require(success, "Precompile call failed");
    }

    // Basic callback auth pattern: allow only async system sender.
    // Replace with your chain's canonical async delivery sender address.
    // AsyncDelivery proxy — msg.sender for all async callbacks
    address constant ASYNC_DELIVERY_SENDER = 0x5A16214fF555848411544b005f7Ac063742f39F6;

    // Callback for long-running async precompiles (Sovereign Agent, Long HTTP, etc.)
    // AsyncDelivery.deliver() calls this with (jobId, result)
    function onResult(bytes32 jobId, bytes calldata result) external {
        require(msg.sender == ASYNC_DELIVERY_SENDER, "Unauthorized callback");
        // Decode result per precompile type
    }
}
```

## Common dApp Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Frontend (React/Next.js)              │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │  Wallet      │  │  Async Job   │  │  Result Display  │  │
│  │  Connection  │  │  Status UI   │  │  & Rendering     │  │
│  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘  │
│         │                 │                    │             │
└─────────│─────────────────│────────────────────│─────────────┘
          │                 │                    │
          ▼                 ▼                    ▼
┌─────────────────────────────────────────────────────────────┐
│                      viem Layer                                │
│  ┌──────────┐ ┌───────────────┐ ┌────────────────────────┐ │
│  │ Chain    │ │ Codec encode/ │ │ Event subscription /   │ │
│  │ Config   │ │ decode        │ │ polling for results    │ │
│  └──────────┘ └───────────────┘ └────────────────────────┘ │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                     Ritual Chain (L1)                         │
│                                                              │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ Consumer    │  │ System       │  │ Precompiles       │  │
│  │ Contracts   │  │ Contracts    │  │ (0x08xx, 0x01xx)  │  │
│  └─────────────┘  └──────────────┘  └───────────────────┘  │
│                                              │               │
└──────────────────────────────────────────────│───────────────┘
                                               │
                                               ▼
                                    ┌──────────────────┐
                                    │  TEE Executors    │
                                    │  (off-chain)      │
                                    └──────────────────┘
```

## Secret Management Overview

Secrets (API keys, tokens, etc.) are encrypted client-side to an executor's public key using ECIES encryption. The executor decrypts them inside its TEE enclave. Secrets are never visible to other parties.

**String replacement**: The executor decrypts the secrets JSON and does direct string replacement — whatever keys are in your secrets map get replaced wherever they appear in URLs, headers, and body. For example, if you encrypt `{"OPENAI_API_KEY": "sk-abc123"}`, then any occurrence of the literal string `OPENAI_API_KEY` in the request gets replaced with `sk-abc123`. The placeholder format is plain strings, not a templating language.

```typescript
import { encrypt, ECIES_CONFIG } from "eciesjs";
import { toHex } from "viem";

ECIES_CONFIG.symmetricNonceLength = 12; // see ritual-dapp-secrets

// Encrypt each secret to the executor's TEE public key using ECIES
function encryptSecret(
  secretValue: string,
  executorPublicKey: `0x${string}`,
): `0x${string}` {
  const pubKeyBytes = Buffer.from(executorPublicKey.slice(2), "hex");
  const encrypted = encrypt(pubKeyBytes, Buffer.from(secretValue));
  return toHex(encrypted);
}

const executorPublicKey = executor.node.publicKey; // from TEEServiceRegistry query
const encryptedApiKey = encryptSecret("sk-abc123", executorPublicKey);
const encryptedApiSecret = encryptSecret("secret456", executorPublicKey);
```

## Fees and RitualWallet

All async precompile calls require RITUAL deposits in the RitualWallet contract. The deposit must be locked for a sufficient duration to cover the expected execution time.

```typescript
import { parseEther } from "viem";

const RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948" as const;
const RITUAL_WALLET_ABI = [
  {
    inputs: [{ name: "lockDuration", type: "uint256" }],
    name: "deposit",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
] as const;

// Deposit 1 RITUAL, locked for 5000 blocks
const hash = await walletClient.writeContract({
  address: RITUAL_WALLET,
  abi: RITUAL_WALLET_ABI,
  functionName: "deposit",
  args: [5000n], // lock for 5000 blocks
  value: 1_000_000_000_000_000_000n, // 1 RITUAL in wei
});
await publicClient.waitForTransactionReceipt({ hash });
```

Unused gas is refunded automatically after each execution. You can withdraw your remaining balance after the lock expires.

## When to Use Each Precompile

| Use Case                | Precompile         | Example                                |
| ----------------------- | ------------------ | -------------------------------------- |
| Fetch external API data | HTTP (0x0801)      | Price feeds, weather data, social APIs |
| AI text generation      | LLM (0x0802)       | Chatbots, content generation, analysis |
| Real-time AI streaming  | LLM + SSE          | Token-by-token chat interface          |
| Multi-step AI workflows | Sovereign Agent (0x080C) | Research agents, coding harnesses, tool use |
| Long async API calls    | Long HTTP (0x0805) | Data processing, report generation     |
| AI image creation       | Image (0x0818)     | NFT art, avatar generation             |
| AI audio creation       | Audio (0x0819)     | Music, speech synthesis                |
| AI video creation       | Video (0x081A)     | Short-form video content               |
| Verifiable computation  | ZK (0x0806)        | Privacy-preserving proofs              |
| ML model inference      | ONNX (0x0800)      | Classification, prediction             |
| JSON transformation     | JQ (0x0803)        | Parse/filter API responses             |

## Related Skills

- **`ritual-dapp-deploy`** — Chain config, contract deployment, addresses
- **`ritual-dapp-contracts`** — Consumer contract patterns in Solidity
- **`ritual-dapp-precompiles`** — Full ABI reference for all precompile inputs/outputs
- **`ritual-dapp-frontend`** — React frontend with async state machine
- **`ritual-dapp-http`** — HTTP precompile deep dive
- **`ritual-dapp-llm`** — LLM inference and streaming
- **`ritual-dapp-agents`** — Agent and persistent agent patterns
- **`ritual-dapp-da`** — Data Availability: StorageRef format, GCS/HF/Pinata credentials, DA error handling
- **`ritual-dapp-secrets`** — Secret encryption and delegated access
- **`ritual-dapp-wallet`** — RitualWallet fee management
- **`ritual-dapp-scheduler`** — Time-based scheduled operations
