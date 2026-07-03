---
name: ritual-dapp-da
description: Data Availability (storage) patterns for Ritual dApps. Use when any precompile stores or retrieves external data — multimodal outputs, conversation history, agent state, FHE ciphertexts, or artifact files.
---

# Data Availability (Storage) — Ritual dApp Patterns

## Overview

Several Ritual precompiles read from or write to external storage during execution. The chain itself does not store large blobs — generated images, conversation history, FHE ciphertexts, and agent artifacts all live off-chain on storage providers (GCS, HuggingFace, Pinata). The executor handles all storage I/O inside the TEE.

This skill covers the shared DA patterns. For precompile-specific ABI fields and usage, see the corresponding skill (`ritual-dapp-multimodal`, `ritual-dapp-llm`, `ritual-dapp-agents`).

## Read This First

- Use `StorageRef` everywhere DA appears: `(platform, path, keyRef)`.
- Put storage credentials in `encryptedSecrets`; `keyRef` links a DA field to its credential.
- Handle `hasError` on result decode paths (callbacks and settled async outputs).
- Keep this skill as the shared DA source; use precompile-specific skills only for ABI specifics.

## When to Use

- "How do I set `outputStorageRef` for image/audio/video?"
- "How should I format GCS/HF/Pinata credentials in `encryptedSecrets`?"
- "How do I debug DA failures when callbacks do not arrive?"
- "How does agent DA encryption with DKMS work?"

### Which Precompiles Use DA?

| Precompile | Address | DA Fields | Read/Write | Skill |
|---|---|---|---|---|
| Image Call | `0x0818` | `outputStorageRef` (field 17) | Write (upload generated image) | `ritual-dapp-multimodal` |
| Audio Call | `0x0819` | `outputStorageRef` (field 17) | Write (upload generated audio) | `ritual-dapp-multimodal` |
| Video Call | `0x081A` | `outputStorageRef` (field 17) | Write (upload generated video) | `ritual-dapp-multimodal` |
| FHE | `0x0807` | `inputStorageRef` (field 17), `outputStorageRef` (field 18) | Read + Write (ciphertext I/O) | `ritual-dapp-precompiles` |
| LLM Call | `0x0802` | `convoHistory` (field 29) | Read + Write (conversation JSONL, **plaintext**) | `ritual-dapp-llm` |
| Sovereign Agent | `0x080C` | `convoHistory` (14), `output` (15), `skills[]` (16), `systemPrompt` (17) | Read + Write (**DKMS-encrypted**) | `ritual-dapp-agents` |
| Persistent Agent | `0x0820` | `daConfig` (15), `soulRef` (16), `agentsRef` (17), `userRef` (18), `memoryRef` (19), `identityRef` (20), `toolsRef` (21), `openclawConfigRef` (22) | Read + Write (**DKMS-encrypted**) | `ritual-dapp-agents` |

---

## 1. StorageRef — The Universal Storage Pointer

Every DA field uses the same type: a `StorageRef` tuple of three strings.

```typescript
// ABI type: (string, string, string)
type StorageRef = [
  string,  // platform  — storage provider identifier
  string,  // path      — platform-specific object path
  string,  // keyRef    — placeholder name in encryptedSecrets for credentials
];
```

**How `keyRef` works:** `keyRef` points to the credential value inside `encryptedSecrets`. For example, if `keyRef = 'GCS_CREDS'`, then `encryptedSecrets` should include a `GCS_CREDS` entry with GCS credentials in the expected format.

**Empty ref:** `['', '', '']` means "no storage reference" — the executor skips this field.

### Encoding in TypeScript

```typescript
import { encodeAbiParameters } from 'viem';

// StorageRef is encoded as a tuple of three strings
const storageRef = ['gcs', 'outputs/image.png', 'GCS_CREDS'];

// In the full precompile ABI, use the tuple type:
// { type: 'tuple', components: [
//   { name: 'platform', type: 'string' },
//   { name: 'path', type: 'string' },
//   { name: 'keyRef', type: 'string' },
// ]}

// Or with parseAbiParameters shorthand:
// '(string,string,string)'
```

### Encoding in Solidity

```solidity
// StorageRef value passed as one tuple field in a larger precompile payload
StorageRef memory outRef = StorageRef({
    platform: "gcs",
    path: "outputs/image.png",
    keyRef: "GCS_CREDS"
});

// Example: include outRef in your full abi.encode payload
bytes memory input = abi.encode(
    // ... other fields ...
    outRef
);
```

---

## 2. Supported Platforms

| Platform | `platform` value | `path` format | `keyRef` value | Auth Required |
|---|---|---|---|---|
| Google Cloud Storage | `'gcs'` | Object path within bucket (bucket is in credential JSON) | Key name in `encryptedSecrets` holding `{service_account_json, bucket}` JSON | Yes |
| HuggingFace | `'hf'` | `org/repo/path/to/file` (slash-separated, first two segments are repo ID) | Key name holding HF access token string | Yes |
| Pinata (IPFS) | `'pinata'` | CID (empty for first upload, CID for subsequent) | Key name holding `{jwt, gateway_url}` JSON | Yes |

### GCS Path Format

The path is an object key within the GCS bucket. The bucket name is specified inside the credential JSON (the `bucket` field), not in the StorageRef path.

```typescript
// GCS StorageRef — object path only, bucket is in credentials
const gcsRef: StorageRef = ['gcs', 'multimodal/outputs/image_001.png', 'GCS_CREDS'];

// The GCS_CREDS value in encryptedSecrets must be a JSON string with two fields:
// '{"service_account_json":"{\"type\":\"service_account\",...}","bucket":"my-bucket"}'
//
// service_account_json: the full GCP service account key file JSON (stringified)
// bucket: the GCS bucket name
```

### HuggingFace Path Format

Slash-separated: the first two segments are the HF repo ID, the rest is the file path within the repo.

```typescript
// org/repo/path/to/file — first two segments = repo ID, rest = file path
const hfRef: StorageRef = ['hf', 'my-org/agent-data/configs/SOUL.md', 'HF_TOKEN'];
// repo ID = "my-org/agent-data", file path = "configs/SOUL.md"

// Repo-root ref (no file subpath) — use for listing/downloading entire repo
const hfRepoRef: StorageRef = ['hf', 'my-org/agent-configs', 'HF_TOKEN'];
```

### Pinata (IPFS) Path Format

Pinata is append-only (content-addressed). Each upload returns a new CID. For the first upload, pass an empty path. For subsequent uploads, pass the CID from the previous response.

```typescript
// First call — empty path, CID returned after upload
const pinataFirst: StorageRef = ['pinata', '', 'DA_PINATA_JWT'];

// Subsequent call — pass CID from previous response
const pinataNext: StorageRef = ['pinata', 'QmXyzAbc123...', 'DA_PINATA_JWT'];
```

### Inline

Content is embedded directly in the path field. No storage I/O occurs — the executor reads the path string as the content. Read-only (never uploaded to).

```typescript
const inlineRef: StorageRef = ['inline', 'You are a helpful DeFi agent.', ''];
```

---

## 3. Providing Storage Credentials

Storage credentials are delivered inside `encryptedSecrets`, encrypted with the executor's ECIES public key. The `keyRef` field in each `StorageRef` tells the executor which key in the decrypted secrets map holds the credential.

### Credential Format by Platform

| Platform | Credential Format | Example `encryptedSecrets` JSON |
|---|---|---|
| GCS | JSON object with `service_account_json` and `bucket` | `{"GCS_CREDS": "{\"service_account_json\":\"{\\\"type\\\":\\\"service_account\\\",...}\",\"bucket\":\"my-bucket\"}"}` |
| HuggingFace | HF access token string (plain, not JSON) | `{"HF_TOKEN": "hf_abc123..."}` |
| Pinata | JSON object with `jwt` and `gateway_url` | `{"PINATA_CREDS": "{\"jwt\":\"eyJ...\",\"gateway_url\":\"https://my-gateway.mypinata.cloud/ipfs\"}"}` |

### Encrypting Credentials

```typescript
import { encrypt, ECIES_CONFIG } from 'eciesjs';
import { encodeAbiParameters, hexToBytes, bytesToHex } from 'viem';

// MANDATORY: 12-byte nonce for Ritual ECIES
ECIES_CONFIG.symmetricNonceLength = 12;

// Combine storage credentials with any other secrets (e.g., LLM API key)
const gcsServiceAccountJson = process.env.GCS_DA_SERVICE_ACCOUNT_JSON!;
const gcsBucket = process.env.GCS_DA_BUCKET!;

const secretsJson = JSON.stringify({
  ANTHROPIC_API_KEY: 'sk-ant-...',
  GCS_CREDS: JSON.stringify({
    service_account_json: gcsServiceAccountJson,
    bucket: gcsBucket,
  }),
});

// Encrypt to executor's public key (from TEEServiceRegistry)
const encryptedBuffer = encrypt(executorPublicKey.slice(2), Buffer.from(secretsJson));
const encryptedSecrets = [`0x${encryptedBuffer.toString('hex')}` as `0x${string}`];
```

> **ECIES nonce length = 12.** Both `eciesjs` (TypeScript) and `eciespy` (Python) default to 16-byte nonces. The executor uses 12. Mismatched nonce length causes silent decryption failure — the transaction mines but DA operations fail with no error message. Set `ECIES_CONFIG.symmetricNonceLength = 12` (TypeScript) or `ECIES_CONFIG.symmetric_nonce_length = 12` (Python) before any `encrypt()` call.

### Executor Discovery for Public Key

```typescript
import { createPublicClient, http, defineChain } from 'viem';

const ritualChain = defineChain({
  id: 1979,
  name: 'Ritual Chain',
  nativeCurrency: { name: 'RITUAL', symbol: 'RITUAL', decimals: 18 },
  rpcUrls: { default: { http: [process.env.RITUAL_RPC_URL!] } },
});
const publicClient = createPublicClient({ chain: ritualChain, transport: http() });

const TEE_SERVICE_REGISTRY = '0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F' as const;

// Use the capability for your precompile:
// 0 = HTTP_CALL (agents), 1 = LLM, 7 = IMAGE_CALL (multimodal)
const services = await publicClient.readContract({
  address: TEE_SERVICE_REGISTRY,
  abi: [{
    name: 'getServicesByCapability',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'capability', type: 'uint8' }, { name: 'activeOnly', type: 'bool' }],
    outputs: [{ type: 'tuple[]', components: [
      { name: 'node', type: 'tuple', components: [
        { name: 'paymentAddress', type: 'address' },
        { name: 'teeAddress', type: 'address' },
        { name: 'teeType', type: 'uint8' },
        { name: 'publicKey', type: 'bytes' },
        { name: 'endpoint', type: 'string' },
        { name: 'certPubKeyHash', type: 'bytes32' },
        { name: 'capability', type: 'uint8' },
      ]},
      { name: 'isValid', type: 'bool' },
      { name: 'workloadId', type: 'bytes32' },
    ]}],
  }] as const,
  functionName: 'getServicesByCapability',
  args: [7, true],  // 7 = IMAGE_CALL capability
});

const executor = services[0];
const executorAddress = executor.node.teeAddress;
const executorPublicKey = executor.node.publicKey as `0x${string}`;
```

### Binding Credentials with SecretsAccessControl

Storage credentials in `encryptedSecrets` are visible on-chain (as ciphertext). Anyone can copy and replay them. To prevent unauthorized reuse, bind credentials to your contract using `SecretsAccessControl`:

```typescript
import { keccak256, toBytes } from 'viem';

const SECRETS_AC = '0xf9BF1BC8A3e79B9EBeD0fa2Db70D0513fecE32FD' as const;
const secretsHash = keccak256(toBytes(encryptedSecrets[0]));
const currentBlock = await publicClient.getBlockNumber();

await walletClient.writeContract({
  address: SECRETS_AC,
  abi: [{
    name: 'grantAccess',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'delegate', type: 'address' },
      { name: 'secretsHash', type: 'bytes32' },
      { name: 'expiresAt', type: 'uint256' },
      { name: 'policy', type: 'tuple', components: [
        { name: 'allowedDestinations', type: 'string[]' },
        { name: 'allowedMethods', type: 'string[]' },
        { name: 'allowedPaths', type: 'string[]' },
        { name: 'allowedQueryParams', type: 'string[]' },
        { name: 'allowedHeaders', type: 'string[]' },
        { name: 'secretLocation', type: 'string' },
        { name: 'bodyFormat', type: 'string' },
      ]},
    ],
    outputs: [],
  }] as const,
  functionName: 'grantAccess',
  args: [
    consumerContractAddress,
    secretsHash,
    currentBlock + 50_000n,
    { allowedDestinations: [], allowedMethods: [], allowedPaths: [],
      allowedQueryParams: [], allowedHeaders: [], secretLocation: '', bodyFormat: '' },
  ],
});
```

See `ritual-dapp-secrets` for the full delegation pattern.

---

## 4. DA Lifecycle (Builder View)

From an app-builder perspective, DA follows a simple lifecycle:

1. **Prepare request inputs**
   - Set one or more `StorageRef` values.
   - Include matching credentials in `encryptedSecrets`.
   - Ensure your wallet lock/deposit is valid for async execution.

2. **Submit the precompile call**
   - The request is accepted on-chain.
   - Processing continues asynchronously for long-running precompiles.

3. **Receive success result**
   - You receive a URI / updated storage reference through the normal result channel:
     - callback for long-running precompiles
     - settled receipt output for short-running async precompiles

4. **Or receive an error result**
   - DA failures come back as structured results with `hasError=true` and an `errorMessage`.
   - You can surface this error directly in your app UX.

### Output URI Handling

Multimodal executors upload to GCS and return `gs://` URIs. Browsers cannot fetch `gs://` directly — convert to HTTPS before displaying:

```typescript
function gsUriToHttps(uri: string): string {
  if (uri.startsWith('gs://')) {
    return uri.replace('gs://', 'https://storage.googleapis.com/');
  }
  return uri;
}
```

---

## 5. DA Error Handling

When storage operations fail (bad credentials, upload failure, network/provider issues), the request still resolves on-chain with a structured error result instead of hanging silently.

### What You Should Expect

1. The result payload includes `hasError=true`.
2. `errorMessage` explains the failure reason.
3. DA-related failures settle with a **constant error fee**: `500,000,000,000 wei` (0.0000005 ETH), which is much smaller than a successful generation fee.
4. Your app should treat `hasError=true` as a terminal state and surface the message to users.

### DA Errors Apply To

| Precompile | Common DA failure points |
|---|---|
| Image (0x0818) | Credential validation failure, output upload failure |
| Audio (0x0819) | Credential validation failure, output upload failure |
| Video (0x081A) | Credential validation failure, output upload failure |
| FHE (0x0807) | Input/output storage credential failure, output upload failure |
| LLM (0x0802) | Convo-history credential failure, convo-history upload failure |

All DA-using precompiles settle with a constant error fee (500,000,000,000 wei / 0.0000005 ETH) when `hasError=true`: a small constant amount is deducted from escrow, far less than successful generation pricing.

### Handling DA Errors in Your Callback

```typescript
// In your Phase 2 callback (e.g., onImageReady):
function onImageReady(jobId: `0x${string}`, responseData: `0x${string}`) {
  const [hasError, , outputUri, , , , , , errorMessage] = decodeAbiParameters(
    [
      { type: 'bool' }, { type: 'bytes' }, { type: 'string' },
      { type: 'bytes32' }, { type: 'bool' }, { type: 'uint32' },
      { type: 'uint32' }, { type: 'uint32' }, { type: 'string' },
    ],
    responseData,
  );

  if (hasError) {
    // DA error — errorMessage contains the reason
    // Common messages:
    //   "Failed to decrypt secrets: ..."
    //   "Failed to create storage client: ..."
    //   "Storage credentials invalid: ..."
    //   "Phase 2 processing failed after N retries: ..."
    console.error('DA error:', errorMessage);
    return;
  }

  // Success — use outputUri
}
```

```solidity
// Solidity callback
address constant ASYNC_DELIVERY = 0x5A16214fF555848411544b005f7Ac063742f39F6;

function onImageReady(bytes32 jobId, bytes calldata responseData) external {
    require(msg.sender == ASYNC_DELIVERY, "unauthorized callback sender");
    (bool hasError, , , , , , , , string memory errorMsg) = abi.decode(
        responseData,
        (bool, bytes, string, bytes32, bool, uint32, uint32, uint32, string)
    );

    if (hasError) {
        emit MediaFailed(jobId, errorMsg);
        return;
    }

    // Process success...
}
```

### Two Common Error Timing Patterns

**Before generation completes**
- Typically credential or access issues.
- You receive `hasError=true` without a usable output URI.

**After generation but before persistence**
- Generation succeeded, but writing output to storage failed.
- You still receive `hasError=true`, and should ask users to retry.

---

## 6. DKMS — Per-Sender DA Encryption (Agent Precompiles Only)

Agent precompiles (Sovereign Agent, Persistent Agent) use DKMS (Decentralized Key Management) to derive a per-sender encryption key inside the TEE. All **agent** DA content is encrypted at rest.

> **LLM, multimodal (image/audio/video), and FHE precompiles store output in plaintext.** Only Sovereign Agent and Persistent Agent use DKMS-derived encryption. LLM conversation history, generated images, audio, video, and FHE ciphertexts are written directly to the storage provider without an additional encryption layer.

### How DKMS DA Encryption Works

1. The executor derives a **secp256k1 keypair** from DKMS, bound to the sender's Ethereum address.
2. **Uploads**: executor ECIES-encrypts content with the derived public key before writing to storage.
3. **Downloads**: executor ECIES-decrypts content with the derived private key after reading from storage.
4. The keypair is **sender-bound, not executor-bound** — agent state is portable across executors.

### Encrypted Inputs with `dkms_encrypted:` Prefix

Skills and system prompts for agents can be pre-encrypted to the agent's DA public key. This keeps agent instructions private on the storage provider.

To use this pattern:

1. Get the agent's DA public key from the DKMS precompile (`0x081B`).
2. ECIES-encrypt the content with that public key.
3. Upload the ciphertext to HF/GCS/Pinata.
4. Set `keyRef` to `dkms_encrypted:<credential>` on the StorageRef.

```typescript
const systemPrompt: StorageRef = [
  'hf',
  'my-org/workspace/system.encrypted.md',
  'dkms_encrypted:HF_TOKEN',  // prefix tells executor to DKMS-decrypt after download
];
```

> **Two different encryption targets.** `encryptedSecrets` is encrypted to the **executor's** public key (from `TEEServiceRegistry.node.publicKey`). `dkms_encrypted:` content is encrypted to the **agent's** DA public key (from DKMS precompile 0x081B). These are different keys for different purposes.

See `ritual-dapp-agents` for the full DKMS agent pattern.

---

## 7. Debugging DA Failures

### Symptom: TX Mines But Callback Never Arrives (Multimodal)

This is the most common DA failure. Phase 1 succeeds but the Phase 2 callback never comes.

**Checklist:**

1. **Is `outputStorageRef` non-empty?** An empty `['', '', '']` means no storage configured — the executor cannot upload the output.
2. **Is `keyRef` correct?** Must match a key in the decrypted `encryptedSecrets` JSON exactly.
3. **Is the credential format correct?** GCS expects a JSON payload containing both `service_account_json` and `bucket`. HF expects a token string. Pinata expects a JSON payload containing `jwt` and `gateway_url`.
4. **Is `ECIES_CONFIG.symmetricNonceLength` = 12?** Wrong nonce length = executor cannot decrypt secrets = silent failure.
5. **Is the executor public key current?** Fetch fresh from `TEEServiceRegistry.getServicesByCapability()`.
6. **Is the RitualWallet lock still active?** `lockUntil` must be > `current block + ttl`. Locks expire fast — 5,000 blocks is only ~29 min at Ritual's ~350ms conservative baseline. Use 100,000+ for development.

### Symptom: Callback Arrives with `hasError=true`

The executor detected a DA problem and settled with an error. Read the `errorMessage` field:

| Error Message Pattern | Cause | Fix |
|---|---|---|
| `Failed to decrypt secrets: ...` | ECIES decryption failed | Check nonce length (12), public key correctness |
| `Failed to create storage client: ...` | Credential format invalid for platform | Check credential JSON format per platform table above |
| `Storage credentials invalid: ...` | Credentials are well-formed but rejected by the storage provider | Check SA permissions, token expiry, bucket existence |
| `Phase 2 processing failed after N retries: ...` | Upload succeeded partially or network issues | Retry with fresh credentials; check storage provider status |

### Symptom: Agent DA Content Not Persisting

For Sovereign/Persistent agents:

1. **Check that DA credentials are in `encryptedSecrets`.** Agent DA requires credentials alongside the LLM API key.
2. **Check `convoHistory` and `output` StorageRefs are non-empty.** Empty refs = no persistence between calls.
3. **For Pinata: pass the CID from the previous response.** Pinata is content-addressed — you must chain CIDs across calls.
4. **All agent DA content is ECIES-encrypted at rest.** You cannot read it directly from the storage provider — it is ciphertext.

---

## Quick Reference

| Item | Value |
|---|---|
| StorageRef type | `(string platform, string path, string keyRef)` |
| Supported platforms | `gcs`, `hf`, `pinata`, `inline` |
| Credential delivery | Via `encryptedSecrets` (ECIES-encrypted to executor public key) |
| ECIES nonce length | **12** (both TypeScript and Python default to 16 — must override) |
| DA error fee | 500,000,000,000 wei (constant, applies to Image/Audio/Video/FHE) |
| DA error detection | `hasError` field in response payload |
| DKMS DA encryption | Per-sender derived key, content encrypted at rest (agents only) |
| TEEServiceRegistry | `0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F` |
| SecretsAccessControl | `0xf9BF1BC8A3e79B9EBeD0fa2Db70D0513fecE32FD` |
| RitualWallet | `0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948` |
