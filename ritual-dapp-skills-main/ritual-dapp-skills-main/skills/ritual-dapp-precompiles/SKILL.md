---
name: ritual-dapp-precompiles
description: Complete Ritual precompile ABI reference. Use when encoding/decoding precompile calls, understanding request/response formats, or debugging precompile interactions.
---

# Ritual Precompile ABI Reference

This file is the ABI reference — field layouts, types, and output formats. For complete contract patterns (deposit, executor selection, callback handling, testing), see `ritual-dapp-contracts`. For wallet deposits and fund flows, see `ritual-dapp-wallet`.

> Deployment note for agents: `0x080C` and `0x0820` ABI calls in this file describe the raw precompile payloads. In production launch flows, prefer factory-backed contract harness mode (`SovereignAgentFactory/SovereignAgentHarness`, `PersistentAgentFactory/PersistentAgentLauncher`) as documented in `ritual-dapp-agents`.

## Address Map

| Precompile | Address | Fields | Execution Model |
|---|---|---|---|
| ONNX Inference | `0x0800` | 7 | Synchronous |
| HTTP Call | `0x0801` | 13 | Short-running async |
| LLM Call | `0x0802` | 30 | Short-running async |
| JQ | `0x0803` | 3 | Synchronous |
| Long-Running HTTP | `0x0805` | 35 | Long-running async |
| ZK Long-Running | `0x0806` | 14 | Long-running async |
| FHE Inference | `0x0807` | 19 | Long-running async |
| Sovereign Agent | `0x080C` | 23 | Long-running async |
| Image Call | `0x0818` | 18 | Long-running async |
| Audio Call | `0x0819` | 18 | Long-running async |
| Video Call | `0x081A` | 18 | Long-running async |
| DKMS Key | `0x081B` | 8 | Short-running async |
| Persistent Agent | `0x0820` | 26 | Long-running async |
| Ed25519 | `0x0009` | 3 | Synchronous |
| SECP256R1 | `0x0100` | 3 | Synchronous |
| TX Hash | `0x0830` | 0 | Synchronous |

**Synchronous**: inline execution, no executor, no limits on calls per tx.
**Short-running async**: One per tx. Builder simulates (fresh simulation), executor processes in TEE, builder re-executes deferred tx with result injected (fulfilled replay). Result in receipt `spcCalls`.
**Long-running async**: Phase 1 mined immediately (returns task ID). Phase 2 delivers result via callback from AsyncDelivery (`0x5A16214fF555848411544b005f7Ac063742f39F6`).

```typescript
const PRECOMPILES = {
  ONNX: '0x0000000000000000000000000000000000000800',
  HTTP_CALL: '0x0000000000000000000000000000000000000801',
  LLM: '0x0000000000000000000000000000000000000802',
  JQ: '0x0000000000000000000000000000000000000803',
  LONG_RUNNING_HTTP: '0x0000000000000000000000000000000000000805',
  ZK_TWO_PHASE: '0x0000000000000000000000000000000000000806',
  FHE_CALL: '0x0000000000000000000000000000000000000807',
  SOVEREIGN_AGENT: '0x000000000000000000000000000000000000080C',
  IMAGE_CALL: '0x0000000000000000000000000000000000000818',
  AUDIO_CALL: '0x0000000000000000000000000000000000000819',
  VIDEO_CALL: '0x000000000000000000000000000000000000081A',
  DKMS_KEY: '0x000000000000000000000000000000000000081B',
  PERSISTENT_AGENT: '0x0000000000000000000000000000000000000820',
  ED25519: '0x0000000000000000000000000000000000000009',
  SECP256R1: '0x0000000000000000000000000000000000000100',
  TX_HASH: '0x0000000000000000000000000000000000000830',
} as const;
```

---

## Output Unwrapping

Async precompiles return `abi.encode(bytes simmedInput, bytes actualOutput)`. Unwrap to get the real result:

```solidity
(, bytes memory actualOutput) = abi.decode(rawOutput, (bytes, bytes));
```

In `eth_call` simulation, `actualOutput` may be empty (`0x`). This is expected — decode the settled receipt for final data.

The `spcCalls` field is a Ritual extension to the transaction receipt:

```typescript
const receipt = await publicClient.waitForTransactionReceipt({ hash });
const spcCalls = (receipt as any).spcCalls;
```

---

## Base Executor Fields (5 fields)

All executor-based precompiles start with these fields:

| Index | Type | Field | Description |
|---|---|---|---|
| 0 | `address` | executor | TEE executor address |
| 1 | `bytes[]` | encryptedSecrets | ECIES-encrypted secret blobs |
| 2 | `uint256` | ttl | Blocks until expiry |
| 3 | `bytes[]` | secretSignatures | Signatures over encrypted secrets |
| 4 | `bytes` | userPublicKey | User's ECIES public key (empty = no output encryption) |

Secrets use plain string replacement — the executor decrypts the secrets JSON and replaces matching key strings wherever they appear in URLs, headers, and body.

---

## HTTP Call (0x0801) — 13 fields

| Index | Type | Field |
|---|---|---|
| 0-4 | — | Base executor fields |
| 5 | `string` | url |
| 6 | `uint8` | method (GET=1, POST=2, PUT=3, DELETE=4, PATCH=5, HEAD=6, OPTIONS=7) |
| 7 | `string[]` | headersKeys |
| 8 | `string[]` | headersValues |
| 9 | `bytes` | body |
| 10 | `uint256` | dkmsKeyIndex (0 = not using dKMS) |
| 11 | `uint8` | dkmsKeyFormat |
| 12 | `bool` | piiEnabled |

**Output**: `(uint16 statusCode, string[] headerKeys, string[] headerValues, bytes body, string errorMessage)`

### Quick Encode

```typescript
// HTTP GET — all 13 fields
const encoded = encodeAbiParameters(
  [{type:'address'},{type:'bytes[]'},{type:'uint256'},{type:'bytes[]'},{type:'bytes'},
   {type:'string'},{type:'uint8'},{type:'string[]'},{type:'string[]'},{type:'bytes'},
   {type:'uint256'},{type:'uint8'},{type:'bool'}],
  [executor, [], 100n, [], '0x', url, 1, [], [], '0x', 0n, 0, false]
);
```

```solidity
// Solidity — decode output after unwrapping (simmedInput, actualOutput) pair
(, bytes memory out) = abi.decode(rawOutput, (bytes, bytes));
(uint16 status, , , bytes memory body, string memory err) =
    abi.decode(out, (uint16, string[], string[], bytes, string));
```

Rough deposit: 0.01 RITUAL.

---

## LLM Call (0x0802) — 30 fields

| Index | Type | Field | Notes |
|---|---|---|---|
| 0-4 | — | Base executor fields | |
| 5 | `string` | messagesJson | `[{role, content}]` |
| 6 | `string` | model | Only confirmed live: `zai-org/GLM-4.7-FP8` |
| 7 | `int256` | frequencyPenalty | ×1000 |
| 8 | `string` | logitBiasJson | |
| 9 | `bool` | logprobs | |
| 10 | `int256` | maxCompletionTokens | -1 = null |
| 11 | `string` | metadataJson | |
| 12 | `string` | modalitiesJson | |
| 13 | `uint256` | n | |
| 14 | `bool` | parallelToolCalls | ABI placeholder (always true) |
| 15 | `int256` | presencePenalty | ×1000 |
| 16 | `string` | reasoningEffort | "low"/"medium"/"high" |
| 17 | `bytes` | responseFormatData | |
| 18 | `int256` | seed | -1 = null |
| 19 | `string` | serviceTier | |
| 20 | `string` | stopJson | |
| 21 | `bool` | stream | |
| 22 | `int256` | temperature | ×1000 |
| 23 | `bytes` | toolChoiceData | ABI placeholder (always 0x) |
| 24 | `bytes` | toolsData | ABI placeholder (always 0x) |
| 25 | `int256` | topLogprobs | -1 = null |
| 26 | `int256` | topP | ×1000 |
| 27 | `string` | user | |
| 28 | `bool` | piiEnabled | |
| 29 | `(string,string,string)` | convoHistory | (platform, path, keyRef) StorageRef for DA-backed multi-turn history; `('','','')` if unused. See `ritual-dapp-da`. |

**Output**: `(bool hasError, bytes completionData, bytes modelMetadata, string errorMessage, (string,string,string) updatedConvoHistory)`

### Quick Encode

```typescript
// LLM — all 30 fields
const encoded = encodeAbiParameters(
  parseAbiParameters([
    'address, bytes[], uint256, bytes[], bytes,',
    'string, string, int256, string, bool, int256, string, string,',
    'uint256, bool, int256, string, bytes, int256, string, string, bool,',
    'int256, bytes, bytes, int256, int256, string, bool,',
    '(string,string,string)',
  ].join('')),
  [
    executor, [], 300n, [], '0x',
    JSON.stringify([{role:'user', content: prompt}]),
    model,
    0n, '', false, 4096n, '', '',           // freq, logitBias, logprobs, maxTokens, meta, modalities  -- >=4096 for GLM-4.7-FP8 reasoning headroom; see ritual-dapp-llm
    1n, true, 0n, 'medium', '0x', -1n,     // n, parallel, presence, reasoning, respFmt, seed
    'auto', '',                              // serviceTier, stop
    false,                                   // stream
    700n,                                    // temperature (0.7)
    '0x', '0x',                             // toolChoice, tools
    -1n, 1000n, '',                         // topLogprobs, topP, user
    false,                                   // piiEnabled
    ['gcs', 'convos/my-session.jsonl', 'GCS_CREDS'], // convoHistory
  ]
);
```

Rough deposit: 0.05 RITUAL (model-dependent, check ModelPricingRegistry).

---

## Long-Running HTTP (0x0805) — 35 fields

| Index | Type | Field |
|---|---|---|
| 0-4 | — | Base executor fields |
| 5 | `uint64` | pollIntervalBlocks |
| 6 | `uint64` | maxPollBlock (Phase 2 deadline offset) |
| 7 | `string` | taskIdMarker |
| 8 | `address` | deliveryTarget |
| 9 | `bytes4` | deliverySelector |
| 10 | `uint256` | deliveryGasLimit |
| 11 | `uint256` | deliveryMaxFeePerGas |
| 12 | `uint256` | deliveryMaxPriorityFeePerGas |
| 13 | `uint256` | deliveryValue |
| 14 | `string` | url |
| 15 | `uint8` | method |
| 16 | `string[]` | headersKeys |
| 17 | `string[]` | headersValues |
| 18 | `bytes` | body |
| 19 | `string` | taskIdJsonPath |
| 20 | `string` | pollUrl |
| 21 | `uint8` | pollMethod |
| 22 | `string[]` | pollHeadersKeys |
| 23 | `string[]` | pollHeadersValues |
| 24 | `bytes` | pollBody |
| 25 | `string` | statusJsonPath |
| 26 | `string` | resultUrl |
| 27 | `uint8` | resultMethod |
| 28 | `string[]` | resultHeadersKeys |
| 29 | `string[]` | resultHeadersValues |
| 30 | `bytes` | resultBody |
| 31 | `string` | resultJsonPath |
| 32 | `uint256` | dkmsKeyIndex |
| 33 | `uint8` | dkmsKeyFormat |
| 34 | `bool` | piiEnabled |

**Phase 1 output**: `(string taskId)`
**Phase 2 callback**: `function onLongRunningResult(bytes32 jobId, bytes calldata result) external`

---

## ZK Long-Running (0x0806) — 14 fields

Note: ZK extends ExecutorRequest directly, NOT the LongRunningRequest base. Different delivery field layout.

| Index | Type | Field |
|---|---|---|
| 0-4 | — | Base executor fields |
| 5 | `bool` | inputEncrypted |
| 6 | `uint64` | maxProofBlock (Phase 2 deadline offset) |
| 7 | `address` | deliveryTarget |
| 8 | `bytes4` | deliverySelector |
| 9 | `uint256` | deliveryGasLimit |
| 10 | `uint256` | deliveryMaxFeePerGas |
| 11 | `uint256` | deliveryMaxPriorityFeePerGas |
| 12 | `uint256` | deliveryValue |
| 13 | `bytes` | operationInput |

**Phase 1 output**: `bytes32` job commitment hash
**Phase 2 callback**: `function onZKResultDelivered(bytes32 jobId, bytes calldata result) external`

---

## FHE Inference (0x0807) — 19 fields

| Index | Type | Field |
|---|---|---|
| 0-4 | — | Base executor fields |
| 5 | `string` | model |
| 6 | `bytes` | encryptedInput |
| 7 | `bytes` | encryptedInputRef |
| 8 | `bytes` | evkReference |
| 9 | `uint8` | numLayers |
| 10 | `uint64` | maxInferenceBlock (Phase 2 deadline offset) |
| 11 | `address` | deliveryTarget |
| 12 | `bytes4` | deliverySelector |
| 13 | `uint256` | deliveryGasLimit |
| 14 | `uint256` | deliveryMaxFeePerGas |
| 15 | `uint256` | deliveryMaxPriorityFeePerGas |
| 16 | `uint256` | deliveryValue |
| 17 | `bytes` | encryptedInputStorage |
| 18 | `bytes` | encryptedOutputStorage |

---

## Sovereign Agent (0x080C) — 23 fields

Different base from other precompiles — no `encryptedSecrets[]` or `secretSignatures[]` in base. No `deliveryValue`.

| Index | Type | Field |
|---|---|---|
| 0 | `address` | executor |
| 1 | `uint256` | ttl |
| 2 | `bytes` | userPublicKey |
| 3 | `uint64` | pollIntervalBlocks |
| 4 | `uint64` | maxPollBlock |
| 5 | `string` | taskIdMarker |
| 6 | `address` | deliveryTarget |
| 7 | `bytes4` | deliverySelector |
| 8 | `uint256` | deliveryGasLimit |
| 9 | `uint256` | deliveryMaxFeePerGas |
| 10 | `uint256` | deliveryMaxPriorityFeePerGas |
| 11 | `uint16` | cliType (ABI enum includes 0..6, but current supported runtime path is 0=claude_code, 5=crush, 6=zeroclaw) |
| 12 | `string` | prompt |
| 13 | `bytes` | encryptedSecrets (single blob, not array) |
| 14 | `(string,string,string)` | convoHistory (platform, path, keyRef) |
| 15 | `(string,string,string)` | output |
| 16 | `(string,string,string)[]` | skills |
| 17 | `(string,string,string)` | systemPrompt |
| 18 | `string` | model |
| 19 | `string[]` | tools |
| 20 | `uint16` | maxTurns |
| 21 | `uint32` | maxTokens |
| 22 | `string` | rpcUrls |

---

## Image Call (0x0818) — 18 fields

| Index | Type | Field |
|---|---|---|
| 0-4 | — | Base executor fields |
| 5-13 | — | Polling + delivery config (same as Long-Running HTTP 5-13) |
| 14 | `string` | model |
| 15 | `(uint8,bytes,string,bytes32,uint32,uint32,bool)[]` | inputs (ModalInput array) |
| 16 | `(uint8,uint32,uint32,uint32,bool,uint16,uint16,uint32,uint8,string)` | output (OutputConfig) |
| 17 | `(string,string,string)` | outputStorageRef — StorageRef: (platform, path, keyRef). See `ritual-dapp-da`. |

**ModalInput**: `(inputType, data, uri, contentHash, param1, param2, encrypted)` — inputType: 0=TEXT, 1=IMAGE, 2=AUDIO, 3=VIDEO
**OutputConfig**: `(outputType, maxWidth, maxHeight, maxParam3, encryptOutput, numInferenceSteps, guidanceScaleX100, seed, fps, negativePrompt)`
**StorageRef**: `(platform, path, keyRef)` — platform is `'gcs'`, `'hf'`, or `'pinata'`. Credentials in `encryptedSecrets` keyed by `keyRef`. See `ritual-dapp-da`.

For IMAGE: outputType=1, maxParam1=width, maxParam2=height.

**Phase 2 result (Image)**: `(bool hasError, bytes completionData, string outputUri, bytes32 outputContentHash, bool outputEncrypted, uint32 outputSizeBytes, uint32 outputWidth, uint32 outputHeight, string errorMessage)`

---

## Audio Call (0x0819) — 18 fields

Same ABI structure as Image Call (field 17 is `outputStorageRef` StorageRef tuple). For AUDIO: outputType=2, maxParam1=maxDurationMs, negativePrompt repurposed as voice parameter.

**Phase 2 result (Audio)**: `(bool hasError, bytes completionData, string outputUri, bytes32 outputContentHash, bool outputEncrypted, uint32 outputSizeBytes, uint32 outputDurationMs, string errorMessage)`

---

## Video Call (0x081A) — 18 fields

Same ABI structure as Image Call (field 17 is `outputStorageRef` StorageRef tuple). For VIDEO: outputType=3, maxParam1=width, maxParam2=height, maxParam3=maxDurationMs, fps used.

**Phase 2 result (Video)**: `(bool hasError, bytes completionData, string outputUri, bytes32 outputContentHash, bool outputEncrypted, uint64 outputSizeBytes, uint32 outputWidth, uint32 outputHeight, uint32 outputDurationMs, string errorMessage)`

---

## DKMS Key (0x081B) — 8 fields

| Index | Type | Field |
|---|---|---|
| 0-4 | — | Base executor fields |
| 5 | `address` | owner |
| 6 | `uint256` | keyIndex |
| 7 | `uint8` | keyFormat |

---

## Persistent Agent (0x0820) — 26 fields

| Index | Type | Field |
|---|---|---|
| 0-4 | — | Base executor fields |
| 5 | `uint64` | maxSpawnBlock (Phase 2 deadline offset) |
| 6 | `address` | deliveryTarget |
| 7 | `bytes4` | deliverySelector |
| 8 | `uint256` | deliveryGasLimit |
| 9 | `uint256` | deliveryMaxFeePerGas |
| 10 | `uint256` | deliveryMaxPriorityFeePerGas |
| 11 | `uint256` | deliveryValue |
| 12 | `uint8` | provider (0=anthropic, 1=openai, 2=gemini, 3=xai, 4=openrouter) |
| 13 | `string` | model |
| 14 | `string` | llmApiKeyRef |
| 15 | `(string,string,string)` | daConfig |
| 16 | `(string,string,string)` | soulRef |
| 17 | `(string,string,string)` | agentsRef |
| 18 | `(string,string,string)` | userRef |
| 19 | `(string,string,string)` | memoryRef |
| 20 | `(string,string,string)` | identityRef |
| 21 | `(string,string,string)` | toolsRef |
| 22 | `(string,string,string)` | openclawConfigRef |
| 23 | `string` | restoreFromCid |
| 24 | `string` | rpcUrls |
| 25 | `uint16` | agentRuntime (0=ZeroClaw, 2=Hermes; 1 reserved for legacy OpenClaw deployments) |

StorageRef tuple: `(platform, path, keyRef)` — all strings.

---

## JQ (0x0803) — Synchronous

```solidity
(string query, string inputData, uint8 outputType)
```

| outputType | Return Type | Notes |
|---|---|---|
| 0 | `int256` | |
| 1 | `uint256` | |
| 2 | `string` | Most common |
| 3 | `bool` | |
| 4 | `address` | |
| 5-9 | Array variants | int256[], uint256[], string[], bool[], address[] |

String output (type 2) has a double-indirection wrapper. Use this decoder:

```solidity
function _decodeJQString(bytes memory raw) internal pure returns (string memory) {
    require(raw.length >= 96, "JQ output too short");
    uint256 strLen;
    assembly { strLen := mload(add(raw, 96)) }
    bytes memory result = new bytes(strLen);
    for (uint256 i = 0; i < strLen; i++) {
        result[i] = raw[96 + i];
    }
    return string(result);
}
```

Wrong `outputType` returns `ok=true` with zero-length output — it does NOT revert.

---

## ONNX Inference (0x0800) — Synchronous

```solidity
(bytes mlModelId, bytes tensorData, uint8 inputArithmetic, uint8 inputFixedPointScale,
 uint8 outputArithmetic, uint8 outputFixedPointScale, uint8 rounding)
```

`mlModelId`: UTF-8 bytes of `hf/<owner>/<repo>/<file>.onnx@<40-char-commit-hash>`. Branch names are rejected.

Arithmetic: 1 = fixed-point, **2 = IEEE 754** (use 2 for standard float models). Rounding: **1 = half-even**, 2 = truncate, 3 = floor, 4 = ceil. Value `0` is invalid for both fields.

RitualTensor encoding: `(uint8 dtype, uint16[] shape, int32[] values)`. For FLOAT32 (**dtype=5**), values are IEEE 754 bit-patterns.

Output is wrapped: `(bytes tensorEncoded, uint8 outputArithmetic, uint8 outputScale, uint8 rounding)`. Decode the outer envelope first, then the inner tensor.

---

## Ed25519 (0x0009) — Synchronous

```solidity
// Input:  abi.encode(bytes pubkey, bytes message, bytes signature)
// Output: abi.encode(uint256 isValid)  — 1 or 0
// Gas:    2,000

bytes memory input = abi.encode(pubkey, message, signature);  // all three are type bytes
(bool ok, bytes memory result) = address(0x0009).staticcall(input);
if (!ok || result.length == 0) revert("ed25519 failed");
bool isValid = abi.decode(result, (uint256)) == 1;
```

All three fields are ABI type `bytes` (dynamic). `pubkey` is 32 bytes, `signature` is 64 bytes (R || S). See `ritual-dapp-ed25519` for complete Solidity and TypeScript examples.

---

## SECP256R1 / P-256 (0x0100) — Synchronous

```solidity
// Input:  abi.encode(bytes pubkey, bytes message, bytes signature)
// Output: abi.encode(uint256 isValid)  — 1 or 0
// Gas:    3,450

bytes memory input = abi.encode(pubkey, message, signature);  // all three are type bytes
(bool ok, bytes memory result) = address(0x0100).staticcall(input);
if (!ok || result.length == 0) revert("secp256r1 failed");
bool isValid = abi.decode(result, (uint256)) == 1;
```

All three fields are ABI type `bytes` (dynamic). `pubkey` accepts 33 bytes (compressed) or 65 bytes (uncompressed, `0x04 || x || y`). `signature` is 64 bytes (`r || s`). `message` is the raw message — the precompile hashes it with SHA-256 internally. See `ritual-dapp-passkey` for complete patterns including TxPasskey (type `0x77`) and WebAuthn flows.

---

## TX Hash (0x0830) — Synchronous

No input. Returns `bytes32` of the current transaction hash. Used internally by the Scheduler.

---

## HTTP Method Codes

| Method | Code |
|---|---|
| GET | 1 |
| POST | 2 |
| PUT | 3 |
| DELETE | 4 |
| PATCH | 5 |
| HEAD | 6 |
| OPTIONS | 7 |

---

## Long-Running Delivery Config

All long-running async precompiles (except ZK and Sovereign Agent which have their own layouts) share fields 5-13 for polling and delivery:

| Index | Type | Field |
|---|---|---|
| 5 | `uint64` | pollIntervalBlocks |
| 6 | `uint64` | maxPollBlock (Phase 2 deadline offset from settlement block) |
| 7 | `string` | taskIdMarker (substituted in poll/result URLs) |
| 8 | `address` | deliveryTarget |
| 9 | `bytes4` | deliverySelector |
| 10 | `uint256` | deliveryGasLimit |
| 11 | `uint256` | deliveryMaxFeePerGas |
| 12 | `uint256` | deliveryMaxPriorityFeePerGas |
| 13 | `uint256` | deliveryValue |

All Phase 2 callbacks have signature: `function onResult(bytes32 jobId, bytes calldata result) external`
`msg.sender` is always `0x5A16214fF555848411544b005f7Ac063742f39F6` (AsyncDelivery).

---

## System Contracts

```typescript
const SYSTEM = {
  RITUAL_WALLET: '0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948',
  SCHEDULER: '0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B',
  ASYNC_JOB_TRACKER: '0xC069FFCa0389f44eCA2C626e55491b0ab045AEF5',
  ASYNC_DELIVERY: '0x5A16214fF555848411544b005f7Ac063742f39F6',
  TEE_SERVICE_REGISTRY: '0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F',
  SECRETS_ACCESS_CONTROL: '0xf9BF1BC8A3e79B9EBeD0fa2Db70D0513fecE32FD',
  MODEL_PRICING_REGISTRY: '0x7A85F48b971ceBb75491b61abe279728F4c4384f',
} as const;
```

## Capability Enum

| Capability | Value | Precompile |
|---|---|---|
| HTTP_CALL | 0 | 0x0801 |
| LLM | 1 | 0x0802 |
| WORMHOLE_QUERY | 2 | — |
| STREAMING | 3 | SSE relay |
| VLLM_PROXY | 4 | vLLM proxy |
| ZK_CALL | 5 | 0x0806 |
| DKMS | 6 | 0x081B |
| IMAGE_CALL | 7 | 0x0818 |
| AUDIO_CALL | 8 | 0x0819 |
| VIDEO_CALL | 9 | 0x081A |
| FHE | 10 | 0x0807 |
