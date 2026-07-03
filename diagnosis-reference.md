# Diagnosis Reference

Quick diagnostic lookup for Ritual dApp debugging.

**Chain:** Ritual (ID `1979`) | **RPC:** `https://rpc.ritualfoundation.org` | **Block time:** ~350ms (conservative baseline)

**Block-time conversions:** 100 blocks ≈ 35s, 300 blocks ≈ 1.75 min, 1000 blocks ≈ 5.8 min, 5000 blocks ≈ 29.2 min, 100,000 blocks ≈ 9.7 hr.

## System Contracts

| Contract | Address |
|----------|---------|
| RitualWallet | `0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948` |
| TEEServiceRegistry | `0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F` |
| AsyncJobTracker | `0xC069FFCa0389f44eCA2C626e55491b0ab045AEF5` |
| AsyncDelivery | `0x5A16214fF555848411544b005f7Ac063742f39F6` |
| SecretsAccessControl | `0xf9BF1BC8A3e79B9EBeD0fa2Db70D0513fecE32FD` |
| Scheduler | `0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B` |

For full ABI definitions, interfaces, and interaction patterns see `ritual-dapp-contracts`.

---

## Diagnostic Flow

Most failures are dApp-side (encoding, wallet, callback config) — not infrastructure. Check by likelihood:

1. TX reverted or missing → encoding or submission error (most common)
2. Wallet unfunded or lock expired → deposit issue
3. Callback not firing → wrong selector, gas too low, or decode mismatch
4. Job stuck (PENDING/EXPIRED) → TTL too short
5. Wrong output → ABI decode mismatch
6. Chain unreachable → infrastructure (rare)

### Step 1: Transaction Status

```bash
cast receipt <TX_HASH> --rpc-url https://rpc.ritualfoundation.org
```

- `status` = 1 → success. `status` = 0 → reverted.
- If reverted: `cast run <TX_HASH> --rpc-url https://rpc.ritualfoundation.org`
- If TX not found: `cast nonce <ADDRESS>` + `cast balance <ADDRESS>` — TX was likely dropped (gas/nonce/balance).

### Step 2: Wallet Balance

```bash
cast call 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948 \
  "balanceOf(address)(uint256)" <ADDRESS> \
  --rpc-url https://rpc.ritualfoundation.org

cast call 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948 \
  "lockUntil(address)(uint256)" <ADDRESS> \
  --rpc-url https://rpc.ritualfoundation.org
```

`balanceOf` > 0 and `lockUntil` > current block + TTL. See `ritual-dapp-wallet` for deposit sizing, scheduled TX payer semantics, and the `deposit(uint256 lockDuration)` call.

### Step 3: Callback Execution

```bash
cast receipt <SETTLEMENT_TX_HASH> --rpc-url https://rpc.ritualfoundation.org
```

If no callback logs: verify selector (`cast sig "handleCallback(bytes32,bytes)"`), increase `deliveryGasLimit` to 500,000+, or simulate: `cast call <CONTRACT> "handleCallback(bytes32,bytes)" <JOB_ID> <DATA>`. See `ritual-dapp-contracts` for callback patterns.

### Step 4: Job State

```bash
cast call 0xC069FFCa0389f44eCA2C626e55491b0ab045AEF5 \
  "getJob(bytes32)(uint8,address,address,uint256,uint256,bytes)" \
  <JOB_ID> --rpc-url https://rpc.ritualfoundation.org
```

| State | Value | Meaning | Next |
|-------|-------|---------|------|
| NONE | 0 | Job never created | Step 1 — TX reverted |
| PENDING | 1 | Waiting for executor | Check TTL; step 6 |
| COMMITTED | 2 | Executor computing | Wait; recheck TTL if slow |
| SETTLED | 3 | Delivered, callback pending | Step 3 |
| COMPLETED | 4 | Done | Check callback event logs |
| FAILED | 5 | Executor error | Inspect settlement TX logs |
| EXPIRED | 6 | TTL exceeded | Increase TTL, check step 6 |

### Step 5: Encoding / Decoding

```bash
cast tx <TX_HASH> --rpc-url https://rpc.ritualfoundation.org
```

See `ritual-dapp-precompiles` for the full ABI spec per precompile and `ritual-dapp-contracts` for decode patterns.

### Step 6: Executor Availability

```bash
cast call 0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F \
  "getServicesByCapability(uint8,bool)" <CAPABILITY_ID> true \
  --rpc-url https://rpc.ritualfoundation.org
```

Non-empty hex = executors registered. Short/empty = none available. Discovery uses `teeAddress` and `publicKey` only — the `endpoint` field in TEEServiceRegistry is internal infrastructure and irrelevant to dApp developers. See `ritual-dapp-secrets` for encryption target selection.

### Step 7: Chain Connectivity

```bash
cast chain-id --rpc-url https://rpc.ritualfoundation.org
```

Healthy: `1979`. Only check this if all other steps fail or RPC calls are timing out.

---

## Scheduled + Async Trace Utilities (RPC-Only)

For scheduled and scheduled-async debugging, follow:
`agents/debugger-reference/scheduled-async-rpc-runbook.md`

### Deterministic scheduled hashes from schedule-submission tx

```bash
python3 /tmp/scheduled_txs.py \
  --hash <SCHEDULE_SUBMISSION_TX_HASH> \
  --rpc-url https://rpc.ritualfoundation.org
```

### Commitment tx lookup from async origin hash

```bash
python3 /tmp/commitment_tx.py \
  --hash <ASYNC_ORIGIN_HASH> \
  --lookback 2000 \
  --rpc-url https://rpc.ritualfoundation.org
```

Copy both utilities from:
`agents/debugger-reference/scheduled-async-rpc-runbook.md`

---

## Common Patterns

Match symptom → apply fix. If no pattern matches, use the diagnostic flow above.

### All Precompiles

| # | Symptom | Cause | Fix | Ref |
|---|---------|-------|-----|-----|
| 1 | TX reverts `InsufficientBalance` | RitualWallet unfunded | `deposit{value: X}(lockDuration)` | `ritual-dapp-wallet` |
| 2 | `InvalidPrecompileInput` revert | Malformed ABI encoding | Verify field order and types against precompile ABI | `ritual-dapp-precompiles` |
| 3 | `InvalidExecutor` revert | Executor not registered | `getServicesByCapability(capId, true)` — use a returned `teeAddress` | `ritual-dapp-deploy` |
| 4 | Fee lock fails | Contract not approved | `RitualWallet.approve(consumerContract, amount)` | `ritual-dapp-wallet` |
| 5 | TX not found on chain | Never broadcast | Check nonce + native balance. Resubmit. | `ritual-dapp-deploy` |
| 6 | `Requested resource not available` from frontend | `eth_estimateGas` fails on async precompiles | Use raw `eth_sendTransaction` with explicit hex gas. See ref for details. | `ritual-dapp-deploy` |
| 7 | `sender locked` | Pending async TX for this address | Wait for current TX to settle or use a different EOA. Check: `AsyncJobTracker.hasPendingJobForSender(sender)` | `ritual-dapp-contracts` |

### Short-Running Async (HTTP, LLM)

| # | Symptom | Cause | Fix | Ref |
|---|---------|-------|-----|-----|
| 8 | Job PENDING > 2 min | No executor or TTL too short | Verify capability and executor. Increase TTL. | `ritual-dapp-testing` |
| 9 | Job EXPIRED | Executor didn't commit in time | Increase TTL and verify executor health | `ritual-dapp-llm` |
| 10 | Job SETTLED, no callback | Wrong delivery selector or gas too low | Verify selector matches. Increase gas to 500,000+. | `ritual-dapp-contracts` |
| 11 | Callback reverts | ABI decode failure in handler | Simulate callback with `cast call`. Check decode types match precompile output. | `ritual-dapp-contracts` |
| 12 | Empty bytes result | Codec mismatch or executor error | Check settlement TX logs for `errorMessage`. Verify decode ABI. | `ritual-dapp-precompiles` |
| 13 | Streaming silent hang | `stream=false` in ABI but SSE connected | Verify `stream: true` in request. EIP-712 domain: `'Ritual Streaming Service'`. Signer = tx sender. | `ritual-dapp-llm` |

### Two-Phase Async (Long HTTP, Sovereign Agent, Persistent Agent, Image, Audio, Video)

| # | Symptom | Cause | Fix | Ref |
|---|---------|-------|-----|-----|
| 14 | Long-running job stuck polling | JQ queries wrong | `curl` poll URL manually, fix `taskIdJsonPath` / `statusJsonPath` / `resultJsonPath` | `ritual-dapp-longrunning` |
| 15 | Scheduled job never triggers | Invalid interval or expired schedule | Check scheduler FSM state. Re-schedule with valid interval + future expiry. | `ritual-dapp-scheduler` |
| 16 | Private output unreadable | Wrong decryption key | Ensure public key in request matches private key for decryption | `ritual-dapp-secrets` |
| 17 | Delegated secret rejected | Access policy blocks caller | `grantAccess(delegate, secretsHash, expiresAt, policy)` — 4 args. See ref for full pattern. | `ritual-dapp-secrets` |
| 18 | Callback never received | Wrong callback signature | Must be `(bytes32 jobId, bytes calldata responseData)` — 2 params. `deliverySelector` must match. | `ritual-dapp-multimodal` |
| 19 | TX mines, callback never arrives | Silent Phase 2 failure | See ref for full debugging checklist (ECIES, storageType, credentials, lock) | `ritual-dapp-multimodal` |
| 20 | `cipher: message authentication failed` | ECIES encryption config wrong | Configure ECIES per `ritual-dapp-secrets` (nonce length, key selection) | `ritual-dapp-secrets` |

### ONNX-Specific

| # | Symptom | Cause | Fix | Ref |
|---|---------|-------|-----|-----|
| 21 | `PrecompileError` on `0x0800` | Wrong enum or model not cached | ArithmeticType: 1 or 2 (not 0). Rounding: 1–4 (not 0). Model ID needs 40-char commit hash. See ref. | `ritual-dapp-onnx` |
| 22 | TX submitted, never mined | Model not cached on block builder | JIT download — wait and retry. See ref for model ID validation. | `ritual-dapp-onnx` |
| 23 | Decode error on success | Output double-wrapped | Decode outer `(bytes, uint8, uint8, uint8)` then inner `(uint8, uint16[], int32[])`. See ref. | `ritual-dapp-onnx` |

### Scheduled + Scheduled-Async

| # | Symptom | Cause | Fix | Ref |
|---|---------|-------|-----|-----|
| 24 | Have schedule tx hash, but no downstream execution hashes | Need deterministic `TxScheduled` derivation per execution index | Run embedded `scheduled_txs.py` utility from runbook on the schedule-submission tx hash | `agents/debugger-reference/scheduled-async-rpc-runbook.md` |
| 25 | Have async origin hash, but cannot find commitment tx | Commitment appears via `AsyncJobTracker.JobAdded` in scanned range | Run embedded `commitment_tx.py` utility from runbook and increase `lookback` if needed | `agents/debugger-reference/scheduled-async-rpc-runbook.md` |
| 26 | Commitment exists, unsure if completed | Need event-level lifecycle reconciliation | Check `Phase1Settled` and `JobRemoved(completed=...)` for the resolved job ID | `agents/debugger-reference/scheduled-async-rpc-runbook.md` |

